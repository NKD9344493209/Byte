import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import '../../core/db.dart';
import 'heard.dart';

/// The words you taught BYTE, kept in the vault (table `heard_fixes`).
class HeardFixes {
  HeardFixes._();

  /// heard → meant, newest lessons included.
  static Future<Map<String, String>> all() async {
    try {
      final rows = await AppDb.instance.db.query('heard_fixes');
      return {for (final r in rows) '${r['heard']}': '${r['meant']}'};
    } catch (e) {
      debugPrint('[heard] all: $e');
      return const {};
    }
  }

  /// Learns from one correction (what BYTE [heard], what you [corrected] it
  /// to). Returns what was learned, so the screen can say so.
  static Future<Map<String, String>> learn(String heard, String corrected) async {
    final fixes = learnFixes(heard, corrected);
    if (fixes.isEmpty) return fixes;
    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      final db = AppDb.instance.db;
      for (final e in fixes.entries) {
        await db.insert('heard_fixes', {'heard': e.key, 'meant': e.value, 'at': now}, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    } catch (e) {
      debugPrint('[heard] learn: $e');
    }
    return fixes;
  }

  static Future<void> forget(String heard) async {
    try {
      await AppDb.instance.db.delete('heard_fixes', where: 'heard = ?', whereArgs: [heard]);
    } catch (e) {
      debugPrint('[heard] forget: $e');
    }
  }

  /// What a new voice note should read: every lesson applied.
  static Future<(String, int)> apply(String text) async => applyFixes(text, await all());

  /// The words you meant, as hints for the speech engine (newest first).
  static Future<List<String>> hints() async {
    try {
      final rows = await AppDb.instance.db.query('heard_fixes', columns: ['meant'], orderBy: 'at DESC', limit: 100);
      return [for (final r in rows) '${r['meant']}'];
    } catch (_) {
      return const [];
    }
  }
}
