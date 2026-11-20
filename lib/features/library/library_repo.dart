import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../../core/activity.dart';
import '../../core/bubble.dart';
import '../../core/db.dart';
import '../../core/drive_media.dart';
import '../../core/gallery.dart';
import '../../core/private_names.dart';
import '../search/words.dart';
import 'library_item.dart';

/// Files + links in the vault, and one search across everything
/// (notes and recordings included).
class LibraryRepo {
  LibraryRepo._();
  static final LibraryRepo instance = LibraryRepo._();

  final ValueNotifier<int> revision = ValueNotifier<int>(0);
  Database get _db => AppDb.instance.db;
  void _bump() => revision.value++;

  Future<Directory> filesDir() async {
    final dir = Directory(p.join((await getApplicationSupportDirectory()).path, 'files'));
    await dir.create(recursive: true);
    return dir;
  }

  Future<Directory> thumbsDir() async {
    final dir = Directory(p.join((await getApplicationSupportDirectory()).path, 'thumbs'));
    await dir.create(recursive: true);
    return dir;
  }

  // ───────────── add ─────────────

  /// Copies the file into the vault folder and records it. Returns the item.
  Future<LibraryItem> importFile(
    String sourcePath, {
    String? displayName,
    String source = 'picker',
    bool move = false,
    bool private = false,
  }) async {
    final src = File(sourcePath);
    final name = displayName ?? p.basename(sourcePath);
    final kind = LibraryKindX.forPath(name);
    final id = const Uuid().v4();
    final ext = p.extension(name).toLowerCase();
    final dst = p.join((await filesDir()).path, '$id$ext');
    if (move) {
      try {
        await src.rename(dst);
      } catch (_) {
        await src.copy(dst);
      }
    } else {
      await src.copy(dst);
    }
    final size = await File(dst).length();
    final now = DateTime.now().millisecondsSinceEpoch;
    final title = p.basenameWithoutExtension(name);

    await _db.transaction((txn) async {
      await txn.insert('items', {
        'id': id,
        'type': kind.name,
        'title': title,
        'body': '',
        'tags': '',
        'sensitivity': 0,
        'source': source,
        'created_at': now,
        'updated_at': now,
        // Added straight into the private space: never seen outside it.
        if (private) 'private': 1,
      });
      await txn.insert('files', {
        'item_id': id,
        'kind': kind.name,
        'path': dst,
        'url': '',
        'mime': _mimeFor(ext),
        'size': size,
        'thumb': '',
        'text': '',
        'labels': '',
        'index_status': 'pending',
      });
    });
    _bump();
    final item = (await get(id))!;
    // Photos and videos go to Google Drive by themselves.
    unawaited(DriveMedia.queue(item));
    return item;
  }

  Future<LibraryItem> addLink(String url, {String title = '', String source = 'manual'}) async {
    var u = url.trim();
    if (!u.startsWith('http://') && !u.startsWith('https://')) u = 'https://$u';
    final id = const Uuid().v4();
    final now = DateTime.now().millisecondsSinceEpoch;
    await _db.transaction((txn) async {
      await txn.insert('items', {
        'id': id,
        'type': LibraryKind.link.name,
        'title': title,
        'body': '',
        'tags': '',
        'sensitivity': 0,
        'source': source,
        'created_at': now,
        'updated_at': now,
      });
      await txn.insert('files', {
        'item_id': id,
        'kind': LibraryKind.link.name,
        'path': '',
        'url': u,
        'mime': 'text/uri-list',
        'size': 0,
        'thumb': '',
        'text': '',
        'labels': '',
        'index_status': 'pending',
      });
    });
    _bump();
    return (await get(id))!;
  }

  // ───────────── read ─────────────

  static const _cols = '''
    i.id, i.type, i.title, i.body, i.tags, i.created_at, i.pinned, i.deleted_at, i.private,
    f.path, f.url, f.mime, f.size, f.thumb, f.labels, f.index_status, f.media_key,
    a.path AS audio_path, a.duration_ms''';
  static const _from = '''
    FROM items i
    LEFT JOIN files f ON f.item_id = i.id
    LEFT JOIN audio a ON a.item_id = i.id
  ''';

  /// With the text BYTE read from the file (search and the viewer need it).
  static const _select = "SELECT $_cols, COALESCE(f.text, a.clean_text, '') AS text $_from";

  /// Without that text: a long PDF carries hundreds of thousands of letters,
  /// and a list that only shows names and previews should not load them.
  static const _selectLite = "SELECT $_cols, '' AS text $_from";

  Future<LibraryItem?> get(String id) async {
    final rows = await _db.rawQuery('$_select WHERE i.id = ?', [id]);
    if (rows.isEmpty) return null;
    return _fromRow(rows.first);
  }

  /// Everything, newest first; optional kind and free-text query.
  /// The query matches title, tags, note body, extracted text, labels, url.
  /// Each word is expanded with synonyms ("animal" → dog, cat…).
  /// [starred] keeps only starred items. [limit]/[offset] page through a big
  /// library (the timeline loads more as you scroll). [withText] false leaves
  /// out the text read from each file — lists that only show names and
  /// previews stay light.
  /// [since] keeps only what was saved (or taken) on or after that moment;
  /// [folderId] only what is filed in that folder.
  /// [until] only what is older than that moment; [place] only what BYTE
  /// sorted into that album; [mainOnly] leaves out screenshots and pictures
  /// that other apps saved (they have their own albums).
  /// [pictures] only photos and videos (when no [kind] is given).
  /// [onDay] only what was taken on that day of the year in an earlier year
  /// ("On this day").
  /// [private] false (the default) leaves out everything in the private
  /// space; true lists only that.
  Future<List<LibraryItem>> list({
    LibraryKind? kind,
    String query = '',
    bool starred = false,
    int limit = 500,
    int offset = 0,
    bool withText = true,
    DateTime? since,
    DateTime? until,
    String? folderId,
    String? place,
    bool mainOnly = false,
    bool pictures = false,
    DateTime? onDay,
    bool private = false,
  }) async {
    final where = <String>['i.deleted_at IS NULL', 'i.private = ${private ? 1 : 0}'];
    final args = <Object?>[];
    if (onDay != null) {
      // The same month and day on the phone's own clock, before this year.
      where.add("strftime('%m-%d', i.created_at / 1000, 'unixepoch', 'localtime') = ?");
      args.add('${onDay.month.toString().padLeft(2, '0')}-${onDay.day.toString().padLeft(2, '0')}');
      where.add('i.created_at < ?');
      args.add(DateTime(onDay.year).millisecondsSinceEpoch);
    }
    if (starred) where.add('i.pinned = 1');
    if (since != null) {
      where.add('i.created_at >= ?');
      args.add(since.millisecondsSinceEpoch);
    }
    if (until != null) {
      where.add('i.created_at < ?');
      args.add(until.millisecondsSinceEpoch);
    }
    if (folderId != null) {
      where.add('i.id IN (SELECT item_id FROM collection_items WHERE collection_id = ?)');
      args.add(folderId);
    }
    if (place != null) {
      where.add('i.id IN (SELECT item_id FROM item_places WHERE place = ?)');
      args.add(place);
    }
    // The main list: camera photos and what you added yourself. Screenshots
    // and pictures from other apps live in their own albums.
    if (mainOnly) where.add("(f.src IS NULL OR f.src = '' OR f.src = 'Camera')");
    if (kind != null) {
      where.add('i.type = ?');
      args.add(kind.name);
    } else {
      // [pictures]: only photos and videos (the Gallery).
      where.add(pictures ? "i.type IN ('photo','video')" : "i.type IN ('photo','video','doc','link','audio','note')");
    }
    final words = query.trim().toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    for (final w in words) {
      final variants = expandQueryWord(w);
      final ors = <String>[];
      for (final v in variants) {
        // a.clean_text: the words of a voice note.
        ors.add('(i.title LIKE ? OR i.tags LIKE ? OR i.body LIKE ? OR f.text LIKE ? OR f.labels LIKE ? OR f.url LIKE ? OR a.clean_text LIKE ?)');
        final like = '%$v%';
        args.addAll([like, like, like, like, like, like, like]);
      }
      where.add('(${ors.join(' OR ')})');
    }
    // The id breaks ties: things saved in the same millisecond keep one order
    // from page to page, so nothing repeats or goes missing at a page edge.
    final rows = await _db.rawQuery(
      '${withText ? _select : _selectLite} WHERE ${where.join(' AND ')} ORDER BY i.created_at DESC, i.id DESC LIMIT ? OFFSET ?',
      [...args, limit, offset],
    );
    return rows.map(_fromRow).toList();
  }

  /// How many voice notes, notes, documents and links were added after the
  /// moment you last looked at each kind ([seen]: kind → milliseconds).
  Future<Map<LibraryKind, int>> newSince(Map<LibraryKind, int> seen) async {
    final out = <LibraryKind, int>{};
    if (seen.isEmpty) return out;
    var oldest = seen.values.first;
    for (final v in seen.values) {
      if (v < oldest) oldest = v;
    }
    final rows = await _db.rawQuery(
      "SELECT type, created_at FROM items WHERE deleted_at IS NULL AND private = 0 AND type IN ('audio','note','doc','link') AND created_at > ?",
      [oldest],
    );
    for (final r in rows) {
      final k = LibraryKindX.parse(r['type'] as String?);
      final at = seen[k];
      if (k != null && at != null && ((r['created_at'] as int?) ?? 0) > at) out[k] = (out[k] ?? 0) + 1;
    }
    return out;
  }

  /// The albums BYTE sorted a thing into ("Camera", "Food").
  Future<List<String>> placesOf(String id) async {
    final rows = await _db.rawQuery('SELECT place FROM item_places WHERE item_id = ?', [id]);
    return [for (final r in rows) '${r['place']}'];
  }

  /// The album YOU chose for a thing: '' = let BYTE decide, '-' = none of
  /// them, else the album's name.
  Future<String> fixedPlace(String id) async {
    final rows = await _db.rawQuery('SELECT fixed FROM files WHERE item_id = ?', [id]);
    return rows.isEmpty ? '' : '${rows.first['fixed'] ?? ''}';
  }

  /// Your choice is kept: BYTE's own sorting never changes it again.
  Future<void> setFixedPlace(String id, String fixed) async {
    await _db.rawUpdate('UPDATE files SET fixed = ?, sorted = 0 WHERE item_id = ?', [fixed, id]);
    _bump();
  }

  /// Which of [ids] are still in the Library (not in the bin, not private).
  Future<Set<String>> inLibrary(List<String> ids) async {
    if (ids.isEmpty) return <String>{};
    final marks = List.filled(ids.length, '?').join(',');
    final rows = await _db.rawQuery('SELECT id FROM items WHERE id IN ($marks) AND deleted_at IS NULL AND private = 0', ids);
    return {for (final r in rows) '${r['id']}'};
  }

  /// How many items are not in the bin (the Search tab says "N things").
  Future<int> total({bool private = false}) async {
    final rows = await _db.rawQuery(
      "SELECT COUNT(*) AS n FROM items WHERE deleted_at IS NULL AND private = ${private ? 1 : 0} "
      "AND type IN ('photo','video','doc','link','audio','note')",
    );
    return (rows.first['n'] as int?) ?? 0;
  }

  /// BYTE's own recordings that are not in the bin — exactly what the Voice
  /// notes list shows (audio files shared in from other apps are not counted).
  Future<int> voiceNoteCount() async {
    final rows = await _db.rawQuery(
      "SELECT COUNT(*) AS n FROM items i JOIN audio a ON a.item_id = i.id "
      "WHERE i.type = 'audio' AND i.deleted_at IS NULL AND i.private = 0",
    );
    return (rows.first['n'] as int?) ?? 0;
  }

  Future<Map<LibraryKind, int>> counts({bool private = false}) async {
    final rows = await _db.rawQuery(
      "SELECT type, COUNT(*) AS n FROM items WHERE deleted_at IS NULL AND private = ${private ? 1 : 0} "
      "AND type IN ('photo','video','doc','link','audio','note') GROUP BY type",
    );
    final out = <LibraryKind, int>{};
    for (final r in rows) {
      final k = LibraryKindX.parse(r['type'] as String?);
      if (k != null) out[k] = r['n'] as int;
    }
    return out;
  }

  Future<List<LibraryItem>> pendingIndex() async {
    final rows = await _db.rawQuery(
      // Newest first: after bringing in a gallery, this year's photos become
      // searchable before the ones from years ago.
      // A locked (private) file cannot be read: it was read before it was locked.
      "$_select WHERE i.deleted_at IS NULL AND f.index_status IN ('pending','working') "
      "AND f.path NOT LIKE '%$sealedExt' "
      'ORDER BY i.created_at DESC LIMIT 20',
    );
    return rows.map(_fromRow).toList();
  }

  // ───────────── update ─────────────

  Future<void> rename(String id, String title) async {
    final before = await _db.rawQuery('SELECT title, private FROM items WHERE id = ?', [id]);
    await _db.update(
      'items',
      {'title': title.trim(), 'updated_at': DateTime.now().millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: [id],
    );
    // In the activity list, with the old name to go back to (not for private things).
    if (before.isNotEmpty && before.first['private'] != 1) {
      final old = '${before.first['title'] ?? ''}';
      if (old.trim() != title.trim()) {
        unawaited(Activity.log('rename', old.trim().isEmpty ? 'Named "${title.trim()}"' : 'Renamed "${old.trim()}" to "${title.trim()}"', undo: {'id': id, 'old': old}));
      }
    }
    _bump();
  }

  /// Sticky note on any item (stored in items.body for non-notes).
  Future<void> setNote(String id, String note) async {
    await _db.update(
      'items',
      {'body': note.trim(), 'updated_at': DateTime.now().millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: [id],
    );
    _bump();
  }

  Future<void> setTags(String id, List<String> tags) async {
    await _db.update(
      'items',
      {'tags': tags.map((t) => t.trim()).where((t) => t.isNotEmpty).join(','), 'updated_at': DateTime.now().millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: [id],
    );
    _bump();
  }

  Future<void> setIndexed(
    String id, {
    String? text,
    List<String>? labels,
    String? thumb,
    String? title,
    String? seen,
    required String status,
    bool quiet = false,
  }) async {
    final f = <String, Object?>{'index_status': status};
    if (seen != null) f['seen'] = seen;
    if (text != null) f['text'] = text;
    if (labels != null) f['labels'] = labels.join(',');
    if (thumb != null) f['thumb'] = thumb;
    // Read (again): its albums are worked out again from what was found.
    if (status != 'working' && status != 'pending') f['sorted'] = 0;
    await _db.update('files', f, where: 'item_id = ?', whereArgs: [id]);
    if (title != null && title.trim().isNotEmpty) {
      // Only fill a title in if the user hasn't set one.
      await _db.rawUpdate(
        "UPDATE items SET title = ? WHERE id = ? AND (title = '' OR title IS NULL)",
        [title.trim(), id],
      );
    }
    // What was just read goes into the word list (spelling-forgiving search)
    // — unless it is private: Search must not hint at a word from in there.
    if (text != null || labels != null || title != null) {
      final own = await _db.rawQuery('SELECT private FROM items WHERE id = ?', [id]);
      if (own.isEmpty || own.first['private'] != 1) {
        await Words.add([text ?? '', (labels ?? const <String>[]).join(' '), title ?? '']);
      }
    }
    // [quiet]: the reader works through thousands of gallery photos; it tells
    // the screens every few items ([touch]) instead of after each one.
    if (!quiet) _bump();
  }

  /// "Something changed" for the screens that list the Library.
  void touch() => _bump();

  Future<void> resetIndex(String id) async {
    await _db.update('files', {'index_status': 'pending'}, where: 'item_id = ?', whereArgs: [id]);
    _bump();
  }

  /// Moves an item to the bin. Nothing is destroyed: the file, its preview
  /// and its Google Drive copy all stay for 30 days, so [restore] brings
  /// everything back exactly as it was.
  Future<void> delete(String id) => deleteMany([id]);

  /// Several at once: one change notice at the end, so lists reload once.
  Future<void> deleteMany(Iterable<String> ids) async {
    final list = ids.toList();
    if (list.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    await _db.transaction((txn) async {
      for (final id in list) {
        await txn.update('items', {'deleted_at': now}, where: 'id = ? AND deleted_at IS NULL', whereArgs: [id]);
      }
    });
    _bump();
    unawaited(DriveMedia.refresh()); // a photo in the bin is no longer "waiting to upload"
    unawaited(Bubble.refreshPin()); // a pinned checklist that went to the bin is unpinned
    unawaited(Activity.logBin(list)); // "Moved 3 items to the bin", with an Undo
  }

  // ───────────── the bin ─────────────

  /// Everything in the bin (files, links, notes, voice notes), most recently
  /// deleted first, with the moment it was deleted.
  /// [private]: the private space has a bin of its own.
  Future<List<(LibraryItem, DateTime)>> listDeleted({bool private = false}) async {
    final rows = await _db.rawQuery(
      "$_selectLite WHERE i.deleted_at IS NOT NULL AND i.private = ${private ? 1 : 0} AND i.type IN ('photo','video','doc','link','audio','note') "
      'ORDER BY i.deleted_at DESC, i.id DESC LIMIT 1000',
    );
    return [
      for (final r in rows) (_fromRow(r), DateTime.fromMillisecondsSinceEpoch((r['deleted_at'] as int?) ?? 0)),
    ];
  }

  /// The id of every item in the bin, however many ("Empty the bin").
  Future<List<String>> deletedIds({bool private = false}) async {
    final rows = await _db.rawQuery(
      "SELECT id FROM items WHERE deleted_at IS NOT NULL AND private = ${private ? 1 : 0} "
      "AND type IN ('photo','video','doc','link','audio','note')",
    );
    return [for (final r in rows) r['id'] as String];
  }

  Future<int> deletedCount({bool private = false}) async {
    final rows = await _db.rawQuery(
      "SELECT COUNT(*) AS n FROM items WHERE deleted_at IS NOT NULL AND private = ${private ? 1 : 0} "
      "AND type IN ('photo','video','doc','link','audio','note')",
    );
    return (rows.first['n'] as int?) ?? 0;
  }

  /// Out of the bin, back where it was (its folders too — those were never touched).
  Future<void> restore(String id) => restoreMany([id]);

  /// Several at once: one change notice at the end.
  Future<void> restoreMany(Iterable<String> ids) async {
    final list = ids.toList();
    if (list.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    await _db.transaction((txn) async {
      for (final id in list) {
        // A "delete by itself" day that passed while it lay in the bin is dropped
        // (or it would go straight back).
        await txn.rawUpdate(
          'UPDATE items SET deleted_at = NULL, expires_at = CASE WHEN expires_at <= ? THEN NULL ELSE expires_at END WHERE id = ?',
          [now, id],
        );
      }
    });
    _bump();
    // Photos and videos: make sure each is (still) on its way to Drive.
    final back = <LibraryItem>[];
    for (final id in list) {
      final rows = await _db.rawQuery('$_selectLite WHERE i.id = ?', [id]);
      if (rows.isNotEmpty) back.add(_fromRow(rows.first));
    }
    await DriveMedia.onRestored(back);
  }

  /// Removes an item for good: BYTE's own files on the phone, the Google
  /// Drive copy (to Drive's Trash) and every row about it. There is no undo.
  /// Only files inside BYTE's own storage are ever deleted.
  Future<void> deleteForever(String id) => deleteForeverMany([id]);

  /// Several at once: one change notice and one Drive pass at the end.
  Future<void> deleteForeverMany(Iterable<String> ids) async {
    final list = ids.toList();
    if (list.isEmpty) return;
    final own = (await getApplicationSupportDirectory()).path;
    final originals = <String, String>{}; // gallery number → the file it is
    for (final id in list) {
      final (key, path) = await _removeForGood(id, own);
      if (key.isNotEmpty && path.isNotEmpty) originals[key] = path;
    }
    // After the rows are gone: their Drive copies go to Drive's Trash.
    await DriveMedia.sweepDeleted();
    _bump();
    // Photos that live in the phone's gallery: Android asks once whether the
    // originals may go too. Whatever the answer, BYTE no longer lists them.
    if (originals.isNotEmpty) await Gallery.deleteOriginals(originals);
  }

  /// Returns the item's gallery number and file ('' when BYTE kept the file itself).
  Future<(String, String)> _removeForGood(String id, String own) async {
    final rows = await _db.rawQuery(
      'SELECT a.path AS apath, f.path AS fpath, f.thumb AS fthumb, f.media_key AS mkey FROM items i '
      'LEFT JOIN audio a ON a.item_id = i.id '
      'LEFT JOIN files f ON f.item_id = i.id WHERE i.id = ?',
      [id],
    );
    if (rows.isEmpty) return ('', '');
    final mediaKey = (rows.first['mkey'] as String?) ?? '';
    final mediaPath = mediaKey.isEmpty ? '' : ((rows.first['fpath'] as String?) ?? '');
    for (final key in const ['apath', 'fpath', 'fthumb']) {
      final path = rows.first[key] as String?;
      if (path == null || path.isEmpty || !p.isWithin(own, path)) continue;
      try {
        final f = File(path);
        if (await f.exists()) await f.delete();
      } catch (e) {
        debugPrint('[library] delete file: $e');
      }
    }
    await _db.transaction((txn) async {
      // Remembered, so the next look at the gallery does not list it again.
      if (mediaKey.isNotEmpty) await txn.rawInsert('INSERT OR IGNORE INTO gallery_skip (media_key) VALUES (?)', [mediaKey]);
      await txn.delete('collection_items', where: 'item_id = ?', whereArgs: [id]);
      await txn.delete('item_history', where: 'item_id = ?', whereArgs: [id]);
      await txn.delete('item_places', where: 'item_id = ?', whereArgs: [id]);
      await txn.delete('files', where: 'item_id = ?', whereArgs: [id]);
      await txn.delete('audio', where: 'item_id = ?', whereArgs: [id]);
      await txn.delete('items', where: 'id = ?', whereArgs: [id]);
    });
    return (mediaKey, mediaPath);
  }

  // ───────────── helpers ─────────────

  LibraryItem _fromRow(Map<String, Object?> r) {
    final m = Map<String, Object?>.from(r);
    // BYTE's own recordings keep their file in the audio table; audio files
    // shared in from other apps (call recordings, mp3s) live in files.path.
    if (m['type'] == 'audio' && (m['audio_path'] as String?)?.isNotEmpty == true) {
      m['path'] = m['audio_path'];
    }
    return LibraryItem.fromRow(m);
  }

  static String _mimeFor(String ext) {
    const map = {
      '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.png': 'image/png', '.webp': 'image/webp',
      '.gif': 'image/gif', '.heic': 'image/heic', '.bmp': 'image/bmp',
      '.mp4': 'video/mp4', '.mkv': 'video/x-matroska', '.mov': 'video/quicktime', '.webm': 'video/webm',
      '.3gp': 'video/3gpp', '.avi': 'video/x-msvideo', '.m4v': 'video/x-m4v',
      '.pdf': 'application/pdf',
      '.xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      '.xls': 'application/vnd.ms-excel', '.csv': 'text/csv',
      '.pptx': 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
      '.ppt': 'application/vnd.ms-powerpoint',
      '.docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      '.doc': 'application/msword', '.txt': 'text/plain', '.md': 'text/markdown',
      '.wav': 'audio/wav', '.mp3': 'audio/mpeg', '.m4a': 'audio/mp4', '.ogg': 'audio/ogg',
    };
    return map[ext] ?? 'application/octet-stream';
  }
}
