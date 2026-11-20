import 'package:flutter/material.dart';

import '../../core/cloud_sync.dart';
import '../../core/prefs.dart';
import '../../shared/byte_mascot.dart';
import '../../shared/lock_gate.dart';
import '../../shared/theme.dart';
import '../../shared/ui.dart';
import '../home/home_screen.dart';
import '../library/library_repo.dart';
import '../notes/notes_repo.dart';

/// First run: one page that says what BYTE does, and you are in.
/// Nothing to type, nothing to configure before you can use it.
///
/// On a new phone there is a second way in: "I used BYTE before" signs in to
/// Google, finds the copy BYTE kept in Drive and brings everything back — one
/// step, where it used to be a walk through Settings.
class SetupFlowScreen extends StatefulWidget {
  const SetupFlowScreen({super.key});

  @override
  State<SetupFlowScreen> createState() => _SetupFlowScreenState();
}

class _SetupFlowScreenState extends State<SetupFlowScreen> {
  bool _saving = false;

  /// BYTE holds nothing yet on this phone: bringing a copy back cannot
  /// replace anything. (This page can also be opened again from Settings,
  /// with a full library — then the offer is not shown.)
  bool _empty = false;

  /// What "bring everything back" is doing right now, in words.
  String _status = '';

  @override
  void initState() {
    super.initState();
    _lookIfEmpty();
  }

  Future<void> _lookIfEmpty() async {
    try {
      // Only on the very first run (this page can be opened again from
      // Settings — never then), and only with nothing kept, binned or private.
      if (Prefs.onboardingDone) return;
      final things = await LibraryRepo.instance.total();
      final hidden = await LibraryRepo.instance.total(private: true);
      final binned = await LibraryRepo.instance.deletedCount();
      final binnedHidden = await LibraryRepo.instance.deletedCount(private: true);
      if (mounted) setState(() => _empty = things == 0 && hidden == 0 && binned == 0 && binnedHidden == 0);
    } catch (e) {
      debugPrint('[welcome] $e');
    }
  }

  Future<void> _finish() async {
    if (_saving) return;
    setState(() => _saving = true);
    await _goIn();
  }

  Future<void> _goIn() async {
    await Prefs.setOnboardingDone(true);
    if (!mounted) return;
    // Same root as app.dart: Home behind the app lock (a bare HomeScreen would drop the lock until restart).
    Navigator.of(context).pushAndRemoveUntil(MaterialPageRoute<void>(builder: (_) => const LockGate(child: HomeScreen())), (_) => false);
  }

  /// The recovery key, typed in: only asked when it was not kept in Drive.
  Future<String?> _askKey() async {
    final ctl = TextEditingController();
    final key = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Recovery key'),
        content: TextField(controller: ctl, autofocus: true, decoration: const InputDecoration(hintText: 'The 64-character key from the old phone')),
        actions: [
          TextButton(style: inlineButton, onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(style: inlineButton, onPressed: () => Navigator.pop(ctx, ctl.text), child: const Text('Use key')),
        ],
      ),
    );
    // The dialog is still closing for a moment and uses the controller meanwhile.
    Future<void>.delayed(const Duration(seconds: 1), ctl.dispose);
    return key;
  }

  /// "I used BYTE before": sign in to Google, find the copy in Drive, bring
  /// it back, and open BYTE with everything in it.
  Future<void> _bringBack() async {
    if (_saving) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() {
      _saving = true;
      _status = 'Signing in to Google…';
    });
    // Signed in but nothing brought back must not be left behind: the phone
    // would then be connected to Drive with an empty BYTE.
    final wasConnected = await CloudSync.connected();
    var back = false;
    // The automatic backup waits meanwhile (see CloudSync.holdAuto).
    CloudSync.holdAuto = true;
    try {
      try {
        await CloudSync.signIn();
      } catch (e) {
        debugPrint('[welcome] sign in: $e');
        messenger.showSnackBar(const SnackBar(content: Text('The Google sign-in did not finish. Try again.')));
        return;
      }
      if (!mounted) return;
      setState(() => _status = 'Looking in your Google Drive…');
      final inv = await CloudSync.inventory();
      if (!mounted) return;
      if (!inv.hasVault) {
        messenger.showSnackBar(const SnackBar(
          duration: Duration(seconds: 6),
          content: Text('This Google account has no BYTE copy in Drive. Try the account of your old phone, or tap Start to begin fresh.'),
        ));
        return;
      }
      String? key;
      if (!inv.hasKey) {
        key = await _askKey();
        if (key == null || !mounted) return;
      }
      final r = await CloudSync.restore(
        recoveryKey: key?.replaceAll(RegExp(r'[^0-9a-fA-F]'), ''),
        onStatus: (s) {
          // (The download is said as it is; the rest in one plain line.)
          if (mounted) setState(() => _status = s.startsWith('Downloading') ? s : 'Putting everything in place…');
        },
      );
      back = true;
      // Every list reads the vault that is in place now.
      LibraryRepo.instance.touch();
      NotesRepo.instance.revision.value++;
      messenger.showSnackBar(SnackBar(
        duration: const Duration(seconds: 6),
        content: Text('Your BYTE is back: ${r.items} things. Settings such as the app lock start fresh on this phone.'),
      ));
      await _goIn();
    } catch (e) {
      debugPrint('[welcome] bring back: $e');
      final why = e is CloudNeedsKey
          ? 'That recovery key does not open this copy. Check it and try again.'
          : e is StateError
              ? 'BYTE is busy with Google Drive. Try again in a minute.'
              : 'Could not bring it back. Check the internet and try again — it carries on from where it stopped.';
      if (mounted) messenger.showSnackBar(SnackBar(duration: const Duration(seconds: 6), content: Text(why)));
    } finally {
      CloudSync.holdAuto = false;
      if (!back && !wasConnected) {
        try {
          await CloudSync.signOut();
        } catch (e) {
          debugPrint('[welcome] sign out: $e');
        }
      }
      if (mounted) {
        setState(() {
          _saving = false;
          _status = '';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    // (While everything is being brought back, Back does not leave the page.)
    return PopScope(
      canPop: !_saving,
      child: Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(0, 24, 0, 8),
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: ByteSpace.page),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const ByteMascot(size: 44),
                        const SizedBox(height: 18),
                        Text("Hi. I'm BYTE.", style: tt.displaySmall),
                        const SizedBox(height: 10),
                        Text(
                          'I keep your photos, videos, documents, voice notes and notes in one place, and find any of them by a single word.',
                          style: tt.bodyMedium?.copyWith(color: ByteColors.textDim),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  Well(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _row(Icons.add_circle_outline_rounded, 'Add with the + button, or share to BYTE from any app.'),
                        _row(Icons.search_rounded, 'I read the words inside photos and every page of a PDF, so one word is enough to find it.'),
                        _row(Icons.cloud_outlined, 'Connect Google Drive (the Drive pill on the Library) and photos and videos stop filling this phone.'),
                        _row(Icons.delete_outline_rounded, 'Anything you delete waits 30 days in the Bin. Nothing is lost by a slip.', last: true),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: ByteSpace.page),
                    child: Text(
                      'Three tabs: Library is everything you saved, Search looks inside all of it, Folders is where things are filed.',
                      style: tt.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
            // What "bring everything back" is doing, while it runs.
            if (_status.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(ByteSpace.page, 0, ByteSpace.page, 8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const LinearProgressIndicator(minHeight: 2),
                    const SizedBox(height: 8),
                    Text(_status, style: tt.bodySmall, maxLines: 2, overflow: TextOverflow.ellipsis),
                  ],
                ),
              ),
            // One primary action — and, on a phone that holds nothing yet, the
            // way back in for someone who used BYTE before.
            Padding(
              padding: EdgeInsets.fromLTRB(ByteSpace.page, 4, ByteSpace.page, _empty ? 4 : 16),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _saving ? null : _finish,
                  child: const Text('Start'),
                ),
              ),
            ),
            if (_empty)
              Padding(
                padding: const EdgeInsets.fromLTRB(ByteSpace.page, 0, ByteSpace.page, 12),
                child: TextButton(
                  onPressed: _saving ? null : _bringBack,
                  child: const Text('I used BYTE before. Bring everything back'),
                ),
              ),
          ],
        ),
      ),
    ),
    );
  }

  Widget _row(IconData i, String t, {bool last = false}) => Padding(
        padding: EdgeInsets.only(bottom: last ? 0 : 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(i, size: 18, color: ByteColors.accentDim),
            const SizedBox(width: 10),
            Expanded(child: Text(t, style: Theme.of(context).textTheme.bodyMedium)),
          ],
        ),
      );
}
