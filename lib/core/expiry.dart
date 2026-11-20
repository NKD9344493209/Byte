import 'dart:async';

import 'package:flutter/foundation.dart';

import '../features/capture/audio_repo.dart';
import '../features/library/library_repo.dart';
import '../features/notes/notes_repo.dart';
import 'activity.dart';
import 'bubble.dart';
import 'db.dart';
import 'drive_media.dart';

/// "Delete by itself": something you only need for a while (a ticket, an
/// OTP screenshot, a form) can be given a last day. On that day it moves to
/// the bin — where it still waits 30 days, so even this is never a loss.
class Expiry {
  Expiry._();

  /// [days] from now; null = keep for good.
  static Future<void> setFor(Iterable<String> ids, int? days) async {
    final at = days == null ? null : DateTime.now().add(Duration(days: days)).millisecondsSinceEpoch;
    final db = AppDb.instance.db;
    await db.transaction((txn) async {
      for (final id in ids) {
        await txn.rawUpdate('UPDATE items SET expires_at = ? WHERE id = ?', [at, id]);
      }
    });
    LibraryRepo.instance.touch();
  }

  /// The day [id] deletes itself, or null.
  static Future<DateTime?> of(String id) async {
    try {
      final rows = await AppDb.instance.db.rawQuery('SELECT expires_at FROM items WHERE id = ?', [id]);
      final at = rows.isEmpty ? null : rows.first['expires_at'] as int?;
      return at == null ? null : DateTime.fromMillisecondsSinceEpoch(at);
    } catch (_) {
      return null;
    }
  }

  static bool _running = false;

  /// Moves everything whose day has come to the bin. Returns how many.
  /// Called when BYTE opens and when it comes back to the front.
  static Future<int> runDue() async {
    if (_running) return 0;
    _running = true;
    try {
      final db = AppDb.instance.db;
      final now = DateTime.now().millisecondsSinceEpoch;
      final rows = await db.rawQuery('SELECT id, private FROM items WHERE expires_at IS NOT NULL AND expires_at <= ? AND deleted_at IS NULL LIMIT 2000', [now]);
      if (rows.isEmpty) return 0;
      await db.transaction((txn) async {
        for (final r in rows) {
          await txn.rawUpdate('UPDATE items SET deleted_at = ?, expires_at = NULL WHERE id = ? AND deleted_at IS NULL', [now, r['id']]);
        }
      });
      LibraryRepo.instance.touch();
      NotesRepo.instance.revision.value++;
      AudioRepo.instance.revision.value++;
      unawaited(DriveMedia.refresh()); // in the bin = no longer "waiting to upload"
      unawaited(Bubble.refreshPin()); // a pinned checklist that went is unpinned
      // (Private things are not named in the activity list.)
      final open = [
        for (final r in rows)
          if (r['private'] != 1) '${r['id']}',
      ];
      if (open.isNotEmpty) {
        await Activity.log(
          'expire',
          open.length == 1 ? '1 item reached its last day and went to the bin' : '${open.length} items reached their last day and went to the bin',
          undo: {'ids': open},
        );
      }
      return rows.length;
    } catch (e) {
      debugPrint('[expiry] $e');
      return 0;
    } finally {
      _running = false;
    }
  }
}
