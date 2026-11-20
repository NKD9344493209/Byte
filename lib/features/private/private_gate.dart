import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/app_lock.dart';
import '../../core/gallery.dart';
import '../../core/private_names.dart';
import '../../core/private_space.dart';
import '../../shared/motion.dart';
import '../../shared/theme.dart';

/// The door of the private space: choosing its PIN the first time, typing
/// it afterwards, and resetting a forgotten one with the recovery key.
class PrivateGate {
  PrivateGate._();

  /// Makes sure the private space is open. Shows the PIN screen when it is
  /// not. True when it is open afterwards.
  static Future<bool> ensure(BuildContext context) async {
    if (!PrivateSpace.supported) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Only on the phone'),
          content: const Text('The private space works in the Android app.'),
          actions: [FilledButton(style: inlineButton, onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
        ),
      );
      return false;
    }
    if (PrivateSpace.unlocked.value) return true;
    final ok = await Navigator.of(context).push<bool>(MaterialPageRoute<bool>(fullscreenDialog: true, builder: (_) => const _GateScreen()));
    return ok == true && PrivateSpace.unlocked.value;
  }

  /// "Make private" from the Library: asks, opens the space (PIN), moves the
  /// items in and closes the space again if it was closed before. True when
  /// at least one item was moved.
  static Future<bool> makePrivate(BuildContext context, List<String> ids) async {
    if (ids.isEmpty) return false;
    final messenger = ScaffoldMessenger.of(context);
    final n = ids.length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(n == 1 ? 'Make this private?' : 'Make $n items private?'),
        content: Text(
          '${n == 1 ? 'It leaves' : 'They leave'} your Library, Search and folders, and ${n == 1 ? 'shows' : 'show'} only in the private space (Folders, then Private), behind its own PIN. '
          '${n == 1 ? 'Its file is' : 'Their files are'} locked on the phone, and the copy in Google Drive is replaced by the locked one '
          '(the old copy waits 30 days in Drive\'s own Trash; a backup ZIP made earlier still has the file as it was).',
        ),
        actions: [
          TextButton(style: inlineButton, onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(style: inlineButton, onPressed: () => Navigator.pop(ctx, true), child: const Text('Make private')),
        ],
      ),
    );
    if (ok != true || !context.mounted) return false;
    final wasOpen = PrivateSpace.unlocked.value;
    if (!await ensure(context)) return false;
    messenger.showSnackBar(const SnackBar(content: Text('Making private…'), duration: Duration(minutes: 2)));
    PrivateMove r;
    try {
      r = await PrivateSpace.moveIn(ids);
    } catch (e) {
      debugPrint('[private] make private: $e');
      r = const PrivateMove();
    }
    // Files BYTE could not lock yet (it is still reading them, or they are
    // only in Drive and there is no internet) are locked at the next opening.
    final waiting = await PrivateSpace.unsealedCount();
    // Opened only for this: closed again.
    if (!wasOpen) PrivateSpace.lock();
    messenger.hideCurrentSnackBar();
    final failed = n - r.moved;
    messenger.showSnackBar(SnackBar(
      duration: const Duration(seconds: 7),
      content: Text(r.moved == 0
          ? 'Nothing could be made private.'
          : '${r.moved} item${r.moved == 1 ? ' is' : 's are'} private now.${failed > 0 ? ' $failed could not be moved.' : ''} Find ${r.moved == 1 ? 'it' : 'them'} in Folders, then Private.'
              '${waiting > 0 ? ' $waiting file${waiting == 1 ? ' is' : 's are'} hidden but not locked yet; BYTE locks ${waiting == 1 ? 'it' : 'them'} the next time you open the private space.' : ''}'),
    ));
    if (r.galleryOriginals.isNotEmpty) {
      // BYTE made its own (locked) copies. The originals are still in the
      // phone's gallery: Android asks once whether they may be deleted.
      final gone = await Gallery.deleteOriginals(r.galleryOriginals);
      if (!gone) {
        final g = r.galleryOriginals.length;
        messenger.showSnackBar(SnackBar(
          duration: const Duration(seconds: 8),
          content: Text('The ${g == 1 ? 'original is' : '$g originals are'} still in your phone\'s gallery. Delete ${g == 1 ? 'it' : 'them'} there if ${g == 1 ? 'it' : 'they'} should be only in the private space.'),
        ));
      }
    }
    return r.moved > 0;
  }

  /// A new PIN for the open space (asked twice). True when it was changed.
  static Future<bool> changePin(BuildContext context) async {
    if (!PrivateSpace.unlocked.value) return false;
    final ok = await Navigator.of(context).push<bool>(MaterialPageRoute<bool>(fullscreenDialog: true, builder: (_) => const _GateScreen(change: true)));
    return ok == true;
  }
}

enum _Step { loading, intro, choose, repeat, unlock, recovery }

class _GateScreen extends StatefulWidget {
  const _GateScreen({this.change = false});

  /// Only choose a new PIN (the space is open already).
  final bool change;

  @override
  State<_GateScreen> createState() => _GateScreenState();
}

class _GateScreenState extends State<_GateScreen> {
  _Step _step = _Step.loading;
  String _pin = '';
  String _first = '';
  String? _error;
  bool _busy = false;

  /// Set while a forgotten PIN is being reset: the recovery key that was typed.
  String? _recovery;
  final _recoveryText = TextEditingController();
  Timer? _waitTick;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _waitTick?.cancel();
    _recoveryText.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    if (widget.change) {
      setState(() => _step = _Step.choose);
      return;
    }
    final has = await PrivateSpace.isSetUp();
    if (!mounted) return;
    setState(() => _step = has ? _Step.unlock : _Step.intro);
    if (has) _watchWait();
  }

  /// While you have to wait after wrong PINs, the seconds count down.
  void _watchWait() {
    _waitTick?.cancel();
    if (PrivateSpace.waitLeft() <= 0) return;
    _waitTick = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      if (PrivateSpace.waitLeft() <= 0) t.cancel();
      setState(() {});
    });
  }

  void _digit(String d) {
    if (_busy || _pin.length >= 12) return;
    Haptics.confirm();
    setState(() {
      _pin += d;
      _error = null;
    });
  }

  void _back() {
    if (_busy || _pin.isEmpty) return;
    setState(() => _pin = _pin.substring(0, _pin.length - 1));
  }

  Future<void> _ok() async {
    final pin = _pin;
    if (_busy || !isValidPin(pin)) return;
    switch (_step) {
      case _Step.choose:
        if (isWeakPin(pin)) {
          setState(() {
            _pin = '';
            _error = 'That one is too easy to guess. Choose another.';
          });
          return;
        }
        setState(() {
          _first = pin;
          _pin = '';
          _step = _Step.repeat;
        });
      case _Step.repeat:
        if (pin != _first) {
          setState(() {
            _pin = '';
            _first = '';
            _step = _Step.choose;
            _error = 'The two were not the same. Choose again.';
          });
          return;
        }
        await _finishChoosing(pin);
      case _Step.unlock:
        await _tryUnlock(pin);
      case _Step.loading:
      case _Step.intro:
      case _Step.recovery:
        break;
    }
  }

  Future<void> _finishChoosing(String pin) async {
    setState(() => _busy = true);
    var ok = false;
    String? error;
    try {
      final recovery = _recovery;
      if (widget.change) {
        ok = await PrivateSpace.changePin(pin);
        if (!ok) error = 'The PIN could not be changed. Open the private space and try again.';
      } else if (recovery != null) {
        ok = await PrivateSpace.resetWithRecoveryKey(recovery, pin);
        if (!ok) error = 'That is not the recovery key of this vault. Check it and try again.';
      } else {
        await PrivateSpace.setUp(pin);
        ok = true;
      }
    } catch (e) {
      error = 'That did not work: $e';
    }
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _busy = false;
      _pin = '';
      _first = '';
      _error = error;
      _step = _recovery != null ? _Step.recovery : _Step.choose;
    });
  }

  Future<void> _tryUnlock(String pin) async {
    setState(() => _busy = true);
    final r = await PrivateSpace.unlock(pin);
    if (!mounted) return;
    if (r == UnlockResult.ok) {
      Navigator.of(context).pop(true);
      return;
    }
    Haptics.confirm();
    setState(() {
      _busy = false;
      _pin = '';
      _error = switch (r) {
        UnlockResult.wrong => 'Wrong PIN.',
        UnlockResult.wait => null,
        _ => 'The private space could not be opened. Close BYTE and try again.',
      };
    });
    _watchWait();
  }

  /// Resetting the PIN is for the owner of the phone: its own lock is asked
  /// first (when the phone has one).
  Future<void> _forgot() async {
    if (await AppLock.deviceLockSet()) {
      if (!await AppLock.biometric(reason: 'Confirm it is you to reset the private PIN')) return;
    }
    if (!mounted) return;
    setState(() {
      _step = _Step.recovery;
      _error = null;
      _pin = '';
    });
  }

  void _recoveryNext() {
    final hex = _recoveryText.text.replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
    if (hex.length != 64) {
      setState(() => _error = 'A recovery key has 64 letters and digits (16 groups of 4). This one has ${hex.length}.');
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _recovery = hex;
      _error = null;
      _pin = '';
      _step = _Step.choose;
    });
  }

  // ───────────── UI ─────────────

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final wait = _step == _Step.unlock ? PrivateSpace.waitLeft() : 0;
    final Widget body;
    switch (_step) {
      case _Step.loading:
        body = const SizedBox.shrink();
      case _Step.intro:
        body = _Intro(onStart: () => setState(() => _step = _Step.choose));
      case _Step.recovery:
        body = ListView(
          padding: const EdgeInsets.fromLTRB(ByteSpace.page, 12, ByteSpace.page, 24),
          children: [
            Text('Reset the private PIN', style: tt.headlineSmall),
            const SizedBox(height: 10),
            Text(
              'Type the recovery key of your vault: the 16 groups of 4 letters and digits BYTE showed you when it was set up. '
              'It is also in Settings, under Lock. Then you choose a new PIN. Nothing in the private space is lost.',
              style: tt.bodyMedium?.copyWith(color: ByteColors.textDim, height: 1.4),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _recoveryText,
              autofocus: true,
              autocorrect: false,
              enableSuggestions: false,
              minLines: 3,
              maxLines: 5,
              textCapitalization: TextCapitalization.characters,
              style: tt.bodyLarge?.copyWith(fontFeatures: const [FontFeature.tabularFigures()], letterSpacing: 1.2),
              decoration: const InputDecoration(hintText: 'ABCD 1234 …'),
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!, style: tt.bodyMedium?.copyWith(color: ByteColors.danger)),
            ],
            const SizedBox(height: 16),
            FilledButton(onPressed: _recoveryNext, child: const Text('Next')),
          ],
        );
      case _Step.choose:
      case _Step.repeat:
      case _Step.unlock:
        final title = switch (_step) {
          _Step.choose => widget.change || _recovery != null ? 'Choose a new PIN' : 'Choose a PIN',
          _Step.repeat => 'Type it once more',
          _ => 'Private space',
        };
        final hint = switch (_step) {
          _Step.choose => '4 to 12 digits. Longer is safer. Not the PIN of your phone.',
          _Step.repeat => 'So a slip of the finger cannot lock you out.',
          _ => wait > 0 ? 'Too many wrong tries. Try again in ${waitText(wait)}.' : 'Enter your private PIN',
        };
        body = _PinPad(
          title: title,
          hint: hint,
          // While waiting, the wait is what matters.
          error: wait > 0 ? null : _error,
          length: _pin.length,
          busy: _busy,
          locked: wait > 0,
          onDigit: _digit,
          onBack: _back,
          onOk: _pin.length >= 4 && wait == 0 ? _ok : null,
          footer: _step == _Step.unlock
              ? TextButton(
                  style: inlineButton,
                  onPressed: _busy ? null : _forgot,
                  child: const Text('Forgot the PIN?'),
                )
              : null,
        );
    }
    return Scaffold(
      backgroundColor: ByteColors.bg,
      appBar: AppBar(
        leading: IconButton(tooltip: 'Close', icon: const Icon(Icons.close_rounded), onPressed: () => Navigator.of(context).pop(false)),
      ),
      body: SafeArea(child: body),
    );
  }
}

class _Intro extends StatelessWidget {
  const _Intro({required this.onStart});
  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    Widget line(IconData icon, String title, String text) => Padding(
          padding: const EdgeInsets.only(bottom: 18),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: ByteColors.accentDim, size: 22),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 2),
                    Text(text, style: tt.bodyMedium?.copyWith(color: ByteColors.textDim, height: 1.35)),
                  ],
                ),
              ),
            ],
          ),
        );
    return ListView(
      padding: const EdgeInsets.fromLTRB(ByteSpace.page, 12, ByteSpace.page, 24),
      children: [
        Text('A private space', style: tt.headlineMedium),
        const SizedBox(height: 8),
        Text('For the things only you should see.', style: tt.bodyLarge?.copyWith(color: ByteColors.textDim)),
        const SizedBox(height: 28),
        line(Icons.pin_outlined, 'Its own PIN', 'Different from your phone\'s lock and from BYTE\'s lock. It closes when you leave it.'),
        line(Icons.visibility_off_outlined, 'Hidden everywhere else', 'Private things do not show in the Library, in Search or in your folders.'),
        line(Icons.lock_outline_rounded, 'Locked files', 'Every private file is scrambled on the phone. The copy in Google Drive and in backups is the scrambled one.'),
        line(Icons.folder_outlined, 'Folders inside', 'Sort private things into private folders.'),
        line(Icons.key_outlined, 'If you forget the PIN', 'Your vault\'s recovery key (Settings, Recovery key) lets you choose a new one. Without the PIN and without that key, nobody can open it — not even you.'),
        line(Icons.cloud_outlined, 'For the strongest lock', 'The recovery key opens the private space too. If "Keep the recovery key in Drive too" is on (Settings, Google Drive), it is in your Google account as well. Turn that off and keep the key on paper if you want only yourself to hold it.'),
        const SizedBox(height: 8),
        FilledButton(onPressed: onStart, child: const Text('Choose a PIN')),
      ],
    );
  }
}

/// Dots, a number pad and an OK button. Holds nothing itself.
class _PinPad extends StatelessWidget {
  const _PinPad({
    required this.title,
    required this.hint,
    required this.length,
    required this.busy,
    required this.locked,
    required this.onDigit,
    required this.onBack,
    required this.onOk,
    this.error,
    this.footer,
  });

  final String title;
  final String hint;
  final String? error;
  final int length;
  final bool busy;

  /// Waiting after wrong tries: the keys do nothing.
  final bool locked;
  final ValueChanged<String> onDigit;
  final VoidCallback onBack;
  final VoidCallback? onOk;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;

    Widget key(String d) => _PadKey(
          label: d,
          onTap: locked || busy ? null : () => onDigit(d),
        );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        children: [
          const Spacer(),
          Icon(Icons.lock_outline_rounded, color: ByteColors.accentDim, size: 30),
          const SizedBox(height: 14),
          Text(title, style: tt.headlineSmall, textAlign: TextAlign.center),
          const SizedBox(height: 8),
          Text(
            error ?? hint,
            textAlign: TextAlign.center,
            style: tt.bodyMedium?.copyWith(color: error != null ? ByteColors.danger : ByteColors.textDim, height: 1.35),
          ),
          const SizedBox(height: 22),
          // One dot per digit typed (at least four places are always shown).
          SizedBox(
            height: 16,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 0; i < (length < 4 ? 4 : length); i++)
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 140),
                    margin: const EdgeInsets.symmetric(horizontal: 6),
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: i < length ? ByteColors.accent : Colors.transparent,
                      border: Border.all(color: i < length ? ByteColors.accent : ByteColors.textFaint, width: 1.5),
                    ),
                  ),
              ],
            ),
          ),
          const Spacer(),
          for (final row in const [
            ['1', '2', '3'],
            ['4', '5', '6'],
            ['7', '8', '9'],
          ])
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [for (final d in row) key(d)],
              ),
            ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _PadKey(icon: Icons.backspace_outlined, semantic: 'Delete the last digit', onTap: locked || busy ? null : onBack),
              key('0'),
              _PadKey(
                icon: Icons.arrow_forward_rounded,
                semantic: 'OK',
                filled: true,
                busy: busy,
                onTap: busy ? null : onOk,
              ),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(height: 44, child: footer),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

class _PadKey extends StatelessWidget {
  const _PadKey({this.label, this.icon, this.semantic, this.onTap, this.filled = false, this.busy = false});

  final String? label;
  final IconData? icon;
  final String? semantic;
  final VoidCallback? onTap;
  final bool filled;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final on = onTap != null;
    final bg = filled ? (on ? ByteColors.accent : ByteColors.border) : ByteColors.surface2;
    final fg = filled ? ByteColors.onAccent : ByteColors.text;
    return Opacity(
      opacity: on || busy ? 1 : 0.5,
      child: Material(
        color: bg,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(
            width: 68,
            height: 68,
            child: Center(
              child: busy
                  ? SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4, color: fg))
                  : label != null
                      ? Text(label!, style: tt.headlineSmall?.copyWith(color: fg, fontWeight: FontWeight.w500))
                      : Icon(icon, color: fg, size: 24, semanticLabel: semantic),
            ),
          ),
        ),
      ),
    );
  }
}
