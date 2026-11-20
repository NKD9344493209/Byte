import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'cloud_sync.dart';
import 'db.dart';
import 'storage_rules.dart';

export 'storage_rules.dart';

/// Walks everything inside BYTE's private folder once and sorts it into
/// buckets (recordings, photos, thumbnails, vault, backups, cache, …), so the
/// Storage screen and the Home nag show the same numbers Android does.
/// The result is cached for 10 minutes; [invalidate] after deleting things.
class StorageAudit {
  StorageAudit._();

  static const ttl = Duration(minutes: 10);
  static const nagBytes = 250 << 20;

  static AuditReport? _cache;
  static Future<AuditReport>? _inFlight;

  static AuditReport? get last => _cache;

  static void invalidate() => _cache = null;

  static Future<AuditReport> run({bool force = false}) async {
    final c = _cache;
    if (!force && c != null && DateTime.now().difference(c.at) < ttl) return c;
    final f = _inFlight;
    if (f != null) return f;
    final job = _measure();
    _inFlight = job;
    try {
      final r = await job;
      _cache = r;
      return r;
    } finally {
      _inFlight = null;
    }
  }

  static Future<AuditReport> _measure() async {
    final roots = await getRoots();
    final files = await walk(roots);
    return AuditReport.fromFiles(files, rootsNote: 'Folders: ${roots.support} · ${roots.cache}');
  }

  static Future<StorageRoots> getRoots() async {
    final support = await getApplicationSupportDirectory();
    final cache = await getTemporaryDirectory();
    String docs = '';
    try {
      docs = (await getApplicationDocumentsDirectory()).path;
    } catch (_) {}
    String external = '';
    if (Platform.isAndroid) {
      try {
        external = (await getExternalStorageDirectory())?.path ?? '';
      } catch (_) {}
    }
    return StorageRoots(support: support.path, cache: cache.path, docs: docs, external: external);
  }

  /// Every file under the app's private folder. On Android that is the parent
  /// of the support dir (`/data/user/0/<pkg>`: files, cache, app_flutter,
  /// shared_prefs, databases, code_cache …) plus the external files dir, so
  /// the total matches what Settings → Apps counts as data + cache.
  static Future<List<AuditFile>> walk(StorageRoots roots) async {
    final dirs = <String>{};
    if (Platform.isAndroid) {
      dirs.add(p.dirname(roots.support));
      if (roots.external.isNotEmpty) dirs.add(roots.external);
    } else {
      dirs.addAll([roots.support, roots.cache, if (roots.docs.isNotEmpty) roots.docs]);
    }
    final seen = <String>{};
    final out = <AuditFile>[];
    for (final d in dirs) {
      final dir = Directory(d);
      if (!await dir.exists()) continue;
      try {
        await for (final e in dir.list(recursive: true, followLinks: false)) {
          if (e is! File) continue;
          final path = normPath(e.path);
          if (!seen.add(path)) continue;
          try {
            final st = await e.stat();
            out.add(AuditFile(path: path, size: st.size, modified: st.modified, cat: classify(path, roots)));
          } catch (_) {}
        }
      } catch (e) {
        debugPrint('[audit] $d: $e');
      }
    }
    return out;
  }

  /// The vault row a file belongs to (for the Storage screen's biggest list).
  static Future<({String id, String title, String kind, bool isThumb})?> itemFor(String path) async {
    final db = AppDb.instance.db;
    for (final alt in {path, path.replaceAll('/', '\\')}) {
      final a = await db.rawQuery('SELECT i.id, i.title, i.type FROM audio a JOIN items i ON i.id = a.item_id WHERE a.path = ? LIMIT 1', [alt]);
      if (a.isNotEmpty) return (id: a.first['id'] as String, title: (a.first['title'] as String? ?? '').trim(), kind: a.first['type'] as String? ?? 'audio', isThumb: false);
      final f = await db.rawQuery('SELECT i.id, i.title, i.type, f.thumb FROM files f JOIN items i ON i.id = f.item_id WHERE f.path = ? OR f.thumb = ? LIMIT 1', [alt, alt]);
      if (f.isNotEmpty) {
        return (id: f.first['id'] as String, title: (f.first['title'] as String? ?? '').trim(), kind: f.first['type'] as String? ?? '', isThumb: normPath(f.first['thumb'] as String? ?? '') == normPath(path));
      }
    }
    return null;
  }

  /// Delete one file right now (the Storage screen's bin button). Returns bytes freed.
  static Future<int> removeFile(String path) async {
    final f = File(path);
    try {
      final n = await f.length();
      await f.delete();
      invalidate();
      return n;
    } catch (_) {
      return 0;
    }
  }
}

class CleanResult {
  const CleanResult({required this.at, required this.bytes, required this.files, this.thumbsSlimmed = 0});
  final DateTime at;
  final int bytes;
  final int files;
  final int thumbsSlimmed;

  Map<String, Object?> toJson() => {'at': at.millisecondsSinceEpoch, 'bytes': bytes, 'files': files, 'thumbs': thumbsSlimmed};
  static CleanResult? fromJson(String? s) {
    if (s == null || s.isEmpty) return null;
    try {
      final j = jsonDecode(s) as Map;
      return CleanResult(
        at: DateTime.fromMillisecondsSinceEpoch((j['at'] as num?)?.toInt() ?? 0),
        bytes: (j['bytes'] as num?)?.toInt() ?? 0,
        files: (j['files'] as num?)?.toInt() ?? 0,
        thumbsSlimmed: (j['thumbs'] as num?)?.toInt() ?? 0,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Removes what nothing needs any more: picker/cache/temp leftovers older than
/// an hour, backup and export ZIPs kept inside the app, half-finished
/// downloads, media files no vault row points to (older than a day), and the
/// WAV/M4A twin left behind by a shrink or expand. Also re-saves big PNG
/// thumbnails as JPEG. Runs at launch, on resume once a day and from the
/// 6-hourly background job; "Clean up now" on the Storage screen.
class StorageCleaner {
  StorageCleaner._();

  static const kLast = 'storage_last_clean';
  static bool _busy = false;
  static bool get busy => _busy;
  static final ValueNotifier<String> status = ValueNotifier<String>('');

  static Future<CleanResult?> last() async => CleanResult.fromJson((await SharedPreferences.getInstance()).getString(kLast));

  /// Launch / background: never throws.
  static Future<void> runQuietly() async {
    try {
      final r = await run();
      debugPrint('[clean] freed ${fmtBytes(r.bytes)} in ${r.files} file(s), ${r.thumbsSlimmed} thumb(s) slimmed');
    } catch (e) {
      debugPrint('[clean] $e');
    }
  }

  /// On resume: only when the last run is more than a day old.
  static Future<void> runIfDue() async {
    try {
      final l = await last();
      if (l != null && DateTime.now().difference(l.at) < const Duration(hours: 24)) return;
      await runQuietly();
    } catch (_) {}
  }

  static Future<CleanResult> run({DateTime? now, void Function(String)? onStatus}) async {
    if (_busy) return CleanResult(at: DateTime.now(), bytes: 0, files: 0);
    _busy = true;
    void say(String s) {
      status.value = s;
      onStatus?.call(s);
    }

    try {
      final n = now ?? DateTime.now();
      say('Looking at every file…');
      final roots = await StorageAudit.getRoots();
      final files = await StorageAudit.walk(roots);
      final referenced = await _referenced();
      final existing = {for (final f in files) f.path};
      // A recording in progress is safe: its row is only written at stop, and
      // an unreferenced WAV is never removed before it is a day old.
      var freed = 0;
      var count = 0;
      for (final f in files) {
        final why = cleanReason(f, now: n, referenced: referenced, existing: existing);
        if (why == null) continue;
        try {
          await File(f.path).delete();
          freed += f.size;
          count++;
          debugPrint('[clean] $why: ${f.name} (${fmtBytes(f.size)})');
        } catch (e) {
          debugPrint('[clean] could not delete ${f.name}: $e');
        }
      }
      say('Tidying folders…');
      await _dropEmptyDirs(Directory(roots.cache));
      say('Slimming thumbnails…');
      var slimmed = 0;
      try {
        final r = await _slimThumbs();
        slimmed = r.count;
        freed += r.saved;
      } catch (e) {
        debugPrint('[clean] thumbs: $e');
      }
      final result = CleanResult(at: n, bytes: freed, files: count, thumbsSlimmed: slimmed);
      try {
        await (await SharedPreferences.getInstance()).setString(kLast, jsonEncode(result.toJson()));
      } catch (_) {}
      StorageAudit.invalidate();
      say('');
      return result;
    } finally {
      _busy = false;
    }
  }

  /// Every path the vault points at (deleted rows too — the purge owns those).
  static Future<Set<String>> _referenced() async {
    final db = AppDb.instance.db;
    final out = <String>{};
    for (final r in await db.rawQuery('SELECT path FROM audio')) {
      final s = r['path'] as String? ?? '';
      if (s.isNotEmpty) out.add(normPath(s));
    }
    for (final r in await db.rawQuery('SELECT path, thumb FROM files')) {
      for (final k in const ['path', 'thumb']) {
        final s = r[k] as String? ?? '';
        if (s.isNotEmpty) out.add(normPath(s));
      }
    }
    return out;
  }

  /// image_picker leaves one `<uuid>/` folder per pick: drop the empty ones.
  static Future<void> _dropEmptyDirs(Directory root) async {
    if (!await root.exists()) return;
    try {
      await for (final e in root.list(followLinks: false)) {
        if (e is! Directory) continue;
        try {
          if (await e.list().isEmpty) await e.delete();
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// Photo thumbnails used to be written as PNG (300–600 KB each); JPEG at
  /// 480 px is ~40 KB. Convert the big ones and repoint the row.
  static Future<({int count, int saved})> _slimThumbs() async {
    const minBytes = 120 * 1024;
    var count = 0;
    var saved = 0;
    final db = AppDb.instance.db;
    final rows = await db.rawQuery("SELECT item_id, thumb FROM files WHERE thumb LIKE '%.png'");
    for (final r in rows) {
      final thumb = r['thumb'] as String? ?? '';
      if (thumb.isEmpty) continue;
      final f = File(thumb);
      try {
        if (!await f.exists()) continue;
        final before = await f.length();
        if (before < minBytes) continue;
        final out = await compute(_pngToJpg, await f.readAsBytes());
        if (out == null || out.length >= before) continue;
        final newPath = p.setExtension(thumb, '.jpg');
        await File('$newPath.tmp').writeAsBytes(out, flush: true);
        await File('$newPath.tmp').rename(newPath);
        await db.update('files', {'thumb': newPath}, where: 'item_id = ?', whereArgs: [r['item_id']]);
        try {
          await f.delete();
        } catch (_) {}
        try {
          await CloudSync.forgetFile('thumbs/${p.basename(thumb)}');
        } catch (_) {}
        count++;
        saved += before - out.length;
      } catch (e) {
        debugPrint('[clean] thumb ${p.basename(thumb)}: $e');
      }
    }
    return (count: count, saved: saved);
  }

  static Uint8List? _pngToJpg(Uint8List bytes) {
    final image = img.decodePng(bytes);
    if (image == null) return null;
    return Uint8List.fromList(img.encodeJpg(image, quality: 80));
  }
}
