import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../../core/activity.dart';
import '../../core/bubble.dart';
import '../../core/db.dart';
import '../search/words.dart';
import 'note.dart';

/// All reads/writes for text notes. Screens never touch SQL directly.
class NotesRepo {
  NotesRepo._();
  static final NotesRepo instance = NotesRepo._();

  static const _uuid = Uuid();

  /// Bumped after every write so other screens (Library) can refresh.
  final ValueNotifier<int> revision = ValueNotifier<int>(0);
  void _bump() => revision.value++;

  /// [private] false (the default) leaves out the notes of the private space.
  Future<List<Note>> list({String query = '', bool private = false}) async {
    final db = AppDb.instance.db;
    final q = query.trim();
    final mine = "type = 'note' AND deleted_at IS NULL AND private = ${private ? 1 : 0}";
    final rows = q.isEmpty
        ? await db.query(
            'items',
            where: mine,
            orderBy: 'updated_at DESC',
          )
        : await db.query(
            'items',
            where:
                '$mine AND (title LIKE ? OR body LIKE ? OR tags LIKE ?)',
            whereArgs: ['%$q%', '%$q%', '%$q%'],
            orderBy: 'updated_at DESC',
          );
    return rows.map(Note.fromRow).toList();
  }

  Future<Note?> get(String id) async {
    final rows = await AppDb.instance.db.query(
      'items',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return Note.fromRow(rows.first);
  }

  /// [id]: only for a list that was started outside BYTE (the control-centre
  /// panel), which already goes by that id in the notification.
  Future<Note> create({
    String title = '',
    String body = '',
    List<String> tags = const [],
    bool private = false,
    String? id,
  }) async {
    final now = DateTime.now();
    final note = Note(
      id: id ?? _uuid.v4(),
      title: title,
      body: body,
      tags: tags,
      createdAt: now,
      updatedAt: now,
      private: private,
    );
    await AppDb.instance.db.insert('items', note.toRow());
    // Words of a private note stay out of Search's spelling list.
    if (!private) await Words.add([title, body]);
    _bump();
    return note;
  }

  Future<void> update(Note note) async {
    final db = AppDb.instance.db;
    await db.transaction((txn) async {
      // Keep the previous version — nothing is ever lost.
      final prev = await txn.query('items',
          columns: ['title', 'body'], where: 'id = ?', whereArgs: [note.id]);
      if (prev.isNotEmpty) {
        await txn.insert('item_history', {
          'item_id': note.id,
          'title': prev.first['title'],
          'body': prev.first['body'],
          'saved_at': DateTime.now().millisecondsSinceEpoch,
        });
      }
      await txn.update(
        'items',
        {
          'title': note.title,
          'body': note.body,
          'tags': note.tags.join(','),
          'updated_at': DateTime.now().millisecondsSinceEpoch,
        },
        where: 'id = ?',
        whereArgs: [note.id],
      );
    });
    if (!note.private) await Words.add([note.title, note.body]); // for spelling-forgiving search
    _bump();
    unawaited(Bubble.noteSaved(note.id)); // a pinned checklist follows its note
  }

  /// Soft delete: recoverable for 30 days (purge job comes later).
  Future<void> delete(String id) async {
    await AppDb.instance.db.update(
      'items',
      {'deleted_at': DateTime.now().millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: [id],
    );
    _bump();
    unawaited(Bubble.noteSaved(id)); // a binned note is unpinned
    unawaited(Activity.logBin([id]));
  }

  /// Undo a delete.
  Future<void> restore(String id) async {
    await AppDb.instance.db.rawUpdate(
      'UPDATE items SET deleted_at = NULL, expires_at = CASE WHEN expires_at <= ? THEN NULL ELSE expires_at END WHERE id = ?',
      [DateTime.now().millisecondsSinceEpoch, id],
    );
    _bump();
  }

  /// Find the note someone means by a few spoken words: exact title, then a
  /// title that contains them, then the most word-overlap in title + body.
  Future<Note?> findByWords(String words) async {
    final q = words.toLowerCase().replaceAll(RegExp(r'[^a-z0-9\u0B80-\u0BFF ]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    if (q.isEmpty) return null;
    final all = await list();
    for (final n in all) {
      if (n.title.toLowerCase().trim() == q) return n;
    }
    for (final n in all) {
      if (n.title.toLowerCase().contains(q)) return n;
    }
    final ws = q.split(' ').where((w) => w.length >= 3).toSet();
    if (ws.isEmpty) return null;
    Note? best;
    var bestScore = 0;
    for (final n in all) {
      final hay = '${n.title} ${n.body}'.toLowerCase();
      final score = ws.where(hay.contains).length;
      if (score > bestScore) {
        bestScore = score;
        best = n;
      }
    }
    return bestScore >= (ws.length >= 2 ? 2 : 1) ? best : null;
  }

  Future<int> count() async {
    final rows = await AppDb.instance.db.rawQuery(
      "SELECT COUNT(*) AS c FROM items WHERE type = 'note' AND deleted_at IS NULL AND private = 0",
    );
    return (rows.first['c'] as int?) ?? 0;
  }
}
