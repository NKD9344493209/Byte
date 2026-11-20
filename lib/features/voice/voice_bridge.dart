import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// What the recognizer heard.
class Heard {
  const Heard({required this.text, this.alternatives = const [], this.confidence = -1, this.error});
  final String text;
  final List<String> alternatives;
  final double confidence;

  /// nothing | network | permission | audio | busy | unavailable | cancelled | error_N
  final String? error;

  bool get ok => error == null && text.trim().isNotEmpty;
}

/// Speech to text: the Dart side of VoiceBridge.kt (Android's own
/// recognizer). Used by "Speak to write" in notes. Every call is safe on
/// Windows (returns an 'unavailable' result).
class VoiceBridge {
  VoiceBridge._();

  static const _voice = MethodChannel('byte/voice');

  static bool get supported => Platform.isAndroid;

  // ───────────── speech ─────────────

  static Future<bool> recognitionAvailable() async {
    if (!supported) return false;
    try {
      return await _voice.invokeMethod<bool>('isRecognitionAvailable') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// "Bluetooth mic Boat Rockerz" when earbuds with a mic are connected,
  /// "no Bluetooth mic" otherwise (empty when unsupported). While BYTE listens
  /// the headset's voice link is opened natively so it hears the buds' mic.
  static Future<String> headsetMic() async {
    if (!supported) return '';
    try {
      return await _voice.invokeMethod<String>('headsetMic') ?? '';
    } catch (_) {
      return '';
    }
  }

  /// Live partial text while listening (what the recognizer has so far).
  static final ValueNotifier<String> partial = ValueNotifier<String>('');
  static bool _handlerSet = false;

  static void _ensureHandler() {
    if (_handlerSet) return;
    _handlerSet = true;
    _voice.setMethodCallHandler((call) async {
      if (call.method == 'partial') partial.value = '${call.arguments ?? ''}';
      return null;
    });
  }

  /// [pauseMs]: how long BYTE waits after you stop talking before it decides
  /// you are done (slow / halting speech → make it longer).
  /// [minMs]: keep the mic open at least this long (10 s for sentences;
  /// ~1.5 s for a yes/no so the answer comes back at once).
  static Future<Heard> listen({bool offline = true, String locale = 'en-IN', int pauseMs = 3000, int minMs = 10000}) async {
    if (!supported) return const Heard(text: '', error: 'unavailable');
    _ensureHandler();
    partial.value = '';
    try {
      final r = await _voice.invokeMethod<Map>('listen', {'offline': offline, 'locale': locale, 'pauseMs': pauseMs, 'minMs': minMs});
      if (r == null) return const Heard(text: '', error: 'error');
      final err = r['error'] as String?;
      if (err != null) return Heard(text: '', error: err);
      return Heard(
        text: (r['text'] as String?) ?? '',
        alternatives: [for (final a in (r['alternatives'] as List? ?? const [])) '$a'],
        confidence: (r['confidence'] as num?)?.toDouble() ?? -1,
      );
    } catch (e) {
      debugPrint('[voice] listen: $e');
      return const Heard(text: '', error: 'error');
    }
  }

  static Future<void> cancelListen() async {
    if (!supported) return;
    try {
      await _voice.invokeMethod('cancelListen');
    } catch (_) {}
  }
}
