import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../../core/activity.dart';
import '../../core/db.dart';
import '../search/words.dart';
import 'audio_item.dart';

/// Reads/writes voice recordings: one row in `items` (type=audio)
/// plus one row in `audio`, and the file itself under the vault's audio dir.
class AudioRepo {
  AudioRepo._();
  static final AudioRepo instance = AudioRepo._();

  static const _uuid = Uuid();

  /// Bumps whenever recordings change, so open screens can refresh.
  final ValueNotifier<int> revision = ValueNotifier<int>(0);
  void _changed() => revision.value++;

  /// Folder where recordings live. Created on first use.
  Future<Directory> audioDir() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory(p.join(base.path, 'audio'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// A fresh file path for a new recording (not yet created).
  Future<(String id, String path)> newRecordingPath() async {
    final id = _uuid.v4();
    final dir = await audioDir();
    return (id, p.join(dir.path, '$id.wav'));
  }

  static const _select = '''
      SELECT i.id, i.title, i.tags, i.created_at, i.body,
             a.path, a.duration_ms, a.raw_transcript, a.clean_text,
             a.transcript_status
      FROM items i JOIN audio a ON a.item_id = i.id
  ''';

  Future<AudioItem> save({
    required String id,
    required String path,
    required Duration duration,
    String source = 'manual',
  }) async {
    final now = DateTime.now();
    final title = 'Voice note · ${_stamp(now)}';
    final db = AppDb.instance.db;
    await db.transaction((txn) async {
      await txn.insert('items', {
        'id': id,
        'type': 'audio',
        'title': title,
        'body': '',
        'tags': '',
        'source': source,
        'created_at': now.millisecondsSinceEpoch,
        'updated_at': now.millisecondsSinceEpoch,
      });
      await txn.insert('audio', {
        'item_id': id,
        'path': path,
        'duration_ms': duration.inMilliseconds,
        'transcript_status': 'pending',
      });
    });
    _changed();
    return AudioItem(
      id: id,
      title: title,
      path: path,
      durationMs: duration.inMilliseconds,
      rawTranscript: '',
      cleanText: '',
      transcriptStatus: 'pending',
      tags: const [],
      createdAt: now,
    );
  }

  Future<AudioItem?> get(String id) async {
    final rows = await AppDb.instance.db.rawQuery(
      '$_select WHERE i.id = ? LIMIT 1',
      [id],
    );
    if (rows.isEmpty) return null;
    return AudioItem.fromRow(rows.first);
  }

  Future<List<AudioItem>> list({String query = ''}) async {
    final db = AppDb.instance.db;
    final q = query.trim();
    final where = StringBuffer("i.type = 'audio' AND i.deleted_at IS NULL AND i.private = 0");
    final args = <Object?>[];
    if (q.isNotEmpty) {
      where.write(
        ' AND (i.title LIKE ? OR a.raw_transcript LIKE ? OR a.clean_text LIKE ? OR i.tags LIKE ? OR i.body LIKE ?)',
      );
      args.addAll(['%$q%', '%$q%', '%$q%', '%$q%', '%$q%']);
    }
    final rows = await db.rawQuery(
      '$_select WHERE $where ORDER BY i.created_at DESC',
      args,
    );
    return rows.map(AudioItem.fromRow).toList();
  }

  Future<void> updateTranscript(
    String id, {
    required String raw,
    required String clean,
    String status = 'done',
  }) async {
    await AppDb.instance.db.update(
      'audio',
      {'raw_transcript': raw, 'clean_text': clean, 'transcript_status': status},
      where: 'item_id = ?',
      whereArgs: [id],
    );
    await Words.add([clean]); // so search forgives a spelling slip in spoken words too
    _changed();
  }

  /// After continuing a recording: the new total length.
  Future<void> updateDuration(String id, Duration d) async {
    await AppDb.instance.db.update('audio', {'duration_ms': d.inMilliseconds}, where: 'item_id = ?', whereArgs: [id]);
    await AppDb.instance.db.update('items', {'updated_at': DateTime.now().millisecondsSinceEpoch}, where: 'id = ?', whereArgs: [id]);
    _changed();
  }

  /// Playlists are tags on the recording ("motivation", "ideas").
  Future<void> setTags(String id, List<String> tags) async {
    final clean = tags.map((t) => t.trim()).where((t) => t.isNotEmpty).toSet().toList();
    await AppDb.instance.db.update(
      'items',
      {'tags': clean.join(','), 'updated_at': DateTime.now().millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: [id],
    );
    _changed();
  }

  /// Every playlist name in use, with counts, most used first.
  Future<List<(String, int)>> playlists() async {
    final rows = await AppDb.instance.db.rawQuery("SELECT tags FROM items WHERE type = 'audio' AND deleted_at IS NULL AND private = 0 AND tags != ''");
    final counts = <String, int>{};
    for (final r in rows) {
      for (final t in (r['tags'] as String? ?? '').split(',')) {
        final k = t.trim();
        if (k.isNotEmpty) counts[k] = (counts[k] ?? 0) + 1;
      }
    }
    final out = counts.entries.map((e) => (e.key, e.value)).toList()..sort((a, b) => b.$2.compareTo(a.$2));
    return out;
  }

  /// User-given title for a voice note.
  Future<void> rename(String id, String title) async {
    final before = await AppDb.instance.db.rawQuery('SELECT title, private FROM items WHERE id = ?', [id]);
    if (before.isNotEmpty && before.first['private'] != 1) {
      final old = '${before.first['title'] ?? ''}';
      if (old.trim() != title.trim()) {
        unawaited(Activity.log('rename', 'Renamed "${old.trim()}" to "${title.trim()}"', undo: {'id': id, 'old': old}));
      }
    }
    await AppDb.instance.db.update(
      'items',
      {'title': title.trim(), 'updated_at': DateTime.now().millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: [id],
    );
    _changed();
  }

  /// Sticky note on a recording.
  Future<void> setNote(String id, String note) async {
    await AppDb.instance.db.update(
      'items',
      {'body': note.trim(), 'updated_at': DateTime.now().millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: [id],
    );
    _changed();
  }

  Future<void> setTranscriptStatus(String id, String status) async {
    await AppDb.instance.db.update(
      'audio',
      {'transcript_status': status},
      where: 'item_id = ?',
      whereArgs: [id],
    );
    _changed();
  }

  /// Soft delete. The file stays until the 30-day purge.
  Future<void> delete(String id) async {
    await AppDb.instance.db.update(
      'items',
      {'deleted_at': DateTime.now().millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: [id],
    );
    _changed();
    unawaited(Activity.logBin([id]));
  }

  static String _stamp(DateTime t) {
    final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
    final m = t.minute.toString().padLeft(2, '0');
    final ap = t.hour < 12 ? 'am' : 'pm';
    return '${t.day}/${t.month} $h:$m $ap';
  }
}
