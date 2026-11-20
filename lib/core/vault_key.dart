import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// The vault's 256-bit database key.
///
/// Generated once, stored in the platform's secure store (Android Keystore /
/// Windows DPAPI). The hex form is the recovery key the user writes down.
class VaultKey {
  VaultKey._();

  static const _storage = FlutterSecureStorage();
  static const _k = 'byte_vault_key_v1';

  static String? _cached;

  /// 64 hex chars (32 bytes). Created on first call.
  static Future<String> get() async {
    final c = _cached;
    if (c != null) return c;
    var hex = await _storage.read(key: _k);
    if (hex == null || hex.length != 64) {
      hex = _randomHex(32);
      await _storage.write(key: _k, value: hex);
    }
    _cached = hex;
    return hex;
  }

  /// Replace the stored key (used when restoring a vault with a recovery key).
  static Future<void> set(String hex) async {
    if (hex.length != 64 || !RegExp(r'^[0-9a-fA-F]+$').hasMatch(hex)) {
      throw ArgumentError('Recovery key must be 64 hex characters');
    }
    await _storage.write(key: _k, value: hex.toLowerCase());
    _cached = hex.toLowerCase();
  }

  /// Groups of 4 for reading aloud / writing down.
  static String pretty(String hex) {
    final b = StringBuffer();
    for (var i = 0; i < hex.length; i += 4) {
      if (i > 0) b.write(i % 16 == 0 ? '\n' : ' ');
      b.write(hex.substring(i, i + 4).toUpperCase());
    }
    return b.toString();
  }

  static String _randomHex(int bytes) {
    final r = Random.secure();
    final sb = StringBuffer();
    for (var i = 0; i < bytes; i++) {
      sb.write(r.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }
}
