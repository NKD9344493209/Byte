import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core/app_lock.dart';
import 'core/bubble.dart';
import 'core/capture_trigger.dart';
import 'core/drive_media.dart';
import 'core/expiry.dart';
import 'core/friends.dart';
import 'core/prefs.dart';
import 'core/private_space.dart';
import 'core/shares.dart';
import 'core/storage_audit.dart';
import 'core/user_busy.dart';
import 'features/capture/audio_compress.dart';
import 'features/capture/quick_capture_screen.dart';
import 'features/capture/recorder_service.dart';
import 'features/home/home_screen.dart';
import 'features/library/library_repo.dart';
import 'features/notes/note_editor_screen.dart';
import 'features/notes/notes_repo.dart';
import 'features/onboarding/setup_flow_screen.dart';
import 'features/wallet/wallet_screen.dart';
import 'shared/lock_gate.dart';
import 'shared/theme.dart';

/// Root widget. Follows the phone: light by default, dark when the system is
/// dark. The palette flips with it and the whole tree is rebuilt (new key).
class ByteApp extends StatefulWidget {
  const ByteApp({super.key});

  @override
  State<ByteApp> createState() => _ByteAppState();
}

class _ByteAppState extends State<ByteApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _syncPalette();
    Prefs.themeMode.addListener(_onThemeMode);
    AppLock.unlocked.addListener(_onUnlocked);
    Bubble.listen();
    WidgetsBinding.instance.addPostFrameCallback((_) => Future<void>.delayed(const Duration(seconds: 3), Bubble.applyTicks));
    WidgetsBinding.instance.addPostFrameCallback((_) => Future<void>.delayed(const Duration(seconds: 2), _openFromShortcut));
  }

  @override
  void dispose() {
    Prefs.themeMode.removeListener(_onThemeMode);
    AppLock.unlocked.removeListener(_onUnlocked);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _onThemeMode() {
    if (mounted) setState(_syncPalette);
  }

  @override
  void didChangePlatformBrightness() {
    setState(_syncPalette);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Leaving BYTE closes the private space.
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) PrivateSpace.onAppPaused();
    if (state != AppLifecycleState.resumed) return;
    PrivateSpace.onAppResumed();
    _openFromShortcut();
    // Ticks made in the notification or the bubble go into their note.
    Bubble.applyTicks();
    // What a friend ticked or added meanwhile comes in.
    Friends.syncSoon();
    // Things whose last day has come go to the bin.
    Future<void>.delayed(const Duration(seconds: 5), Expiry.runDue);
    // Shared links whose last day has come stop working.
    Future<void>.delayed(const Duration(seconds: 7), Shares.runDue);
    // Storage: shrink any WAV left over, and a daily tidy-up.
    Future<void>.delayed(const Duration(seconds: 10), AudioCompressor.compressDue);
    Future<void>.delayed(const Duration(seconds: 15), StorageCleaner.runIfDue);
    // Drive: the pill is fresh, and anything waiting goes up.
    DriveMedia.refresh();
    Future<void>.delayed(const Duration(seconds: 3), DriveMedia.kick);
  }

  /// A place asked for while BYTE was locked; opened right after unlocking.
  String? _openAfterUnlock;

  void _onUnlocked() {
    final which = _openAfterUnlock;
    if (which == null || !AppLock.unlocked.value) return;
    _openAfterUnlock = null;
    _openPlace(which);
  }

  /// A launcher shortcut, the bubble or one of BYTE's own notifications can
  /// name the place to open ("byte_open" on the intent): a tab, the recorder,
  /// a new note, a new checklist, or the pinned checklist.
  Future<void> _openFromShortcut() async {
    if (!Platform.isAndroid) return;
    try {
      final which = await const MethodChannel('byte/system').invokeMethod<String>('consumeOpen');
      if (which == null) return;
      final nav = CaptureTrigger.navigatorKey.currentState;
      if (nav == null) return;
      if (which == 'record') {
        // The recorder works while BYTE is locked too: it shows nothing of yours.
        nav.push(MaterialPageRoute<void>(fullscreenDialog: true, builder: (_) => const QuickCaptureScreen(source: 'app')));
        return;
      }
      if (AppLock.enabled && !AppLock.unlocked.value) {
        _openAfterUnlock = which; // everything else waits behind the lock
        return;
      }
      await _openPlace(which);
    } catch (e) {
      debugPrint('[open] $e');
    }
  }

  Future<void> _openPlace(String which) async {
    final nav = CaptureTrigger.navigatorKey.currentState;
    if (nav == null) return;
    if (which.startsWith('note:')) {
      // From the reminder of a checklist item: that list, up to date.
      await Bubble.applyTicks();
      final id = which.substring(5);
      final note = await NotesRepo.instance.get(id);
      // (Gone to the bin or into the private space since the reminder was set: not opened.)
      if (note == null || note.private || (await LibraryRepo.instance.inLibrary([id])).isEmpty) {
        HomeScreen.jumpTo.value = 'library';
        return;
      }
      nav.push(MaterialPageRoute<void>(builder: (_) => NoteEditorScreen(note: note)));
      return;
    }
    switch (which) {
      case 'note':
        nav.push(MaterialPageRoute<void>(builder: (_) => const NoteEditorScreen()));
      case 'checklist':
        nav.push(MaterialPageRoute<void>(builder: (_) => const NoteEditorScreen(checklist: true)));
      case 'wallet':
        // (From a "this paper runs out soon" reminder.)
        await WalletScreen.open(nav.context);
      case 'pinned':
        // First write in the ticks made outside, so the list opens up to date.
        await Bubble.applyTicks();
        final id = Bubble.pinnedId;
        final note = id.isEmpty ? null : await NotesRepo.instance.get(id);
        if (note == null) {
          HomeScreen.jumpTo.value = 'library';
          return;
        }
        nav.push(MaterialPageRoute<void>(builder: (_) => NoteEditorScreen(note: note)));
      default:
        // 'library' | 'search' | 'folders' (anything else lands on the Library).
        // The tabs live on the first screen: what is open on top is closed
        // (it saves itself) — but never a recorder that is running.
        if (!CaptureTrigger.isCaptureOpen && !RecorderService.instance.isRecording) nav.popUntil((r) => r.isFirst);
        HomeScreen.jumpTo.value = which;
    }
  }

  void _syncPalette() {
    final b = WidgetsBinding.instance.platformDispatcher.platformBrightness;
    final mode = Prefs.themeMode.value;
    ByteColors.dark = mode == 'dark' || (mode == 'system' && b == Brightness.dark);
    SystemChrome.setSystemUIOverlayStyle(
      ByteColors.dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      key: ValueKey('byte-${ByteColors.dark ? 'dark' : 'light'}'),
      title: 'BYTE',
      navigatorKey: CaptureTrigger.navigatorKey,
      debugShowCheckedModeBanner: false,
      theme: ByteTheme.light(),
      darkTheme: ByteTheme.dark(),
      themeMode: switch (Prefs.themeMode.value) { 'dark' => ThemeMode.dark, 'light' => ThemeMode.light, _ => ThemeMode.system },
      // The lock wraps the home; the voice-note recorder pushed by the
      // neckband still works while locked.
      // Every touch is noted, so heavy background work can step aside
      // while you use the screen (see UserBusy).
      builder: (context, child) => Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) => UserBusy.touch(),
        onPointerMove: (_) => UserBusy.touch(),
        onPointerUp: (_) => UserBusy.touch(),
        child: child ?? const SizedBox.shrink(),
      ),
      home: Prefs.onboardingDone
          ? const LockGate(child: HomeScreen())
          : const SetupFlowScreen(),
    );
  }
}
