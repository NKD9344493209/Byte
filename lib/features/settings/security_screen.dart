import 'package:flutter/material.dart';

import '../../core/app_lock.dart';
import '../../core/prefs.dart';
import '../../shared/theme.dart';
import '../../shared/ui.dart';

/// Settings → Security: the lock on BYTE's front door.
class SecurityScreen extends StatefulWidget {
  const SecurityScreen({super.key});

  @override
  State<SecurityScreen> createState() => _SecurityScreenState();
}

class _SecurityScreenState extends State<SecurityScreen> {
  String _mode = Prefs.appLockMode;
  bool _bioAvailable = false;
  bool _hasPin = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final b = await AppLock.biometricsAvailable();
    final p = await AppLock.hasPin();
    if (!mounted) return;
    setState(() {
      _bioAvailable = b;
      _hasPin = p;
    });
  }

  Future<String?> _askPin(String title) async {
    final a = TextEditingController();
    final b = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: a, autofocus: true, obscureText: true, keyboardType: TextInputType.number, maxLength: 8, decoration: const InputDecoration(hintText: 'New PIN (4–8 digits)', counterText: '')),
            TextField(controller: b, obscureText: true, keyboardType: TextInputType.number, maxLength: 8, decoration: const InputDecoration(hintText: 'Again', counterText: '')),
          ],
        ),
        actions: [
          TextButton(style: inlineButton, onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(style: inlineButton, onPressed: () => Navigator.pop(ctx, true), child: const Text('Set')),
        ],
      ),
    );
    final pin = a.text.trim();
    final again = b.text.trim();
    Future<void>.delayed(const Duration(seconds: 1), () {
      a.dispose();
      b.dispose();
    });
    if (ok != true) return null;
    if (pin.length < 4 || pin != again) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('PINs must match and have at least 4 digits.')));
      return null;
    }
    return pin;
  }

  Future<void> _setMode(String m) async {
    if (m != 'off' && !_bioAvailable) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Set up a fingerprint or face unlock on the phone first.')));
      return;
    }
    if (m == 'pin_bio' && !_hasPin) {
      final pin = await _askPin('App PIN');
      if (pin == null) return;
      await AppLock.setPin(pin);
    }
    if (m != 'off') {
      // Prove it works before locking the user out.
      final ok = await AppLock.biometric(reason: 'Confirm to turn on the app lock');
      if (!ok) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Not verified — lock left as it was.')));
        return;
      }
    }
    await Prefs.setAppLockMode(m);
    AppLock.unlock();
    if (!mounted) return;
    setState(() => _mode = m);
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Security')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          const SectionLabel('Opening BYTE', top: 8),
          Well(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: RadioGroup<String>(
              groupValue: _mode,
              onChanged: (v) {
                if (v != null) _setMode(v);
              },
              child: Column(
                children: [
                  const RadioListTile<String>(value: 'off', title: Text('No lock'), subtitle: Text('Opens straight away')),
                  RadioListTile<String>(
                    value: 'biometric',
                    title: const Text('Fingerprint / face'),
                    subtitle: Text(_bioAvailable ? 'The phone\'s own prompt, on open and after 1 min in the background' : 'Set up fingerprint or face on the phone first'),
                  ),
                  const RadioListTile<String>(
                    value: 'pin_bio',
                    title: Text('PIN + fingerprint / face'),
                    subtitle: Text('Two steps every time'),
                  ),
                ],
              ),
            ),
          ),
          if (_mode == 'pin_bio')
            Padding(
              padding: const EdgeInsets.fromLTRB(ByteSpace.page - 8, 6, ByteSpace.page, 0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  style: inlineButton,
                  onPressed: () async {
                    final pin = await _askPin('Change app PIN');
                    if (pin != null) {
                      await AppLock.setPin(pin);
                      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('App PIN changed')));
                    }
                  },
                  icon: const Icon(Icons.password_rounded, size: 18),
                  label: const Text('Change app PIN'),
                ),
              ),
            ),

          Padding(
            padding: const EdgeInsets.fromLTRB(ByteSpace.page, 20, ByteSpace.page, 0),
            child: Text(
              'The lock covers everything in BYTE. Recording a voice note from the neckband still works while locked; opening what you saved asks for the lock first. The private space (Folders, then Private) has a PIN of its own on top of this.',
              style: tt.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}
