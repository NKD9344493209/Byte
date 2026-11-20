import 'dart:convert';

import 'package:http/http.dart' as http;

import 'ai_settings.dart';

/// An image attached to a turn (base64, with its media type).
class AiImage {
  const AiImage({required this.mime, required this.base64});
  final String mime; // image/jpeg | image/png | image/webp
  final String base64;
}

/// One turn of the conversation as the model sees it.
class AiTurn {
  const AiTurn(this.role, this.text, {this.images = const []});
  final String role; // 'user' | 'assistant'
  final String text;
  final List<AiImage> images;
}

class AiException implements Exception {
  AiException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// A reply that was allowed to search the web: text + where it came from.
class GroundedReply {
  const GroundedReply({required this.text, required this.sources, this.searched = false});
  final String text;

  /// (title, url), de-duplicated, in citation order.
  final List<(String, String)> sources;

  /// True when the model actually ran a search.
  final bool searched;
}

/// Thin HTTP client over the three providers. Request bodies are built by
/// pure functions so they can be unit-tested without the network.
class AiClient {
  AiClient(this.settings, {http.Client? client}) : _http = client ?? http.Client();

  final AiSettings settings;
  final http.Client _http;

  static const _timeout = Duration(seconds: 60);
  static const _timeoutSearch = Duration(seconds: 90);

  /// Live web search is available on Claude and Gemini keys.
  static bool supportsSearch(AiProvider p) => p == AiProvider.claude || p == AiProvider.gemini;

  /// Returns the assistant's reply text.
  Future<String> chat({required String system, required List<AiTurn> turns, int maxTokens = 800}) async {
    if (!settings.isConfigured) throw AiException('No AI key set. Add one in Settings, AI key.');
    final (uri, headers, body) = buildRequest(settings, system: system, turns: turns, maxTokens: maxTokens);
    final res = await _post(uri, headers, body, _timeout);
    final text = parseReply(settings.provider, res.body);
    if (text.trim().isEmpty) throw AiException('${settings.provider.label} sent an empty reply.');
    return text.trim();
  }

  /// Same, but the model may search the web; sources come back with the text.
  /// On a provider without search this falls back to [chat] with `searched=false`.
  Future<GroundedReply> chatGrounded({required String system, required List<AiTurn> turns, int maxTokens = 1200, int maxSearches = 5}) async {
    if (!settings.isConfigured) throw AiException('No AI key set. Add one in Settings, AI key.');
    if (!supportsSearch(settings.provider)) {
      final t = await chat(system: system, turns: turns, maxTokens: maxTokens);
      return GroundedReply(text: t, sources: const [], searched: false);
    }
    final (uri, headers, body) = buildRequest(settings, system: system, turns: turns, maxTokens: maxTokens, search: true, maxSearches: maxSearches);
    final res = await _post(uri, headers, body, _timeoutSearch);
    final r = parseGroundedReply(settings.provider, res.body);
    if (r.text.trim().isEmpty) throw AiException('${settings.provider.label} sent an empty reply.');
    return r;
  }

  Future<http.Response> _post(Uri uri, Map<String, String> headers, Map<String, Object?> body, Duration timeout) async {
    http.Response res;
    try {
      res = await _http.post(uri, headers: headers, body: jsonEncode(body)).timeout(timeout);
    } catch (e) {
      throw AiException('No reply from ${settings.provider.label}: $e');
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw AiException(describeError(settings.provider, res.statusCode, res.body));
    }
    return res;
  }

  // ───────────── pure builders ─────────────

  static (Uri, Map<String, String>, Map<String, Object?>) buildRequest(
    AiSettings s, {
    required String system,
    required List<AiTurn> turns,
    int maxTokens = 800,
    bool search = false,
    int maxSearches = 5,
  }) {
    switch (s.provider) {
      case AiProvider.claude:
        return (
          Uri.parse('https://api.anthropic.com/v1/messages'),
          {
            'content-type': 'application/json',
            'x-api-key': s.apiKey,
            'anthropic-version': '2023-06-01',
          },
          {
            'model': s.model,
            'max_tokens': maxTokens,
            'system': system,
            'messages': [for (final t in turns) _claudeMessage(t)],
            if (search)
              'tools': [
                {'type': 'web_search_20250305', 'name': 'web_search', 'max_uses': maxSearches},
              ],
          },
        );
      case AiProvider.openai:
        return (
          Uri.parse('https://api.openai.com/v1/chat/completions'),
          {
            'content-type': 'application/json',
            'authorization': 'Bearer ${s.apiKey}',
          },
          {
            'model': s.model,
            'max_tokens': maxTokens,
            'messages': [
              {'role': 'system', 'content': system},
              for (final t in turns) _openaiMessage(t),
            ],
          },
        );
      case AiProvider.gemini:
        return (
          Uri.parse('https://generativelanguage.googleapis.com/v1beta/models/${s.model}:generateContent'),
          {
            'content-type': 'application/json',
            'x-goog-api-key': s.apiKey,
          },
          {
            'systemInstruction': {
              'parts': [
                {'text': system},
              ],
            },
            'contents': [for (final t in turns) _geminiContent(t)],
            if (search)
              'tools': [
                {'google_search': <String, Object?>{}},
              ],
            'generationConfig': {'maxOutputTokens': maxTokens < 1024 ? 1024 : maxTokens},
          },
        );
    }
  }

  static Map<String, Object?> _claudeMessage(AiTurn t) {
    if (t.images.isEmpty) return {'role': t.role, 'content': t.text};
    return {
      'role': t.role,
      'content': [
        for (final i in t.images)
          {
            'type': 'image',
            'source': {'type': 'base64', 'media_type': i.mime, 'data': i.base64},
          },
        {'type': 'text', 'text': t.text},
      ],
    };
  }

  static Map<String, Object?> _openaiMessage(AiTurn t) {
    if (t.images.isEmpty) return {'role': t.role, 'content': t.text};
    return {
      'role': t.role,
      'content': [
        {'type': 'text', 'text': t.text},
        for (final i in t.images)
          {
            'type': 'image_url',
            'image_url': {'url': 'data:${i.mime};base64,${i.base64}'},
          },
      ],
    };
  }

  static Map<String, Object?> _geminiContent(AiTurn t) => {
        'role': t.role == 'assistant' ? 'model' : 'user',
        'parts': [
          for (final i in t.images)
            {
              'inline_data': {'mime_type': i.mime, 'data': i.base64},
            },
          {'text': t.text},
        ],
      };

  static String parseReply(AiProvider p, String body) {
    final j = jsonDecode(body);
    switch (p) {
      case AiProvider.claude:
        final content = (j['content'] as List?) ?? const [];
        return content
            .whereType<Map>()
            .where((c) => c['type'] == 'text')
            .map((c) => c['text'] as String? ?? '')
            .join();
      case AiProvider.openai:
        final choices = (j['choices'] as List?) ?? const [];
        if (choices.isEmpty) return '';
        final msg = (choices.first as Map)['message'] as Map?;
        return msg?['content'] as String? ?? '';
      case AiProvider.gemini:
        return _geminiText(j);
    }
  }

  /// Gemini 3.x "thinks" first: skip thought parts; explain an empty answer.
  static String _geminiText(dynamic j) {
    final cands = (j['candidates'] as List?) ?? const [];
    if (cands.isEmpty) {
      final block = (j['promptFeedback'] as Map?)?['blockReason'];
      if (block != null) throw AiException('Gemini blocked the request ($block).');
      return '';
    }
    final first = cands.first as Map;
    final parts = ((first['content'] as Map?)?['parts'] as List?) ?? const [];
    final text = parts.whereType<Map>().where((x) => x['thought'] != true).map((x) => x['text'] as String? ?? '').join();
    if (text.trim().isEmpty) {
      final why = first['finishReason'];
      if (why == 'MAX_TOKENS') throw AiException('Gemini ran out of room while thinking — raise max tokens or pick a lighter model (gemini-3.5-flash-lite).');
      if (why != null && why != 'STOP') throw AiException('Gemini stopped: $why.');
    }
    return text;
  }

  /// Text + sources from a search-enabled reply.
  static GroundedReply parseGroundedReply(AiProvider p, String body) {
    final j = jsonDecode(body);
    final sources = <(String, String)>[];
    final seen = <String>{};
    void add(String? title, String? url) {
      if (url == null || url.isEmpty || seen.contains(url)) return;
      seen.add(url);
      sources.add(((title ?? '').trim().isEmpty ? _host(url) : title!.trim(), url));
    }

    switch (p) {
      case AiProvider.claude:
        final content = (j['content'] as List?) ?? const [];
        var searched = false;
        final text = StringBuffer();
        for (final c in content.whereType<Map>()) {
          final type = c['type'];
          if (type == 'text') {
            text.write(c['text'] as String? ?? '');
            for (final cit in (c['citations'] as List?) ?? const []) {
              if (cit is Map) add(cit['title'] as String?, cit['url'] as String?);
            }
          } else if (type == 'server_tool_use') {
            searched = true;
          } else if (type == 'web_search_tool_result') {
            searched = true;
            final inner = c['content'];
            if (inner is List) {
              for (final r in inner.whereType<Map>()) {
                if (r['type'] == 'web_search_result') add(r['title'] as String?, r['url'] as String?);
              }
            }
          }
        }
        // Cited sources first, then the rest of what was looked at (max 8).
        return GroundedReply(text: text.toString(), sources: sources.take(8).toList(), searched: searched);
      case AiProvider.gemini:
        final cands = (j['candidates'] as List?) ?? const [];
        if (cands.isEmpty) return const GroundedReply(text: '', sources: []);
        final first = cands.first as Map;
        final text = _geminiText(j);
        final gm = first['groundingMetadata'] as Map?;
        var searched = false;
        if (gm != null) {
          searched = true;
          for (final ch in (gm['groundingChunks'] as List?) ?? const []) {
            final web = (ch as Map)['web'] as Map?;
            if (web != null) add(web['title'] as String?, web['uri'] as String?);
          }
        }
        return GroundedReply(text: text, sources: sources.take(8).toList(), searched: searched);
      case AiProvider.openai:
        return GroundedReply(text: parseReply(p, body), sources: const [], searched: false);
    }
  }

  static String _host(String url) {
    try {
      return Uri.parse(url).host.replaceFirst('www.', '');
    } catch (_) {
      return url;
    }
  }

  static String describeError(AiProvider p, int status, String body) {
    String detail = '';
    try {
      final j = jsonDecode(body);
      detail = (j['error'] is Map ? (j['error']['message'] as String?) : j['error'] as String?) ?? '';
    } catch (_) {
      detail = body.length > 200 ? '${body.substring(0, 200)}…' : body;
    }
    final why = switch (status) {
      401 || 403 => 'the API key was refused',
      404 => 'that model name doesn\'t exist',
      429 => 'rate limit or no credit left',
      _ => 'HTTP $status',
    };
    return '${p.label}: $why.${detail.isEmpty ? '' : ' $detail'}';
  }
}
