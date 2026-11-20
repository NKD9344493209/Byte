import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import '../features/library/library_repo.dart';
import 'cloud_sync.dart';
import 'db.dart';

/// Photo shrinking: camera photos are 3–8 MB each; at 2048 px / JPEG 82 they
/// look the same on a phone screen at ~0.5 MB. Only on request (it's lossy).
class PhotoSlim {
  PhotoSlim._();

  static const maxSide = 2048;
  static const minBytes = 1200 * 1024; // leave small photos alone

  static Future<({int count, int bytes})> pending() async {
    var count = 0;
    var bytes = 0;
    for (final r in await _rows()) {
      count++;
      bytes += r.size;
    }
    return (count: count, bytes: (bytes * 0.8).round());
  }

  static Future<List<({String id, String path, int size})>> _rows() async {
    final rows = await AppDb.instance.db.rawQuery('''
      SELECT f.item_id AS id, f.path AS path, f.size AS size
      FROM files f JOIN items i ON i.id = f.item_id
      WHERE i.deleted_at IS NULL AND i.private = 0 AND i.type = 'photo' AND f.path != '' AND f.media_key = '' AND f.size > ?
        AND (lower(f.path) LIKE '%.jpg' OR lower(f.path) LIKE '%.jpeg' OR lower(f.path) LIKE '%.png' OR lower(f.path) LIKE '%.webp' OR lower(f.path) LIKE '%.heic')
      ORDER BY f.size DESC
    ''', [minBytes]);
    // Photos that live in Google Drive have no phone copy to shrink.
    return [
      for (final r in rows)
        if (File(r['path'] as String).existsSync()) (id: r['id'] as String, path: r['path'] as String, size: (r['size'] as num?)?.toInt() ?? 0),
    ];
  }

  static Future<({int count, int saved})> shrinkAll({void Function(String)? onStatus}) async {
    var count = 0;
    var saved = 0;
    for (final r in await _rows()) {
      final f = File(r.path);
      if (!await f.exists()) continue;
      onStatus?.call('Shrinking photo ${count + 1}…');
      try {
        final before = await f.length();
        final out = await compute(_reencode, await f.readAsBytes());
        if (out == null || out.length >= before * 0.7) continue; // not worth it
        final newPath = p.setExtension(r.path, '.jpg');
        // tmp → rename (atomic, overwrites when the name is unchanged) → DB → old file.
        // At every step the DB points at a file that exists.
        await File('$newPath.tmp').writeAsBytes(out, flush: true);
        await File('$newPath.tmp').rename(newPath);
        await AppDb.instance.db.update('files', {'path': newPath, 'size': out.length, 'mime': 'image/jpeg'}, where: 'item_id = ?', whereArgs: [r.id]);
        if (newPath != r.path) {
          try {
            await f.delete();
          } catch (_) {}
        }
        try {
          await CloudSync.forgetFile('files/${p.basename(r.path)}');
        } catch (_) {}
        count++;
        saved += before - out.length;
      } catch (e) {
        debugPrint('[slim] ${p.basename(r.path)}: $e');
      }
    }
    if (count > 0) LibraryRepo.instance.revision.value++;
    return (count: count, saved: saved);
  }

  static Uint8List? _reencode(Uint8List bytes) {
    var image = img.decodeImage(bytes);
    if (image == null) return null;
    image = img.bakeOrientation(image);
    if (image.width > maxSide || image.height > maxSide) {
      image = image.width >= image.height ? img.copyResize(image, width: maxSide) : img.copyResize(image, height: maxSide);
    }
    return Uint8List.fromList(img.encodeJpg(image, quality: 82));
  }
}

/// The biggest things in the vault, so the user can decide what to drop.
class BigItems {
  BigItems._();

  static Future<List<({String id, String title, String kind, String path, int size})>> top({int n = 15}) async {
    final rows = await AppDb.instance.db.rawQuery('''
      SELECT i.id, i.title, i.type, COALESCE(f.path, a.path) AS path, COALESCE(f.size, 0) AS size
      FROM items i LEFT JOIN files f ON f.item_id = i.id LEFT JOIN audio a ON a.item_id = i.id
      WHERE i.deleted_at IS NULL AND i.private = 0 AND (f.path IS NOT NULL OR a.path IS NOT NULL)
    ''');
    final out = <({String id, String title, String kind, String path, int size})>[];
    for (final r in rows) {
      final path = r['path'] as String? ?? '';
      if (path.isEmpty) continue;
      var size = (r['size'] as num?)?.toInt() ?? 0;
      if (size == 0) {
        try {
          size = await File(path).length();
        } catch (_) {
          continue;
        }
      }
      out.add((id: r['id'] as String, title: (r['title'] as String? ?? '').trim(), kind: r['type'] as String? ?? '', path: path, size: size));
    }
    out.sort((a, b) => b.size.compareTo(a.size));
    return out.take(n).toList();
  }
}
