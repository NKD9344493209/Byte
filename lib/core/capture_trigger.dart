import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../features/capture/quick_capture_screen.dart';
import '../features/capture/recorder_service.dart';

/// Bridges the Android "assist / voice command" intent (neckband long-press)
/// to the Quick Capture screen. No-op on Windows.
class CaptureTrigger {
  CaptureTrigger._();

  static const _channel = MethodChannel('byte/capture');
  static final GlobalKey<NavigatorState> navigatorKey =
      GlobalKey<NavigatorState>();

  static bool _quickCaptureOpen = false;
  static bool get isCaptureOpen => _quickCaptureOpen;

  static Future<void> init() async {
    if (!Platform.isAndroid) return;

    _channel.setMethodCallHandler((call) async {
      if (call.method == 'trigger') await onTrigger(source: '${call.arguments ?? 'headset'}');
      return null;
    });

    // A trigger that arrived before Dart was listening (cold start).
    String? pending;
    try {
      pending = await _channel.invokeMethod<String?>('consumePendingTrigger');
    } on MissingPluginException {
      pending = null;
    } catch (_) {
      pending = null;
    }
    if (pending != null) {
      final src = pending;
      WidgetsBinding.instance.addPostFrameCallback((_) => onTrigger(source: src));
    }
  }

  /// Drops the Bluetooth voice link the headset press opened for the previous
  /// assistant, so our recorder actually receives audio.
  static Future<void> prepareMic() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('prepareMic');
    } catch (_) {}
  }

  /// True if MainActivity already beeped + prepared the mic for this trigger
  /// (so Quick Capture must not beep again — that would stall the mic).
  static Future<bool> consumeNativeBeep() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('consumeNativeBeep') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// True when a music stream is playing (e.g. Spotify resumed after a
  /// headset tap). Used as the "stop & save" signal during capture.
  static Future<bool> isMusicActive() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('isMusicActive') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// While recording, Android holds a media session so any headset press
  /// stops the capture, and takes audio focus so music pauses.
  static Future<void> captureStarted() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('captureStarted');
    } catch (_) {}
  }

  /// The recorder is about to open the mic, and holds it until [micFree].
  /// Android then keeps the mic alive with the screen off (a quiet
  /// "BYTE is recording" line in the notification shade).
  static Future<void> micBusy() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('micBusy');
    } catch (_) {}
  }

  static Future<void> micFree() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('micFree');
    } catch (_) {}
  }

  static Future<void> captureStopped() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('captureStopped');
    } catch (_) {}
  }

  /// A headset press on a locked phone lets BYTE show over the lock screen
  /// so the recorder can be seen. This says "the recorder has closed (or
  /// never opened)": BYTE goes back behind the lock.
  static Future<void> overLockDone() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('overLockDone');
    } catch (_) {}
  }

  /// A voice note started from the floating bubble is done: give the screen
  /// back to the app that was underneath. Does nothing for any other start.
  static Future<void> backToApp() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('backToApp');
    } catch (_) {}
  }

  /// Asks for "Nearby devices" (Android 12+), which the headset button needs
  /// so BYTE can end the headset's own voice session and record cleanly.
  /// True when it is allowed.
  static Future<bool> requestHeadsetPermission() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('requestHeadsetPermission') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Any press while recording = stop. Otherwise open Quick Capture and
  /// record a voice note. [source]: headset (neckband) | button (power key) | app.
  static Future<void> onTrigger({String source = 'headset'}) async {
    final rec = RecorderService.instance;
    debugPrint('[trigger] source=$source recording=${rec.isRecording} '
        'open=$_quickCaptureOpen elapsed=${rec.elapsed}');
    if (rec.isRecording || _quickCaptureOpen) {
      // Still starting up — ignore.
      if (!rec.isRecording) return;
      // The long-press that launched us sends a trailing button event a
      // moment later; don't let it stop the capture it just started.
      if (rec.elapsed < const Duration(milliseconds: 2000)) {
        if (!_quickCaptureOpen) await overLockDone();
        return;
      }
      if (_quickCaptureOpen) {
        QuickCaptureScreen.requestStop();
      } else {
        // The long recorder is running: nothing opens for this press.
        await overLockDone();
      }
      return;
    }
    final nav = navigatorKey.currentState;
    if (nav == null) {
      await overLockDone();
      return;
    }
    _quickCaptureOpen = true;
    try {
      await nav.push(MaterialPageRoute<void>(fullscreenDialog: true, builder: (_) => QuickCaptureScreen(source: source)));
    } finally {
      _quickCaptureOpen = false;
      await backToApp();
      await overLockDone();
    }
  }
}
