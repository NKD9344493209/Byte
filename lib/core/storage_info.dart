import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'storage_audit.dart';

/// What takes up space inside BYTE (so "862 MB" has an explanation).
/// Numbers come from [StorageAudit] — one walk of the whole private folder,
/// so they add up to what Android shows.
class StorageInfo {
  const StorageInfo({required this.recordings, required this.libraryFiles, required this.thumbs, required this.vault, required this.cache, this.other = 0});
  final int recordings;
  final int libraryFiles;
  final int thumbs;
  final int vault;
  final int cache;

  /// Backups/exports kept inside the app, the speech model, everything else.
  final int other;

  int get total => recordings + libraryFiles + thumbs + vault + cache + other;

  static Future<StorageInfo> measure() async {
    final a = await StorageAudit.run();
    return StorageInfo(
      recordings: a.of(StorageCat.wav) + a.of(StorageCat.aac),
      libraryFiles: a.of(StorageCat.photo) + a.of(StorageCat.video) + a.of(StorageCat.doc) + a.of(StorageCat.file),
      thumbs: a.of(StorageCat.thumbs),
      vault: a.of(StorageCat.db),
      cache: a.of(StorageCat.cache) + a.of(StorageCat.picker) + a.of(StorageCat.temp),
      other: a.of(StorageCat.backup) + a.of(StorageCat.model) + a.of(StorageCat.other),
    );
  }

  static Future<int> dirSize(Directory d) async {
    if (!await d.exists()) return 0;
    var n = 0;
    try {
      await for (final f in d.list(recursive: true, followLinks: false)) {
        if (f is File) n += await f.length();
      }
    } catch (_) {}
    return n;
  }

  /// Deletes the temp cache (safe: it is rebuilt on demand).
  static Future<int> clearCache() async {
    final tmp = await getTemporaryDirectory();
    final before = await dirSize(tmp);
    try {
      await for (final f in tmp.list()) {
        try {
          await f.delete(recursive: true);
        } catch (_) {}
      }
    } catch (_) {}
    StorageAudit.invalidate();
    return before;
  }

  static String fmt(int bytes) {
    if (bytes >= 1 << 30) return '${(bytes / (1 << 30)).toStringAsFixed(2)} GB';
    if (bytes >= 1 << 20) return '${(bytes / (1 << 20)).toStringAsFixed(1)} MB';
    if (bytes >= 1 << 10) return '${(bytes / (1 << 10)).toStringAsFixed(0)} KB';
    return '$bytes B';
  }
}
