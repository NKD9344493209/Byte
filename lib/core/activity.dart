import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../features/capture/audio_repo.dart';
import '../features/library/collections_repo.dart';
import '../features/library/library_repo.dart';
import '../features/notes/notes_repo.dart';
import 'db.dart';

/// One line of the activity list.
class ActivityEntry {
  const ActivityEntry({required this.id, required this.at, required this.kind, required this.summary, required this.undo, required this.undone});

  final int id;
  final DateTime at;

  /// bin | expire | rename | names | folder
  final String kind;
  final String summary;

  /// What is needed to take it back (empty = cannot be undone).
  final Map<String, dynamic> undo;
  final bool undone;

  bool get canUndo => undo.isNotEmpty && !undone;

  static ActivityEntry fromRow(Map<String, Object?> r) {
    Map<String, dynamic> undo = const {};
    try {
      final raw = '${r['undo'] ?? ''}';
      if (raw.isNotEmpty) {
        final j = jsonDecode(raw);
        if (j is Map<String, dynamic>) undo = j;
      }
    } catch (_) {}
    return ActivityEntry(
      id: (r['id'] as int?) ?? 0,
      at: DateTime.fromMillisecondsSinceEpoch((r['at'] as int?) ?? 0),
      kind: '${r['kind'] ?? ''}',
      summary: '${r['summary'] ?? ''}',
      undo: undo,
      undone: ((r['undone'] as int?) ?? 0) == 1,
    );
  }
}

/// What BYTE did lately — moved to the bin, renamed, filed, deleted by
/// date — with an Undo for each. Things in the private space are never
/// written here.
class Activity {
  Activity._();

  static final ValueNotifier<int> changed = ValueNotifier<int>(0);

  /// True while an undo is running: what it does is not logged as new activity.
  static bool _quiet = false;
  static bool get quiet => _quiet;

  static List<String> _ids(Object? v) => v is List ? [for (final x in v) '$x'] : const <String>[];

  /// Writes one line. Never throws: the list is a convenience, not a duty.
  static Future<void> log(String kind, String summary, {Map<String, Object?>? undo}) async {
    if (_quiet) return;
    try {
      final db = AppDb.instance.db;
      await db.insert('activity', {
        'at': DateTime.now().millisecondsSinceEpoch,
        'kind': kind,
        'summary': summary,
        'undo': undo == null ? '' : jsonEncode(undo),
      });
      // Only the last 500 are kept.
      await db.rawDelete('DELETE FROM activity WHERE id <= (SELECT MAX(id) FROM activity) - 500');
      changed.value++;
    } catch (e) {
      debugPrint('[activity] log: $e');
    }
  }

  /// Items were just moved to the bin: one line for those that are not private.
  static Future<void> logBin(List<String> ids) async {
    if (_quiet || ids.isEmpty) return;
    try {
      final db = AppDb.instance.db;
      final open = <String>[];
      var title = '';
      for (var from = 0; from < ids.length; from += 400) {
        final chunk = ids.sublist(from, from + 400 > ids.length ? ids.length : from + 400);
        final marks = List.filled(chunk.length, '?').join(',');
        for (final r in await db.rawQuery('SELECT id, title FROM items WHERE private = 0 AND id IN ($marks)', chunk)) {
          open.add('${r['id']}');
          if (title.isEmpty) title = '${r['title'] ?? ''}'.trim();
        }
      }
      if (open.isEmpty) return;
      final summary = open.length == 1 ? (title.isEmpty ? 'Moved 1 item to the bin' : 'Moved "$title" to the bin') : 'Moved ${open.length} items to the bin';
      await log('bin', summary, undo: {'ids': open});
    } catch (e) {
      debugPrint('[activity] bin: $e');
    }
  }

  static Future<List<ActivityEntry>> recent({int limit = 200}) async {
    try {
      final rows = await AppDb.instance.db.query('activity', orderBy: 'id DESC', limit: limit);
      return rows.map(ActivityEntry.fromRow).toList();
    } catch (e) {
      debugPrint('[activity] recent: $e');
      return const [];
    }
  }

  /// Takes [e] back. Returns what to tell the user.
  static Future<String> undo(ActivityEntry e) async {
    if (!e.canUndo) return 'This one cannot be undone.';
    final db = AppDb.instance.db;
    _quiet = true;
    String said;
    try {
      switch (e.kind) {
        case 'bin':
        case 'expire':
          final ids = _ids(e.undo['ids']);
          await LibraryRepo.instance.restoreMany(ids); // (also drops a last day that has passed)
          NotesRepo.instance.revision.value++;
          AudioRepo.instance.revision.value++;
          var back = 0;
          for (var from = 0; from < ids.length; from += 400) {
            final chunk = ids.sublist(from, from + 400 > ids.length ? ids.length : from + 400);
            final marks = List.filled(chunk.length, '?').join(',');
            back += ((await db.rawQuery('SELECT COUNT(*) AS n FROM items WHERE deleted_at IS NULL AND id IN ($marks)', chunk)).first['n'] as int?) ?? 0;
          }
          said = back == 0 ? 'Nothing left to bring back (the bin was emptied).' : '$back item${back == 1 ? ' is' : 's are'} back.';
        case 'rename':
          final id = '${e.undo['id']}';
          if ((await db.rawQuery('SELECT 1 FROM items WHERE id = ?', [id])).isEmpty) {
            said = 'That item is not in BYTE any more.';
          } else {
            await LibraryRepo.instance.rename(id, '${e.undo['old'] ?? ''}');
            AudioRepo.instance.revision.value++;
            NotesRepo.instance.revision.value++;
            said = 'The old name is back.';
          }
        case 'names':
          final items = e.undo['items'];
          var n = 0;
          if (items is List) {
            await db.transaction((txn) async {
              for (final it in items) {
                if (it is! Map) continue;
                // Only where the name is still the one BYTE gave: a name you
                // typed since then is yours.
                n += it['new'] == null
                    ? await txn.rawUpdate('UPDATE items SET title = ? WHERE id = ?', ['${it['old'] ?? ''}', '${it['id']}'])
                    : await txn.rawUpdate('UPDATE items SET title = ? WHERE id = ? AND title = ?', ['${it['old'] ?? ''}', '${it['id']}', '${it['new']}']);
              }
            });
          }
          LibraryRepo.instance.touch();
          AudioRepo.instance.revision.value++;
          NotesRepo.instance.revision.value++;
          said = '$n name${n == 1 ? ' is' : 's are'} as before.';
        case 'folder':
          final folder = '${e.undo['folder'] ?? ''}';
          final ids = _ids(e.undo['ids']);
          await db.transaction((txn) async {
            for (final id in ids) {
              await txn.delete('collection_items', where: 'collection_id = ? AND item_id = ?', whereArgs: [folder, id]);
            }
          });
          // A folder BYTE made for this, now empty, goes too.
          if (e.undo['created'] == true) {
            final left = ((await db.rawQuery('SELECT COUNT(*) AS n FROM collection_items WHERE collection_id = ?', [folder])).first['n'] as int?) ?? 0;
            if (left == 0) await db.delete('collections', where: 'id = ?', whereArgs: [folder]);
          }
          CollectionsRepo.instance.revision.value++;
          LibraryRepo.instance.touch();
          said = 'They are out of that folder again.';
        default:
          said = 'This one cannot be undone.';
      }
      await db.rawUpdate('UPDATE activity SET undone = 1 WHERE id = ?', [e.id]);
    } catch (err) {
      debugPrint('[activity] undo: $err');
      said = 'That could not be undone: $err';
    } finally {
      _quiet = false;
    }
    changed.value++;
    return said;
  }
}
