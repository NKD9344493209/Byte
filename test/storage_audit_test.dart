import 'package:byte/core/storage_rules.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final roots = StorageRoots(
    support: '/data/user/0/com.naveen.byteapp/files',
    cache: '/data/user/0/com.naveen.byteapp/cache',
    docs: '/data/user/0/com.naveen.byteapp/app_flutter',
    external: '/storage/emulated/0/Android/data/com.naveen.byteapp/files',
  );
  const s = '/data/user/0/com.naveen.byteapp/files';
  const c = '/data/user/0/com.naveen.byteapp/cache';
  final now = DateTime(2026, 11, 5, 12);

  AuditFile f(String path, {int size = 1000, Duration age = const Duration(days: 2)}) => AuditFile(path: path, size: size, modified: now.subtract(age), cat: classify(path, roots));

  group('classify', () {
    test('recordings, library files, thumbnails, vault', () {
      expect(classify('$s/audio/a.wav', roots), StorageCat.wav);
      expect(classify('$s/audio/a.M4A', roots), StorageCat.aac);
      expect(classify('$s/files/x.mp4', roots), StorageCat.video);
      expect(classify('$s/files/x.jpeg', roots), StorageCat.photo);
      expect(classify('$s/files/x.pdf', roots), StorageCat.doc);
      expect(classify('$s/files/x.mp3', roots), StorageCat.file);
      expect(classify('$s/files/fix-1699.jpg', roots), StorageCat.temp);
      expect(classify('$s/thumbs/id.png', roots), StorageCat.thumbs);
      expect(classify('$s/thumbs/frame-id-2.jpg', roots), StorageCat.temp);
      expect(classify('$s/byte_vault.enc.db', roots), StorageCat.db);
      expect(classify('$s/byte_vault.enc.db-wal', roots), StorageCat.db);
      expect(classify('$s/byte_vault.db.migrated', roots), StorageCat.temp);
      expect(classify('$s/byte_vault.enc.db.pre-restore', roots), StorageCat.temp);
      expect(classify('$s/cloud-restore.enc.db.part', roots), StorageCat.temp);
      expect(classify('$s/cloud-snapshot.enc.db', roots), StorageCat.temp);
    });
    test('backups, exports, model, cache, picker', () {
      expect(classify('$s/latest-backup.zip', roots), StorageCat.backup);
      expect(classify('$s/byte-backup-20261101-0900.zip', roots), StorageCat.backup);
      expect(classify('$s/exports/byte-export-20261101-0900.zip', roots), StorageCat.backup);
      expect(classify('$s/models/whisper-base/base-decoder.int8.onnx', roots), StorageCat.model);
      expect(classify('$s/models/whisper-base/base-decoder.int8.onnx.part', roots), StorageCat.temp);
      expect(classify('$c/file_picker/report.pdf', roots), StorageCat.picker);
      expect(classify('$c/5f1a2b3c-1234-4abc-9def-0123456789ab/VID_2026.mp4', roots), StorageCat.picker);
      expect(classify('$c/scaled_IMG_1.jpg', roots), StorageCat.picker);
      expect(classify('$c/shared/1699-photo.jpg', roots), StorageCat.picker);
      expect(classify('$c/picked-1699.zip', roots), StorageCat.cache);
      expect(classify('$c/abc-1699.wav', roots), StorageCat.cache);
      expect(classify('$c/exports/byte-export-1.zip', roots), StorageCat.cache);
      expect(classify('/storage/emulated/0/Android/data/com.naveen.byteapp/files/Pictures/IMG_1.jpg', roots), StorageCat.picker);
      expect(classify('/storage/emulated/0/Android/data/com.naveen.byteapp/files/x.bin', roots), StorageCat.other);
      expect(classify('/data/user/0/com.naveen.byteapp/shared_prefs/FlutterSharedPreferences.xml', roots), StorageCat.other);
      expect(classify('/data/user/0/com.naveen.byteapp/app_flutter/x', roots), StorageCat.other);
    });
    test('windows separators are fine', () {
      final w = StorageRoots(support: r'C:\Users\s\AppData\byte', cache: r'C:\Users\s\AppData\Local\Temp\byte');
      expect(classify(r'C:\Users\s\AppData\byte\audio\a.wav', w), StorageCat.wav);
      expect(classify(r'C:\Users\s\AppData\Local\Temp\byte\x.tmp', w), StorageCat.temp);
    });
  });

  group('cleanReason', () {
    test('never touches the vault, the model or unknown app data', () {
      for (final path in ['$s/byte_vault.enc.db', '$s/byte_vault.enc.db-wal', '$s/models/whisper-base/base-decoder.int8.onnx', '/data/user/0/com.naveen.byteapp/shared_prefs/x.xml']) {
        expect(cleanReason(f(path, age: const Duration(days: 400)), now: now, referenced: {}, existing: {}), isNull, reason: path);
      }
    });
    test('picker/cache/temp go after an hour, zips in cache after six', () {
      expect(cleanReason(f('$c/file_picker/a.mp4', age: const Duration(minutes: 30)), now: now, referenced: {}, existing: {}), isNull);
      expect(cleanReason(f('$c/file_picker/a.mp4', age: const Duration(minutes: 61)), now: now, referenced: {}, existing: {}), isNotNull);
      expect(cleanReason(f('$c/abc-1.wav', age: const Duration(minutes: 61)), now: now, referenced: {}, existing: {}), isNotNull);
      expect(cleanReason(f('$c/picked-1.zip', age: const Duration(hours: 2)), now: now, referenced: {}, existing: {}), isNull);
      expect(cleanReason(f('$c/picked-1.zip', age: const Duration(hours: 7)), now: now, referenced: {}, existing: {}), isNotNull);
      expect(cleanReason(f('$s/models/whisper-base/x.onnx.part', age: const Duration(hours: 2)), now: now, referenced: {}, existing: {}), isNotNull);
      expect(cleanReason(f('$s/byte_vault.db.migrated'), now: now, referenced: {}, existing: {}), isNotNull);
    });
    test('backup copies inside the app go after an hour', () {
      expect(cleanReason(f('$s/latest-backup.zip', age: const Duration(minutes: 10)), now: now, referenced: {}, existing: {}), isNull);
      expect(cleanReason(f('$s/latest-backup.zip', age: const Duration(hours: 3)), now: now, referenced: {}, existing: {}), contains('Downloads'));
      expect(cleanReason(f('$s/exports/byte-export-1.zip', age: const Duration(hours: 3)), now: now, referenced: {}, existing: {}), isNotNull);
    });
    test('vault media: referenced → keep; orphan → only after a day', () {
      final wav = '$s/audio/a.wav';
      expect(cleanReason(f(wav, age: const Duration(days: 30)), now: now, referenced: {wav}, existing: {wav}), isNull);
      expect(cleanReason(f(wav, age: const Duration(hours: 5)), now: now, referenced: {}, existing: {wav}), isNull);
      expect(cleanReason(f(wav, age: const Duration(hours: 25)), now: now, referenced: {}, existing: {wav}), isNotNull);
      final mp4 = '$s/files/v.mp4';
      expect(cleanReason(f(mp4, age: const Duration(days: 3)), now: now, referenced: {mp4}, existing: {mp4}), isNull);
      expect(cleanReason(f(mp4, age: const Duration(days: 3)), now: now, referenced: {}, existing: {mp4}), isNotNull);
      final th = '$s/thumbs/t.png';
      expect(cleanReason(f(th, age: const Duration(days: 3)), now: now, referenced: {th}, existing: {th}), isNull);
      expect(cleanReason(f(th, age: const Duration(days: 3)), now: now, referenced: {}, existing: {th}), isNotNull);
    });
    test('a deleted-but-not-purged row still protects its file', () {
      final wav = '$s/audio/bin.wav';
      expect(cleanReason(f(wav, age: const Duration(days: 20)), now: now, referenced: {wav}, existing: {wav}), isNull);
    });
    test('WAV/M4A twin: the one the vault does not name goes at once', () {
      final wav = '$s/audio/a.wav';
      final m4a = '$s/audio/a.m4a';
      // shrink finished, WAV delete failed → the row names the m4a
      expect(cleanReason(f(wav, age: const Duration(minutes: 5)), now: now, referenced: {m4a}, existing: {wav, m4a}), contains('leftover'));
      // expanded for "continue recording", m4a delete failed → the row names the wav
      expect(cleanReason(f(m4a, age: const Duration(minutes: 5)), now: now, referenced: {wav}, existing: {wav, m4a}), isNotNull);
      // a lone fresh WAV (being recorded right now) is left alone
      expect(cleanReason(f(wav, age: const Duration(minutes: 5)), now: now, referenced: {}, existing: {wav}), isNull);
    });
    test('backslash paths in the vault still count as referenced', () {
      final wav = '$s/audio/a.wav';
      expect(cleanReason(f(wav, age: const Duration(days: 9)), now: now, referenced: {normPath(wav.replaceAll('/', '\\'))}, existing: {wav}), isNull);
    });
  });

  group('AuditReport', () {
    test('sums per bucket, ranks, picks the biggest, prints a report', () {
      final files = [
        f('$s/audio/a.wav', size: 600 << 20),
        f('$s/audio/b.m4a', size: 20 << 20),
        f('$s/files/v.mp4', size: 90 << 20),
        f('$s/latest-backup.zip', size: 100 << 20),
        f('$c/file_picker/v.mp4', size: 90 << 20),
        f('$s/byte_vault.enc.db', size: 3 << 20),
      ];
      final r = AuditReport.fromFiles(files, at: now, top: 3);
      expect(r.total, 903 << 20);
      expect(r.of(StorageCat.wav), 600 << 20);
      expect(r.countOf(StorageCat.wav), 1);
      expect(r.ranked.first, StorageCat.wav);
      expect(r.biggest.length, 3);
      expect(r.biggest.first.name, 'a.wav');
      final text = r.reportText(appNote: 'plus the app');
      expect(text, contains('903 MB'));
      expect(text, contains('Recordings · WAV'));
      expect(text, contains('Biggest files'));
      expect(text, contains('latest-backup.zip'));
    });
    test('fmtBytes', () {
      expect(fmtBytes(0), '0 B');
      expect(fmtBytes(3072), '3 KB');
      expect(fmtBytes(5 << 20), '5.0 MB');
      expect(fmtBytes(610 << 20), '610 MB');
      expect(fmtBytes(3 << 30), '3.00 GB');
    });
  });

  group('storageNag (Home suggestion)', () {
    test('silent under 250 MB, one line above it', () {
      final small = AuditReport.fromFiles([f('$s/audio/a.wav', size: 100 << 20)], at: now);
      expect(storageNag(small), isNull);
      final big = AuditReport.fromFiles([
        f('$s/audio/a.wav', size: 610 << 20),
        f('$s/files/v.mp4', size: 150 << 20),
        f('$s/models/whisper-base/d.onnx', size: 102 << 20),
      ], at: now);
      final n = storageNag(big)!;
      expect(n.title, 'BYTE is using 862 MB — 610 MB is old recordings not shrunk yet. Shrink now?');
      expect(n.subtitle, contains('WAV recordings 610 MB'));
      expect(n.subtitle, contains('Opens Storage'));
    });
    test('wording follows the biggest bucket', () {
      final r = AuditReport.fromFiles([f('$s/latest-backup.zip', size: 300 << 20), f('$s/audio/a.m4a', size: 10 << 20)], at: now);
      expect(storageNag(r)!.title, endsWith('backup copies kept inside the app. Clean up now?'));
      final v = AuditReport.fromFiles([f('$s/files/v.mp4', size: 300 << 20)], at: now);
      expect(storageNag(v)!.title, endsWith('videos. See what can go?'));
    });
    test('threshold is adjustable', () {
      final r = AuditReport.fromFiles([f('$s/audio/a.wav', size: 100 << 20)], at: now);
      expect(storageNag(r, threshold: 50 << 20), isNotNull);
    });
  });
}
