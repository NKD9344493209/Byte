import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../capture/recorder_service.dart';
import 'heard_fixes.dart';

/// The words of a voice note, appearing while you talk.
///
/// BYTE's recorder keeps the microphone and writes the audio file. This class
/// only passes a COPY of the sound to Android's on-device speech engine
/// (native `LiveWords`, channel "byte/live"). If the engine is missing or
/// gives up, the words stop and the recording carries on untouched.
class LiveWords {
  LiveWords._();

  static const _ch = MethodChannel('byte/live');

  /// Everything heard so far (finished sentences + the one being spoken).
  static final ValueNotifier<String> text = ValueNotifier<String>('');

  /// '' while fine. Otherwise why the words stopped: 'language' (the offline
  /// speech pack for the language is not on the phone), 'stalled', 'error'.
  static final ValueNotifier<String> problem = ValueNotifier<String>('');

  static bool _active = false;
  static bool _listening = false;
  static String _done = '';
  static String _partial = '';
  static Completer<void>? _ended;

  /// A start that is still on its way (stop and cancel wait for it), and a
  /// number that goes up with every recording (so an old stop that is still
  /// waiting never touches the next recording).
  static Future<bool>? _starting;
  static int _session = 0;

  static bool get active => _active;

  static void _show() {
    final d = _done.trim();
    final p = _partial.trim();
    text.value = d.isEmpty ? p : (p.isEmpty ? d : '$d $p');
  }

  static Future<dynamic> _onCall(MethodCall call) async {
    switch (call.method) {
      case 'partial':
        _partial = '${call.arguments ?? ''}';
        _show();
      case 'segment':
        final s = '${call.arguments ?? ''}'.trim();
        if (s.isNotEmpty) _done = _done.isEmpty ? s : '$_done $s';
        _partial = '';
        _show();
      case 'error':
        final code = call.arguments is int ? call.arguments as int : 0;
        // 12 / 13: the language is not supported / its pack is not downloaded.
        problem.value = code == 12 || code == 13 ? 'language' : (code == -1 ? 'stalled' : 'error');
        _end();
      case 'end':
        _end();
    }
    return null;
  }

  static void _end() {
    _active = false;
    RecorderService.instance.onPcm = null;
    final c = _ended;
    if (c != null && !c.isCompleted) c.complete();
  }

  /// Does this phone have the on-device speech engine at all?
  static Future<bool> supported() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _ch.invokeMethod<bool>('supported') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Call right after the recorder has started. True when words will appear.
  static Future<bool> start({String locale = 'en-IN'}) => _starting = _start(locale);

  static Future<bool> _start(String locale) async {
    if (!Platform.isAndroid) return false;
    _session++;
    if (!_listening) {
      _listening = true;
      _ch.setMethodCallHandler(_onCall);
    }
    _done = '';
    _partial = '';
    text.value = '';
    problem.value = '';
    _ended = Completer<void>();
    try {
      final ok = await _ch.invokeMethod<bool>('start', {'locale': locale, 'hints': await HeardFixes.hints()}) ?? false;
      if (!ok) return false;
      _active = true;
      RecorderService.instance.onPcm = _feed;
      return true;
    } catch (e) {
      debugPrint('[live] start: $e');
      return false;
    }
  }

  static void _feed(Uint8List chunk) {
    if (!_active) return;
    // Not awaited: the recorder never waits for the speech engine.
    _ch.invokeMethod<void>('feed', chunk).catchError((Object _) {});
  }

  /// The recording has stopped. Waits briefly for the last words and returns
  /// everything that was heard ('' when live words were not running).
  static Future<String> stop() async {
    RecorderService.instance.onPcm = null;
    if (!Platform.isAndroid) return '';
    final starting = _starting;
    if (starting != null) await starting; // a start still on its way finishes first
    RecorderService.instance.onPcm = null;
    final mine = _session;
    final before = text.value.trim();
    final wasActive = _active;
    final ended = _ended;
    if (wasActive) {
      try {
        await _ch.invokeMethod<void>('stop');
        if (ended != null) await ended.future.timeout(const Duration(milliseconds: 4500), onTimeout: () {});
      } catch (e) {
        debugPrint('[live] stop: $e');
      }
    }
    // A new recording started while this one was waiting for its last
    // words: leave the new one alone.
    if (mine != _session) return before;
    _active = false;
    _show();
    return text.value.trim();
  }

  /// The recording was thrown away: stop without waiting for anything.
  static Future<void> cancel() async {
    RecorderService.instance.onPcm = null;
    final starting = _starting;
    if (starting != null) await starting; // a start still on its way finishes first
    RecorderService.instance.onPcm = null;
    _active = false;
    if (!Platform.isAndroid) return;
    try {
      await _ch.invokeMethod<void>('cancel');
    } catch (_) {}
  }

  /// Opens Android's "download this language for offline speech" step.
  static Future<bool> downloadLanguage({String locale = 'en-IN'}) async {
    if (!Platform.isAndroid) return false;
    try {
      return await _ch.invokeMethod<bool>('download', {'locale': locale}) ?? false;
    } catch (_) {
      return false;
    }
  }
}
