import 'package:flutter/material.dart';

import '../core/app_lock.dart';
import '../core/capture_trigger.dart';
import 'byte_mascot.dart';
import 'theme.dart';

/// Wraps the app: shows the lock screen until [AppLock.unlocked] is true.
class LockGate extends StatefulWidget {
  const LockGate({super.key, required this.child});
  final Widget child;

  @override
  State<LockGate> createState() => _LockGateState();
}

class _LockGateState extends State<LockGate> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    AppLock.unlocked.addListener(_rebuild);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    AppLock.unlocked.removeListener(_rebuild);
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) AppLock.onHidden();
    if (state == AppLifecycleState.resumed && AppLock.onResumed()) {
      // Drop whatever was open so the lock is what you see — unless the
      // neckband capture / voice screen is up (that must keep working).
      if (!CaptureTrigger.isCaptureOpen) {
        CaptureTrigger.navigatorKey.currentState?.popUntil((r) => r.isFirst);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (AppLock.unlocked.value || !AppLock.enabled) return widget.child;
    return Stack(
      children: [
        // Keep the app tree alive underneath (alarms, triggers), hidden.
        Offstage(child: widget.child),
        const _LockScreen(),
      ],
    );
  }
}

class _LockScreen extends StatefulWidget {
  const _LockScreen();
  @override
  State<_LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<_LockScreen> {
  final _pin = TextEditingController();
  bool _pinOk = !AppLock.needsPin;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (!AppLock.needsPin) WidgetsBinding.instance.addPostFrameCallback((_) => _bio());
  }

  @override
  void dispose() {
    _pin.dispose();
    super.dispose();
  }

  Future<void> _checkPin() async {
    final ok = await AppLock.checkPin(_pin.text.trim());
    if (!mounted) return;
    if (!ok) {
      setState(() => _error = 'Wrong PIN.');
      return;
    }
    setState(() {
      _pinOk = true;
      _error = null;
    });
    await _bio();
  }

  Future<void> _bio() async {
    if (_busy) return;
    setState(() => _busy = true);
    final ok = await AppLock.biometric();
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) {
      AppLock.unlock();
    } else {
      setState(() => _error = 'Not verified. Try again.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Scaffold(
      backgroundColor: ByteColors.bg,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const ByteMascot(size: 48, mood: ByteMood.neutral),
                const SizedBox(height: 18),
                Text('BYTE is locked', style: tt.headlineSmall),
                const SizedBox(height: 6),
                Text(
                  _pinOk ? 'Fingerprint or face to continue.' : 'PIN first, then fingerprint or face.',
                  textAlign: TextAlign.center,
                  style: tt.bodyMedium?.copyWith(color: ByteColors.textDim),
                ),
                const SizedBox(height: 28),
                if (!_pinOk) ...[
                  // Big digits, nothing else on the line.
                  TextField(
                    controller: _pin,
                    autofocus: true,
                    obscureText: true,
                    keyboardType: TextInputType.number,
                    textAlign: TextAlign.center,
                    maxLength: 8,
                    style: tt.headlineMedium?.copyWith(letterSpacing: 10, fontFeatures: const [FontFeature.tabularFigures()]),
                    decoration: InputDecoration(
                      hintText: 'PIN',
                      counterText: '',
                      hintStyle: tt.headlineMedium?.copyWith(color: ByteColors.textFaint, letterSpacing: 2),
                    ),
                    onSubmitted: (_) => _checkPin(),
                  ),
                  const SizedBox(height: 14),
                  FilledButton(onPressed: _checkPin, child: const Text('Continue')),
                ] else
                  FilledButton.icon(
                    onPressed: _busy ? null : _bio,
                    icon: const Icon(Icons.fingerprint_rounded),
                    label: Text(_busy ? 'Checking…' : 'Unlock'),
                  ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!, textAlign: TextAlign.center, style: tt.bodySmall?.copyWith(color: ByteColors.danger)),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
