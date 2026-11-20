import 'package:flutter/material.dart';

import '../../shared/theme.dart';
import '../../shared/ui.dart';
import 'ai_client.dart';
import 'ai_settings.dart';

/// Settings → AI key: which AI service, which key. Optional: BYTE works
/// without one; a key only adds the "tidy" and "suggest" buttons.
class AiSettingsScreen extends StatefulWidget {
  const AiSettingsScreen({super.key});

  @override
  State<AiSettingsScreen> createState() => _AiSettingsScreenState();
}

class _AiSettingsScreenState extends State<AiSettingsScreen> {
  AiProvider _provider = AiProvider.claude;
  final _key = TextEditingController();
  final _model = TextEditingController();
  bool _showKey = false;
  bool _loaded = false;
  bool _busy = false;
  String? _status;
  bool _statusOk = false;

  @override
  void initState() {
    super.initState();
    AiSettings.load().then((s) {
      if (!mounted) return;
      setState(() {
        _provider = s.provider;
        _key.text = s.apiKey;
        _model.text = s.model;
        _loaded = true;
      });
    });
  }

  @override
  void dispose() {
    _key.dispose();
    _model.dispose();
    super.dispose();
  }

  Future<void> _switchProvider(AiProvider p) async {
    // Keep what was typed for the old provider.
    await AiSettings.save(provider: _provider, model: _model.text, apiKey: _key.text);
    final key = await AiSettings.keyFor(p);
    final model = await AiSettings.modelFor(p);
    if (!mounted) return;
    setState(() {
      _provider = p;
      _key.text = key;
      _model.text = model;
      _status = null;
    });
    await AiSettings.save(provider: p, model: model, apiKey: key);
  }

  Future<void> _save({bool quiet = false}) async {
    await AiSettings.save(provider: _provider, model: _model.text, apiKey: _key.text);
    if (!mounted || quiet) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Saved')));
  }

  Future<void> _test() async {
    await _save(quiet: true);
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      final s = await AiSettings.load();
      final reply = await AiClient(s).chat(
        system: 'You are BYTE. Reply with exactly three words.',
        turns: const [AiTurn('user', 'Say hello to me.')],
        maxTokens: 400,
      );
      if (!mounted) return;
      setState(() {
        _status = '${s.provider.label} replied: "$reply"';
        _statusOk = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _status = '$e';
        _statusOk = false;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('AI key')),
      body: !_loaded
          ? const SizedBox.shrink()
          : ListView(
              padding: const EdgeInsets.only(bottom: 32),
              children: [
                const SectionLabel('Which AI service', top: 8),
                ByteList(
                  children: [
                    for (final p in AiProvider.values)
                      ByteRow(
                        title: p.label,
                        titleWeight: FontWeight.w600,
                        trailing: _provider == p ? Icon(Icons.check_rounded, color: ByteColors.accentDim) : null,
                        onTap: () => _switchProvider(p),
                      ),
                  ],
                ),

                const SectionLabel('Key and model'),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: ByteSpace.page),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TextField(
                        controller: _key,
                        obscureText: !_showKey,
                        autocorrect: false,
                        enableSuggestions: false,
                        decoration: InputDecoration(
                          labelText: 'API key',
                          hintText: _provider.keyHint,
                          suffixIcon: IconButton(
                            tooltip: _showKey ? 'Hide key' : 'Show key',
                            icon: Icon(_showKey ? Icons.visibility_off_outlined : Icons.visibility_outlined),
                            onPressed: () => setState(() => _showKey = !_showKey),
                          ),
                        ),
                        onChanged: (_) => setState(() => _status = null),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: _model,
                        autocorrect: false,
                        decoration: InputDecoration(
                          labelText: 'Model',
                          hintText: _provider.defaultModel,
                          suffixIcon: IconButton(
                            tooltip: 'Reset to default',
                            icon: const Icon(Icons.restart_alt_rounded),
                            onPressed: () => setState(() => _model.text = _provider.defaultModel),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      FilledButton(onPressed: _busy ? null : () => _save(), child: const Text('Save key')),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          TextButton(style: inlineButton, onPressed: _busy || _key.text.trim().isEmpty ? null : _test, child: const Text('Test the key')),
                          if (_busy) ...[
                            const SizedBox(width: 8),
                            SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: ByteColors.accent)),
                          ],
                        ],
                      ),
                      if (_status != null) ...[
                        const SizedBox(height: 6),
                        Text(
                          _statusOk ? 'Works — $_status' : 'Failed — $_status',
                          style: tt.bodySmall?.copyWith(color: _statusOk ? ByteColors.accentDim : ByteColors.danger),
                        ),
                      ],
                    ],
                  ),
                ),

                const SectionLabel('What leaves your phone'),
                const ByteList(
                  children: [
                    ByteRow(icon: Icons.touch_app_outlined, title: 'Only when you tap a button', subtitle: 'BYTE never sends anything to the AI by itself', titleWeight: FontWeight.w600),
                    ByteRow(icon: Icons.short_text_rounded, title: 'Only words, never files', subtitle: 'The words of the voice note you tidy. Photos, videos, documents and recordings stay on the phone', titleWeight: FontWeight.w600),
                    ByteRow(icon: Icons.key_rounded, title: 'The key lives in the device keystore', subtitle: 'Not in the vault, not in backups', titleWeight: FontWeight.w600),
                    ByteRow(icon: Icons.check_circle_outline_rounded, title: 'No key still works', subtitle: 'Everything else in BYTE works without one', titleWeight: FontWeight.w600),
                  ],
                ),
              ],
            ),
    );
  }
}
