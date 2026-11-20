import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Which cloud model answers "Ask BYTE". The key lives in secure storage
/// (Android Keystore / Windows DPAPI), never in the vault or a backup.
enum AiProvider { claude, openai, gemini }

extension AiProviderX on AiProvider {
  String get label => switch (this) {
        AiProvider.claude => 'Claude',
        AiProvider.openai => 'OpenAI',
        AiProvider.gemini => 'Gemini',
      };

  String get defaultModel => switch (this) {
        AiProvider.claude => 'claude-haiku-5-5',
        AiProvider.openai => 'gpt-4o-mini',
        AiProvider.gemini => 'gemini-3.8-flash',
      };

  String get keyHint => switch (this) {
        AiProvider.claude => 'sk-ant-…  (console.anthropic.com → API keys)',
        AiProvider.openai => 'sk-…  (platform.openai.com → API keys)',
        AiProvider.gemini => 'AIza…  (aistudio.google.com → Get API key)',
      };

  static AiProvider parse(String? s) =>
      AiProvider.values.firstWhere((p) => p.name == s, orElse: () => AiProvider.claude);
}

class AiSettings {
  const AiSettings({required this.provider, required this.model, required this.apiKey});

  final AiProvider provider;
  final String model;
  final String apiKey;

  bool get isConfigured => apiKey.trim().isNotEmpty;

  static const _secure = FlutterSecureStorage();
  static const _kProvider = 'ai_provider';
  static const _kModel = 'ai_model';
  static String _keyName(AiProvider p) => 'ai_key_${p.name}';

  static Future<AiSettings> load() async {
    final p = await SharedPreferences.getInstance();
    final provider = AiProviderX.parse(p.getString(_kProvider));
    final model = (p.getString('${_kModel}_${provider.name}') ?? '').trim();
    String key = '';
    try {
      key = await _secure.read(key: _keyName(provider)) ?? '';
    } catch (_) {}
    return AiSettings(
      provider: provider,
      model: model.isEmpty ? provider.defaultModel : model,
      apiKey: key,
    );
  }

  static Future<void> save({required AiProvider provider, required String model, required String apiKey}) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kProvider, provider.name);
    await p.setString('${_kModel}_${provider.name}', model.trim());
    final k = apiKey.trim();
    if (k.isEmpty) {
      await _secure.delete(key: _keyName(provider));
    } else {
      await _secure.write(key: _keyName(provider), value: k);
    }
  }

  /// The key saved for [provider], if any (so switching providers shows it).
  static Future<String> keyFor(AiProvider provider) async {
    try {
      return await _secure.read(key: _keyName(provider)) ?? '';
    } catch (_) {
      return '';
    }
  }

  static Future<String> modelFor(AiProvider provider) async {
    final p = await SharedPreferences.getInstance();
    final m = (p.getString('${_kModel}_${provider.name}') ?? '').trim();
    return m.isEmpty ? provider.defaultModel : m;
  }
}
