import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/app_lock.dart';
import '../../core/backup.dart';
import '../../core/bubble.dart';
import '../../core/capture_trigger.dart';
import '../../core/db.dart';
import '../../core/exporter.dart';
import '../../core/prefs.dart';
import '../../core/private_space.dart';
import '../../core/storage_info.dart';
import '../../core/vault_key.dart';
import '../../shared/motion.dart';
import '../../shared/theme.dart';
import '../../shared/ui.dart';
import '../chat/ai_settings_screen.dart';
import '../onboarding/setup_flow_screen.dart';
import '../voice/live_words.dart';
import 'cloud_screen.dart';
import 'gallery_screen.dart';
import 'heard_words_screen.dart';
import 'security_screen.dart';
import 'storage_screen.dart';

/// Settings — one short page. Where your things are kept (Google Drive,
/// space on the phone), how BYTE is locked, the backups, and how it looks.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> with WidgetsBindingObserver {
  bool? _encrypted;

  /// The floating bubble: is it on, and was it asked for while Android's
  /// "display over other apps" page was open (then it turns on when you are back).
  bool _bubbleOn = false;
  bool _bubbleAsked = false;
  String _exportStatus = '';
  bool _exporting = false;
  String _backupStatus = '';
  bool _backing = false;
  DateTime? _lastBackup;
  String? _lastBackupName;
  bool _autoBackup = true;
  String? _cloudUrl;
  DateTime? _cloudAt;
  String? _cloudErr;

  @override
  void initState() {
    super.initState();
    AppDb.instance.isEncryptedOnDisk().then((v) {
      if (mounted) setState(() => _encrypted = v);
    });
    BackupService.changed.addListener(_loadBackup);
    WidgetsBinding.instance.addObserver(this);
    _loadBackup();
    _measureStorage();
    _loadBubble();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _loadBubble();
  }

  Future<void> _loadBubble() async {
    var (allowed, on) = await Bubble.state();
    // Back from the permission page with the permission given: finish turning it on.
    if (_bubbleAsked && allowed && !on) on = await Bubble.setOn(true);
    if (allowed) _bubbleAsked = false;
    if (mounted) setState(() => _bubbleOn = on && allowed);
  }

  Future<void> _setBubble(bool want) async {
    if (!want) {
      _bubbleAsked = false;
      await Bubble.setOn(false);
      if (mounted) setState(() => _bubbleOn = false);
      return;
    }
    final (allowed, _) = await Bubble.state();
    if (!mounted) return;
    if (!allowed) {
      final go = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('One permission first'),
          content: const Text(
            'To float over other apps, Android needs "Display over other apps" switched on for BYTE. On the next page, choose BYTE if a list is shown, and switch it on. Then come back: the bubble appears by itself.\n\n'
            'On Xiaomi phones one more switch may be needed, or tapping the bubble does nothing: phone Settings, Apps, BYTE, Other permissions, "Display pop-up windows while running in the background".',
          ),
          actions: [
            TextButton(style: inlineButton, onPressed: () => Navigator.pop(ctx, false), child: const Text('Not now')),
            FilledButton(style: inlineButton, onPressed: () => Navigator.pop(ctx, true), child: const Text('Open that page')),
          ],
        ),
      );
      if (go != true) return;
      _bubbleAsked = true;
      await Bubble.setOn(true); // opens the Android page
      return;
    }
    // Its small "BYTE bubble is on" notification needs this on Android 13+.
    await Bubble.askNotifications();
    final on = await Bubble.setOn(true);
    if (mounted) setState(() => _bubbleOn = on);
  }

  /// Puts the "BYTE checklist" button in the phone's control centre: the phone
  /// asks by itself where it can; where it cannot, the steps are shown.
  Future<void> _checklistButton() async {
    final messenger = ScaffoldMessenger.of(context);
    final answer = await Bubble.addTile();
    if (!mounted) return;
    if (answer == 'added') {
      messenger.showSnackBar(const SnackBar(content: Text('Added. Swipe down from the top right of the screen and tap "BYTE checklist".')));
    } else if (answer == 'there') {
      messenger.showSnackBar(const SnackBar(content: Text('It is already in your control centre. Swipe down from the top right of the screen.')));
    } else {
      // Also after "no": the phone stops asking after a few of those.
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Add it by hand'),
          content: const Text(
            '1. Swipe down from the top right of the screen.\n'
            '2. Tap the edit button at the top (a small pencil, or a square with dots).\n'
            '3. Find "BYTE checklist" among the buttons that are not added yet.\n'
            '4. Tap it (or drag it up), then tap Done.',
          ),
          actions: [FilledButton(style: inlineButton, onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
        ),
      );
    }
  }

  /// Puts the checklist on the home screen (a widget).
  Future<void> _checklistWidget() async {
    final messenger = ScaffoldMessenger.of(context);
    final asked = await Bubble.addWidget();
    if (!mounted) return;
    if (asked) {
      // The phone's own "Add to home screen" box takes over (some phones show none).
      messenger.showSnackBar(const SnackBar(
        duration: Duration(seconds: 6),
        content: Text('If nothing appeared: press and hold an empty spot on the home screen, tap Widgets, then BYTE.'),
      ));
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add it by hand'),
        content: const Text(
          '1. Go to the home screen.\n'
          '2. Press and hold an empty spot, then tap Widgets.\n'
          '3. Find BYTE and pick "BYTE checklist".\n'
          '4. Drag it to where you want it.',
        ),
        actions: [FilledButton(style: inlineButton, onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
      ),
    );
  }

  static const _voiceLanguages = [('en-IN', 'English (India)'), ('ta-IN', 'Tamil'), ('hi-IN', 'Hindi'), ('en-US', 'English (US)'), ('en-GB', 'English (UK)')];

  static String _voiceLanguageName(String code) {
    for (final (c, name) in _voiceLanguages) {
      if (c == code) return name;
    }
    return code;
  }

  Future<void> _liveWords() async {
    final can = await LiveWords.supported();
    if (!mounted) return;
    if (!can) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Not on this phone yet'),
          content: const Text('Writing the words while you talk needs Android\'s on-device speech engine (Android 13 or newer, with "Speech Recognition & Synthesis from Google" installed and up to date).\n\nYour voice notes are recorded and saved all the same; only the words are missing.'),
          actions: [FilledButton(style: inlineButton, onPressed: () => Navigator.pop(ctx), child: const Text('Got it'))],
        ),
      );
      return;
    }
    // Which language you speak in your voice notes.
    const langs = _voiceLanguages;
    final now = Prefs.voiceLocale;
    final pick = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(ByteSpace.page, 16, ByteSpace.page, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Which language do you speak in voice notes?', style: Theme.of(ctx).textTheme.titleMedium),
              ),
            ),
            for (final (code, name) in langs)
              ListTile(
                title: Text(name),
                trailing: code == now ? Icon(Icons.check_rounded, color: ByteColors.accentDim) : null,
                onTap: () => Navigator.pop(ctx, code),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (pick == null) return;
    await Prefs.setVoiceLocale(pick);
    final started = await LiveWords.downloadLanguage(locale: pick);
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(started
          ? 'Set. If Android offers this language for offline speech and it is not on the phone yet, it asks to download it. If no words appear in your next voice note, the language is not available.'
          : 'Set. Android could not start the language download; words appear only if the language is already on the phone.'),
    ));
  }

  @override
  void dispose() {
    BackupService.changed.removeListener(_loadBackup);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _loadBackup() async {
    final last = await BackupService.lastBackup();
    final name = await BackupService.lastBackupName();
    final auto = await BackupService.autoEnabled();
    final cloud = await BackupService.cloudUrl();
    final cloudAt = await BackupService.lastCloudAt();
    final cloudErr = await BackupService.lastCloudError();
    if (!mounted) return;
    setState(() {
      _lastBackup = last;
      _lastBackupName = name;
      _autoBackup = auto;
      _cloudUrl = cloud;
      _cloudAt = cloudAt;
      _cloudErr = cloudErr;
    });
  }

  Future<void> _cloudSetup() async {
    final ctl = TextEditingController(text: _cloudUrl ?? '');
    String testStatus = '';
    final result = await showDialog<String?>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('Cloud copy'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Every backup is also uploaded here. Paste an Azure Blob container SAS URL '
                '(with Create + Write), or any URL that accepts PUT.',
                style: Theme.of(ctx).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: ctl,
                maxLines: 4,
                style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                decoration: const InputDecoration(hintText: 'https://<account>.blob.core.windows.net/<container>?sv=…'),
              ),
              if (testStatus.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(testStatus, style: Theme.of(ctx).textTheme.bodySmall?.copyWith(color: testStatus.startsWith('OK') ? ByteColors.accentDim : ByteColors.danger)),
              ],
            ],
          ),
          actions: [
            TextButton(style: inlineButton, onPressed: () => Navigator.pop(ctx, ''), child: const Text('Remove')),
            TextButton(
              style: inlineButton,
              onPressed: () async {
                setD(() => testStatus = 'Testing…');
                try {
                  await BackupService.testCloud(ctl.text.trim());
                  setD(() => testStatus = 'OK — BYTE can write there.');
                } catch (e) {
                  setD(() => testStatus = 'Failed: $e');
                }
              },
              child: const Text('Test'),
            ),
            FilledButton(
              style: inlineButton,
              onPressed: () => Navigator.pop(ctx, ctl.text.trim()),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    Future<void>.delayed(const Duration(seconds: 1), ctl.dispose);
    if (result == null) return;
    await BackupService.setCloudUrl(result.isEmpty ? null : result);
  }

  Future<void> _backupNow() async {
    if (_backing) return;
    setState(() {
      _backing = true;
      _backupStatus = 'Starting…';
    });
    try {
      final where = await BackupService.backupNow(
        onStatus: (s) {
          if (mounted) setState(() => _backupStatus = s);
        },
      );
      if (mounted) setState(() => _backupStatus = 'Saved · $where');
    } catch (e) {
      if (mounted) setState(() => _backupStatus = 'Failed: $e');
    } finally {
      if (mounted) setState(() => _backing = false);
    }
  }

  Future<void> _restore() async {
    final messenger = ScaffoldMessenger.of(context);
    File? file;
    if (Platform.isAndroid) {
      file = await BackupService.pickBackupFile();
    } else {
      final ctl = TextEditingController();
      final path = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Restore from backup'),
          content: TextField(
            controller: ctl,
            decoration: const InputDecoration(hintText: r'Full path to byte-backup-….zip'),
          ),
          actions: [
            TextButton(style: inlineButton, onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(
              style: inlineButton,
              onPressed: () => Navigator.pop(ctx, ctl.text.trim()),
              child: const Text('Restore'),
            ),
          ],
        ),
      );
      Future<void>.delayed(const Duration(seconds: 1), ctl.dispose);
      if (path == null || path.isEmpty) return;
      file = File(path);
    }
    if (file == null) return;
    final f = file;
    if (!mounted) return;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Replace everything?'),
        content: Text(
          'Everything in BYTE on this phone will be replaced by the backup.\n\n${f.path.split(RegExp(r'[\\/]')).last}',
          style: Theme.of(ctx).textTheme.bodyMedium?.copyWith(color: ByteColors.textDim),
        ),
        actions: [
          TextButton(style: inlineButton, onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
            style: inlineButton,
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Restore', style: TextStyle(color: ByteColors.danger)),
          ),
        ],
      ),
    );
    if (ok != true) return;

    String? key;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        setState(() => _backupStatus = 'Restoring…');
        final r = await BackupService.restore(
          f,
          recoveryKey: key,
          onStatus: (s) {
            if (mounted) setState(() => _backupStatus = s);
          },
        );
        if (!mounted) return;
        setState(() => _backupStatus = 'Restored · ${r.items} items, ${r.recordings} recordings');
        messenger.showSnackBar(const SnackBar(content: Text('Restored. Restart BYTE to see everything.')));
        return;
      } on RestoreNeedsKey {
        if (!mounted) return;
        key = await _askRecoveryKey();
        if (key == null) {
          setState(() => _backupStatus = 'Restore cancelled');
          return;
        }
      } catch (e) {
        if (mounted) setState(() => _backupStatus = 'Restore failed: $e');
        return;
      }
    }
  }

  Future<String?> _askRecoveryKey() async {
    final ctl = TextEditingController();
    final v = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Recovery key needed'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'This backup was made on another device (or after a reset). '
              'Enter the 64-character recovery key you wrote down.',
              style: Theme.of(ctx).textTheme.bodyMedium?.copyWith(color: ByteColors.textDim),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: ctl,
              maxLines: 3,
              style: const TextStyle(fontFamily: 'monospace'),
              decoration: const InputDecoration(hintText: 'ABCD 1234 …'),
            ),
          ],
        ),
        actions: [
          TextButton(style: inlineButton, onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            style: inlineButton,
            onPressed: () => Navigator.pop(
              ctx,
              ctl.text.replaceAll(RegExp(r'[^0-9a-fA-F]'), '').toLowerCase(),
            ),
            child: const Text('Use key'),
          ),
        ],
      ),
    );
    Future<void>.delayed(const Duration(seconds: 1), ctl.dispose);
    if (v == null || v.length != 64) return null;
    return v;
  }

  String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'just now';
    if (d.inHours < 1) return '${d.inMinutes} min ago';
    if (d.inDays < 1) return '${d.inHours} h ago';
    return '${d.inDays} d ago';
  }

  Future<void> _showRecoveryKey() async {
    // This key also resets the PIN of the private space: once there is one,
    // the phone's own lock (fingerprint, face or screen PIN) is asked first.
    if (await PrivateSpace.isSetUp() && await AppLock.deviceLockSet()) {
      if (!await AppLock.biometric(reason: 'Confirm it is you to show the recovery key')) return;
    }
    final key = await VaultKey.get();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Recovery key'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'This is the only way to open your vault on another device or '
              'after a reset. Write it down and keep it somewhere safe. '
              'BYTE cannot recover it for you.',
              style: Theme.of(ctx).textTheme.bodyMedium?.copyWith(color: ByteColors.textDim),
            ),
            const SizedBox(height: 14),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: ByteColors.surface2,
                borderRadius: BorderRadius.circular(12),
              ),
              child: SelectableText(
                VaultKey.pretty(key),
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 15,
                  height: 1.6,
                  letterSpacing: 1,
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            style: inlineButton,
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: key));
              if (ctx.mounted) {
                ScaffoldMessenger.of(ctx).showSnackBar(
                  const SnackBar(content: Text('Copied. Paste it somewhere safe, then clear your clipboard.')),
                );
              }
            },
            child: const Text('Copy'),
          ),
          TextButton(
            style: inlineButton,
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }

  Future<void> _export() async {
    if (_exporting) return;
    setState(() {
      _exporting = true;
      _exportStatus = 'Starting…';
    });
    try {
      final file = await Exporter.exportAll(
        onStatus: (s) {
          if (mounted) setState(() => _exportStatus = s);
        },
      );
      final kb = (await file.length() / 1024).round();
      if (!mounted) return;
      setState(() => _exportStatus = 'Done · $kb KB');
      if (Platform.isAndroid || Platform.isIOS) {
        await SharePlus.instance.share(
          ShareParams(files: [XFile(file.path)], text: 'BYTE export'),
        );
      } else {
        _snack('Saved to ${file.path}');
      }
    } catch (e) {
      if (mounted) setState(() => _exportStatus = 'Failed: $e');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// The headset button: Android asks once for "Nearby devices"; the rest is
  /// one choice in the phone's own settings, which only you can make.
  Future<void> _headsetButton() async {
    final ok = await CaptureTrigger.requestHeadsetPermission();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(ok ? 'One more step' : 'BYTE needs "Nearby devices"'),
        content: Text(
          ok
              ? 'In your phone\'s Settings, open Apps, then Default apps, then Digital assistant app, and choose BYTE.\n\n'
                  'After that, a long press on the neckband or earbud button starts a voice note — even when the phone is locked. Press again to stop and save.'
              : 'Without it BYTE cannot take over from the headset and hear you. Allow "Nearby devices" for BYTE in the phone\'s Settings, then tap this row again.',
        ),
        actions: [
          FilledButton(style: inlineButton, onPressed: () => Navigator.pop(ctx), child: const Text('Got it')),
        ],
      ),
    );
  }

  StorageInfo? _storage;

  Future<void> _measureStorage() async {
    final i = await StorageInfo.measure();
    if (mounted) setState(() => _storage = i);
  }

  static String _storageText(StorageInfo i) =>
      '${StorageInfo.fmt(i.total)} in all — recordings ${StorageInfo.fmt(i.recordings)}, library ${StorageInfo.fmt(i.libraryFiles)}, vault ${StorageInfo.fmt(i.vault)}, cache ${StorageInfo.fmt(i.cache)}';

  /// Colours, motion and haptics, in a glass sheet.
  Future<void> _appearance() async {
    await showGlassSheet<void>(
      context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(ByteSpace.page, 4, ByteSpace.page, 6),
              child: Align(alignment: Alignment.centerLeft, child: Text('Appearance', style: Theme.of(ctx).textTheme.titleLarge)),
            ),
            const SectionLabel('Colours', top: 8),
            for (final (id, label, note) in const [('system', 'Same as the phone', 'Follows the phone\'s dark mode'), ('light', 'Light', 'White and green, always'), ('dark', 'Dark', 'Easy on the eyes at night')])
              ByteRow(
                title: label,
                subtitle: note,
                titleWeight: FontWeight.w600,
                trailing: AnimatedOpacity(
                  opacity: Prefs.themeModeValue == id ? 1 : 0,
                  duration: Motion.d(ctx, 200),
                  child: Icon(Icons.check_rounded, color: ByteColors.accentDim),
                ),
                onTap: () async {
                  await Prefs.setThemeMode(id);
                  if (ctx.mounted) set(() {});
                  if (mounted) setState(() {});
                },
              ),
            const SectionLabel('Motion', top: 16),
            for (final (id, label, note) in const [('full', 'Full', 'Every slide, spring and wave'), ('calm', 'Calm', 'The same, a little quicker and quieter'), ('off', 'Off', 'No animations')])
              ByteRow(
                title: label,
                subtitle: note,
                titleWeight: FontWeight.w600,
                trailing: AnimatedOpacity(
                  opacity: Motion.mode.value == id ? 1 : 0,
                  duration: Motion.d(ctx, 200),
                  child: Icon(Icons.check_rounded, color: ByteColors.accentDim),
                ),
                onTap: () async {
                  await Motion.setMode(id);
                  if (ctx.mounted) set(() {});
                  if (mounted) setState(() {});
                },
              ),
            ByteRow(
              icon: Icons.vibration_rounded,
              title: 'Haptics',
              subtitle: 'A small click under every tap',
              titleWeight: FontWeight.w600,
              trailing: ByteSwitch(
                value: Motion.haptics.value,
                onChanged: (v) async {
                  await Motion.setHaptics(v);
                  if (ctx.mounted) set(() {});
                },
              ),
              hairline: false,
            ),
          ],
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  void _push(Widget page) {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page)).then((_) {
      if (mounted) _measureStorage();
    });
  }

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final look = '${switch (Prefs.themeModeValue) { 'dark' => 'Dark', 'light' => 'Light', _ => 'Same as the phone' }}, motion ${switch (Motion.mode.value) { 'off' => 'off', 'calm' => 'calm', _ => 'full' }}';
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          const SectionLabel('Where your things are kept', top: 8),
          ByteList(
            children: [
              ByteRow(
                icon: Icons.cloud_outlined,
                tone: 'act',
                title: 'Google Drive',
                subtitle: 'Photos and videos live in your own Drive; a copy of everything else goes there every day',
                chevron: true,
                onTap: () => _push(const CloudScreen()),
              ),
              ByteRow(
                icon: Icons.photo_library_outlined,
                title: 'Phone gallery',
                subtitle: 'Your phone\'s photos inside BYTE, copies in Drive, free up space',
                chevron: true,
                onTap: () => _push(const GalleryScreen()),
              ),
              ByteRow(
                icon: Icons.storage_rounded,
                title: 'Space on this phone',
                subtitle: _storage == null ? 'What takes space, and how to free it' : _storageText(_storage!),
                chevron: true,
                onTap: () => _push(const StorageScreen()),
              ),
            ],
          ),
          const SectionLabel('Lock'),
          ByteList(
            children: [
              ByteRow(
                icon: Icons.lock_outline_rounded,
                title: 'App lock',
                subtitle: switch (Prefs.appLockMode) { 'biometric' => 'Fingerprint / face', 'pin_bio' => 'PIN + fingerprint / face', _ => 'Off — BYTE opens straight away' },
                chevron: true,
                onTap: () => _push(const SecurityScreen()),
              ),
              ByteRow(
                icon: _encrypted == false ? Icons.lock_open : Icons.enhanced_encryption_outlined,
                tone: _encrypted == false ? 'danger' : 'plain',
                title: _encrypted == null
                    ? 'Checking the vault…'
                    : _encrypted!
                        ? 'The vault is encrypted'
                        : 'The vault is not encrypted',
                subtitle: 'Notes and the index of everything are scrambled on this phone; the key stays in the phone\'s secure store',
              ),
              ByteRow(
                icon: Icons.key,
                title: 'Recovery key',
                subtitle: 'The only way to open your vault on a new phone. Write it down once.',
                chevron: true,
                onTap: _showRecoveryKey,
              ),
            ],
          ),
          const SectionLabel('Backup'),
          ByteList(
            children: [
              ByteRow(
                icon: Icons.cloud_done_outlined,
                tone: _lastBackup == null ? 'danger' : 'act',
                title: 'Back up now',
                subtitle: _backupStatus.isNotEmpty
                    ? _backupStatus
                    : _lastBackup == null
                        ? 'No backup yet. Uninstalling BYTE would lose everything.'
                        : 'Last backup ${_ago(_lastBackup!)} · ${_lastBackupName ?? ''}',
                trailing: _backing ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : null,
                chevron: !_backing,
                onTap: _backupNow,
              ),
              ByteRow(
                icon: Icons.autorenew_rounded,
                title: 'Auto backup',
                subtitle: Platform.isAndroid ? 'Once a day when you open BYTE → Downloads/BYTE (kept after uninstall)' : 'Once a day when you open BYTE → Downloads/BYTE backups',
                trailing: ByteSwitch(value: _autoBackup, onChanged: (v) => BackupService.setAuto(v)),
              ),
              ByteRow(
                icon: Icons.send_rounded,
                title: 'Send backup…',
                subtitle: 'Share the latest backup to Gmail, Drive, WhatsApp, your laptop',
                chevron: true,
                onTap: () => BackupService.shareLatest(),
              ),
              ByteRow(
                icon: Icons.settings_backup_restore_rounded,
                title: 'Restore from backup…',
                subtitle: 'Pick a byte-backup-….zip. Replaces what\'s on this phone.',
                chevron: true,
                onTap: _restore,
              ),
              ByteRow(
                icon: Icons.archive_outlined,
                title: 'Export everything',
                subtitle: _exportStatus.isEmpty ? 'A plain ZIP anyone can open: notes as text, recordings, a list of everything' : _exportStatus,
                trailing: _exporting ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : null,
                chevron: !_exporting,
                onTap: _export,
              ),
              ByteRow(
                icon: Icons.cloud_upload_outlined,
                tone: _cloudErr != null ? 'danger' : 'plain',
                title: 'Your own storage (advanced)',
                subtitle: _cloudUrl == null || _cloudUrl!.isEmpty
                    ? 'Off — also upload each backup to an Azure Blob or any PUT URL'
                    : _cloudErr != null
                        ? 'Last upload failed: $_cloudErr'
                        : _cloudAt == null
                            ? 'Set up — uploads with the next backup'
                            : 'Last upload ${_ago(_cloudAt!)}',
                chevron: true,
                onTap: _cloudSetup,
              ),
            ],
          ),
          if (Platform.isAndroid) ...[
            const SectionLabel('Voice notes'),
            ByteList(
              children: [
                ByteRow(
                  icon: Icons.headset_mic_outlined,
                  title: 'Record with the headset button',
                  subtitle: 'A long press on the neckband or earbuds starts a voice note, even when the phone is locked',
                  chevron: true,
                  onTap: _headsetButton,
                ),
                ByteRow(
                  icon: Icons.bubble_chart_outlined,
                  title: 'Floating BYTE bubble',
                  subtitle: 'A small button over every app. Tap it for a voice note, a new note, a checklist, search, or your pinned list',
                  trailing: ByteSwitch(value: _bubbleOn, onChanged: _setBubble),
                ),
                ByteRow(
                  icon: Icons.checklist_rounded,
                  title: 'Checklist button in the control centre',
                  subtitle: 'A BYTE button beside Wi-Fi and the torch. One tap shows your checklist over any app, to tick things off',
                  chevron: true,
                  onTap: _checklistButton,
                ),
                ByteRow(
                  icon: Icons.widgets_outlined,
                  title: 'Checklist on the home screen',
                  subtitle: 'A widget with the things still to do. A tap ticks one',
                  chevron: true,
                  onTap: _checklistWidget,
                ),
                ByteRow(
                  icon: Icons.subtitles_outlined,
                  title: 'Words while you talk',
                  subtitle: 'In the quick recorder (+, the bubble, the headset button) BYTE writes what you say under the recording, on the phone, with no internet. Tap to choose your language (now ${_voiceLanguageName(Prefs.voiceLocale)})',
                  chevron: true,
                  onTap: _liveWords,
                ),
                ByteRow(
                  icon: Icons.spellcheck_rounded,
                  title: 'Words BYTE learned',
                  subtitle: 'Fix a wrong word in a voice note once; BYTE gets it right next time',
                  chevron: true,
                  onTap: () => _push(const HeardWordsScreen()),
                ),
              ],
            ),
          ],
          const SectionLabel('BYTE'),
          ByteList(
            children: [
              ByteRow(
                icon: Icons.dark_mode_outlined,
                title: 'Appearance',
                subtitle: look,
                chevron: true,
                onTap: _appearance,
              ),
              ByteRow(
                icon: Icons.key_rounded,
                title: 'AI key (optional)',
                subtitle: 'Only for the "Tidy" button on a voice note. Everything else works without it',
                chevron: true,
                onTap: () => _push(const AiSettingsScreen()),
              ),
              ByteRow(
                icon: Icons.restart_alt_rounded,
                title: 'Show the welcome again',
                subtitle: 'What BYTE does, in a few lines',
                chevron: true,
                onTap: () => _push(const SetupFlowScreen()),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(ByteSpace.page, 20, ByteSpace.page, 0),
            child: Text(
              'BYTE keeps your photos, videos, documents, voice notes and notes: sorted, searchable by any word inside them, and stored in your own Google Drive.',
              style: tt.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}
