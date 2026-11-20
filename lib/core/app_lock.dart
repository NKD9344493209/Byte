import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';

import 'prefs.dart';

/// The front door. Modes:
///  - off        : nothing
///  - biometric  : fingerprint / face (phone's own prompt) on open and after
///                 [grace] in the background
///  - pin_bio    : PIN first, then fingerprint / face
/// Wealth can additionally demand a biometric after its own PIN.
class AppLock {
  AppLock._();

  static const _storage = FlutterSecureStorage();
  static const _kHash = 'app_pin_hash';
  static const _kSalt = 'app_pin_salt';
  static const grace = Duration(minutes: 1);

  static final ValueNotifier<bool> unlocked = ValueNotifier<bool>(false);
  static DateTime? _hiddenAt;

  static String get mode => Prefs.appLockMode;
  static bool get enabled => mode != 'off';
  static bool get needsPin => mode == 'pin_bio';

  /// Call once at startup.
  static void init() {
    unlocked.value = !enabled;
  }

  static Future<bool> hasPin() async {
    try {
      return (await _storage.read(key: _kHash))?.isNotEmpty == true;
    } catch (_) {
      return false;
    }
  }

  static Future<void> setPin(String pin) async {
    final salt = _salt();
    await _storage.write(key: _kSalt, value: salt);
    await _storage.write(key: _kHash, value: hash(pin, salt));
  }

  static Future<void> clearPin() async {
    await _storage.delete(key: _kHash);
    await _storage.delete(key: _kSalt);
  }

  static Future<bool> checkPin(String pin) async {
    final salt = await _storage.read(key: _kSalt) ?? '';
    final h = await _storage.read(key: _kHash) ?? '';
    if (h.isEmpty) return true;
    return hash(pin, salt) == h;
  }

  static String hash(String pin, String salt) => sha256.convert(utf8.encode('$salt:$pin')).toString();

  static String _salt() {
    final r = Random.secure();
    return List.generate(16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }

  // ───────────── biometrics ─────────────

  static final _auth = LocalAuthentication();

  static Future<bool> biometricsAvailable() async {
    if (!(Platform.isAndroid || Platform.isIOS || Platform.isWindows)) return false;
    try {
      final can = await _auth.canCheckBiometrics || await _auth.isDeviceSupported();
      return can;
    } catch (_) {
      return false;
    }
  }

  /// The phone has a lock of its own that can be asked now (a screen PIN or
  /// pattern, or an enrolled fingerprint or face).
  static Future<bool> deviceLockSet() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _auth.isDeviceSupported();
    } catch (_) {
      return false;
    }
  }

  /// The phone's own prompt (fingerprint, face, or device PIN as fallback).
  static Future<bool> biometric({String reason = 'Unlock BYTE'}) async {
    try {
      // local_auth 3.x: no AuthenticationOptions; defaults allow device PIN fallback.
      return await _auth.authenticate(localizedReason: reason);
    } catch (e) {
      debugPrint('[lock] biometric: $e');
      return false;
    }
  }

  // ───────────── lifecycle ─────────────

  static void onHidden() {
    if (!enabled) return;
    // Kept from the first call: on the way back Android reports "hidden"
    // once more before "resumed".
    _hiddenAt ??= DateTime.now();
  }

  /// True when the gate must show again.
  static bool onResumed() {
    if (!enabled) return false;
    final h = _hiddenAt;
    _hiddenAt = null;
    if (h == null) return false;
    if (DateTime.now().difference(h) >= grace) {
      unlocked.value = false;
      return true;
    }
    return false;
  }

  static void lockNow() {
    if (!enabled) return;
    unlocked.value = false;
  }

  static void unlock() => unlocked.value = true;
}
