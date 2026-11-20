import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:share_plus/share_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'cloud_sync.dart';
import 'db.dart';
import 'gallery.dart';
import 'private_space.dart';
import 'vault_key.dart';

/// Full backup = one ZIP with the encrypted vault file, every recording and a
/// manifest. On Android it lands in the public Downloads/BYTE folder (kept
/// after uninstall); on Windows in Documents/BYTE backups.
///
/// The ZIP is built in the cache folder and removed once it is saved: no copy
/// of the whole vault is kept inside the app (that used to double BYTE's
/// size). "Send backup…" builds a fresh one; the storage cleaner drops it
/// from the cache a few hours later.
///
/// The vault inside the ZIP stays encrypted — restoring on another device
/// needs the recovery key.
class BackupService {
  BackupService._();

  static const _files = MethodChannel('byte/files');
  static const _kLast = 'last_backup_at';
  static const _kAuto = 'auto_backup';
  static const _kLastName = 'last_backup_name';
  static const _kCloudAt = 'last_cloud_backup_at';
  static const _kCloudErr = 'last_cloud_backup_error';
  static const _kCloudUrl = 'backup_cloud_url'; // secure storage
  static const _secure = FlutterSecureStorage();

  static final ValueNotifier<int> changed = ValueNotifier<int>(0);

  static Future<DateTime?> lastBackup() async {
    final prefs = await SharedPreferences.getInstance();
    final ms = prefs.getInt(_kLast);
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  static Future<String?> lastBackupName() async =>
      (await SharedPreferences.getInstance()).getString(_kLastName);

  static Future<bool> autoEnabled() async =>
      (await SharedPreferences.getInstance()).getBool(_kAuto) ?? true;

  static Future<void> setAuto(bool v) async {
    await (await SharedPreferences.getInstance()).setBool(_kAuto, v);
    changed.value++;
  }

  /// Called at launch: back up if auto is on and the last one is >20 h old.
  static Future<void> autoBackupIfDue() async {
    try {
      if (!await autoEnabled()) return;
      final last = await lastBackup();
      if (last != null && DateTime.now().difference(last) < const Duration(hours: 20)) {
        return;
      }
      await backupNow();
    } catch (e) {
      debugPrint('[backup] auto: $e');
    }
  }

  /// Returns where the backup ended up (a path or a "Downloads/BYTE/…" label).
  static Future<String> backupNow({void Function(String)? onStatus}) async {
    final name = 'byte-backup-${_stamp(DateTime.now())}.zip';
    final tmp = await buildZip(name, onStatus: onStatus);
    final size = await tmp.length();
    var keep = tmp;
    try {
      String where;
      if (Platform.isAndroid) {
        onStatus?.call('Saving to Downloads/BYTE…');
        where = await _files.invokeMethod<String>('saveToDownloads', {
              'path': tmp.path,
              'name': name,
              'mime': 'application/zip',
            }) ??
            'Downloads/BYTE/$name';
      } else {
        final docs = await _desktopBackupDir();
        final dst = File(p.join(docs.path, name));
        await tmp.rename(dst.path);
        keep = dst;
        where = dst.path;
      }

      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kLast, DateTime.now().millisecondsSinceEpoch);
      await prefs.setString(_kLastName, where);
      changed.value++;
      debugPrint('[backup] saved $where (${(size / 1024).round()} KB)');

      // Off-device copy, if a cloud URL is set up.
      final cloud = await cloudUrl();
      if (cloud != null && cloud.isNotEmpty) {
        onStatus?.call('Uploading to cloud…');
        try {
          await uploadToCloud(cloud, name, await keep.readAsBytes());
          await prefs.setInt(_kCloudAt, DateTime.now().millisecondsSinceEpoch);
          await prefs.remove(_kCloudErr);
        } catch (e) {
          await prefs.setString(_kCloudErr, '$e');
          debugPrint('[backup] cloud: $e');
        }
        changed.value++;
      }
      return where;
    } finally {
      if (Platform.isAndroid) {
        try {
          await tmp.delete();
        } catch (_) {}
      }
    }
  }

  /// Builds the backup ZIP in the cache folder. Streams file by file
  /// (photos/videos can be big), so memory stays small.
  static Future<File> buildZip(String name, {void Function(String)? onStatus}) async {
    final db = AppDb.instance;
    onStatus?.call('Packing vault…');

    // Make sure everything is on disk, then copy the (encrypted) file.
    try {
      await db.db.rawQuery('PRAGMA wal_checkpoint(TRUNCATE)');
    } catch (_) {}
    final vaultPath = db.path!;
    final vaultBytes = await File(vaultPath).readAsBytes();

    final support = await getApplicationSupportDirectory();
    final cache = await getTemporaryDirectory();
    final tmp = File(p.join(cache.path, name));
    final enc = ZipFileEncoder();
    enc.create(tmp.path);
    enc.addArchiveFile(ArchiveFile.bytes(AppDb.vaultName, vaultBytes));

    var n = 0;
    var files = 0;
    // A private file goes into a backup only in its locked form.
    final held = await PrivateSpace.uploadGuard();
    for (final dirName in ['audio', 'files', 'thumbs']) {
      final dir = Directory(p.join(support.path, dirName));
      if (!await dir.exists()) continue;
      await for (final f in dir.list()) {
        if (f is! File) continue;
        if (held('$dirName/${p.basename(f.path)}')) continue;
        if (dirName == 'audio') {
          n++;
          onStatus?.call('Packing recording $n…');
        } else {
          files++;
          onStatus?.call('Packing file $files…');
        }
        // archive 3.x returns void here, 4.x a Future: go dynamic so both build.
        await (enc as dynamic).addFile(f, '$dirName/${p.basename(f.path)}');
      }
    }
    enc.addArchiveFile(ArchiveFile.string(
      'manifest.json',
      jsonEncode({
        'app': 'BYTE',
        'format': 2,
        'created': DateTime.now().toIso8601String(),
        'platform': Platform.operatingSystem,
        'recordings': n,
        'files': files,
        'note': 'The vault is AES-encrypted; restoring needs the recovery key.',
      }),
    ));
    onStatus?.call('Compressing…');
    await (enc as dynamic).close();
    return tmp;
  }

  // ───────────── off-device copies ─────────────

  /// Opens the share sheet with a fresh backup (Gmail to yourself, Drive,
  /// WhatsApp, laptop…). The ZIP lives in the cache until the cleaner drops it.
  static Future<void> shareLatest() async {
    final f = await buildZip('byte-backup-${_stamp(DateTime.now())}.zip');
    await SharePlus.instance.share(
      ShareParams(files: [XFile(f.path, mimeType: 'application/zip')], text: 'BYTE backup'),
    );
  }

  static Future<String?> cloudUrl() => _secure.read(key: _kCloudUrl);

  static Future<void> setCloudUrl(String? url) async {
    if (url == null || url.trim().isEmpty) {
      await _secure.delete(key: _kCloudUrl);
    } else {
      await _secure.write(key: _kCloudUrl, value: url.trim());
    }
    changed.value++;
  }

  static Future<DateTime?> lastCloudAt() async {
    final ms = (await SharedPreferences.getInstance()).getInt(_kCloudAt);
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  static Future<String?> lastCloudError() async =>
      (await SharedPreferences.getInstance()).getString(_kCloudErr);

  /// PUTs the ZIP next to the URL's path. Works with an Azure Blob container
  /// SAS URL (needs Write + Create), an S3/GCS pre-signed PUT URL, or any
  /// WebDAV-style endpoint that accepts PUT.
  static Future<void> uploadToCloud(String cloud, String name, List<int> bytes) async {
    final u = Uri.parse(cloud);
    final isAzure = u.host.toLowerCase().contains('blob.core.windows.net');
    // Insert the file name before the query (SAS / signature) part.
    final path = u.path.endsWith('/') ? '${u.path}$name' : '${u.path}/$name';
    final target = u.replace(path: path);
    final res = await http
        .put(
          target,
          headers: {
            'Content-Type': 'application/zip',
            if (isAzure) 'x-ms-blob-type': 'BlockBlob',
            if (isAzure) 'x-ms-version': '2020-10-02',
          },
          body: bytes,
        )
        .timeout(const Duration(minutes: 5));
    if (res.statusCode < 200 || res.statusCode >= 300) {
      final body = res.body.length > 200 ? res.body.substring(0, 200) : res.body;
      throw Exception('HTTP ${res.statusCode} $body');
    }
  }

  /// Uploads a tiny probe so the user knows the URL works.
  static Future<void> testCloud(String cloud) async {
    await uploadToCloud(cloud, 'byte-test.txt', 'BYTE can write here. ${DateTime.now()}'.codeUnits);
  }

  /// Android: lets the user pick a ZIP; returns a readable local copy.
  static Future<File?> pickBackupFile() async {
    final path = await _files.invokeMethod<String>('pickFile', {'mime': 'application/zip'});
    if (path == null) return null;
    return File(path);
  }

  /// Replace the vault + recordings with the ZIP's content.
  /// [recoveryKey] is only needed when the backup came from another device.
  /// Throws [RestoreNeedsKey] if the vault can't be opened with the current key.
  static Future<RestoreResult> restore(
    File zip, {
    String? recoveryKey,
    void Function(String)? onStatus,
  }) async {
    onStatus?.call('Reading backup…');
    final archive = ZipDecoder().decodeStream(InputFileStream(zip.path));
    ArchiveFile? vault;
    final audio = <ArchiveFile>[];
    final media = <ArchiveFile>[]; // files/… and thumbs/…
    for (final f in archive) {
      if (!f.isFile) continue;
      if (f.name == AppDb.vaultName) {
        vault = f;
      } else if (f.name.startsWith('audio/')) {
        audio.add(f);
      } else if (f.name.startsWith('files/') || f.name.startsWith('thumbs/')) {
        media.add(f);
      }
    }
    if (vault == null) {
      throw const FormatException('Not a BYTE backup (no vault inside).');
    }

    final support = await getApplicationSupportDirectory();
    final vaultPath = p.join(support.path, AppDb.vaultName);
    final keep = File('$vaultPath.pre-restore');

    onStatus?.call('Closing vault…');
    final vaultBytes = _bytes(vault); // unpacked before anything is touched
    // If the restored vault will not open, the old one needs its own key back.
    final oldKey = await VaultKey.get();
    await Gallery.beforeRestore();
    var swapped = true;
    var oldVaultSafe = true; // false while .pre-restore is the only good copy
    await AppDb.instance.close();
    try {
      var replaced = false;
      onStatus?.call('Opening restored vault…');
      try {
        final current = File(vaultPath);
        if (await current.exists()) await current.copy(keep.path);
        replaced = true;
        await File(vaultPath).writeAsBytes(vaultBytes, flush: true);
        if (recoveryKey != null) await VaultKey.set(recoveryKey);
        await AppDb.instance.open();
        await AppDb.instance.db.rawQuery('SELECT COUNT(*) FROM items');
      } catch (e) {
        // Wrong key, corrupt, or no room. Put the old vault back and tell the caller.
        oldVaultSafe = false;
        await AppDb.instance.close();
        if (replaced && await keep.exists()) await keep.copy(vaultPath);
        await VaultKey.set(oldKey);
        await AppDb.instance.open();
        oldVaultSafe = true;
        await Gallery.restoreAborted();
        swapped = false;
        if (e is FileSystemException) rethrow;
        throw RestoreNeedsKey('$e');
      }

      onStatus?.call('Restoring recordings…');
      final audioDir = Directory(p.join(support.path, 'audio'));
      await audioDir.create(recursive: true);
      var n = 0;
      for (final f in audio) {
        final dst = File(p.join(audioDir.path, p.basename(f.name)));
        await dst.writeAsBytes(_bytes(f), flush: true);
        n++;
      }
      // Recording rows store absolute paths from the old device → repoint.
      final rows = await AppDb.instance.db.query('audio', columns: ['item_id', 'path']);
      for (final r in rows) {
        final old = r['path'] as String;
        final base = old.split(RegExp(r'[\\/]')).last;
        final fresh = p.join(audioDir.path, base);
        if (fresh != old) {
          await AppDb.instance.db.update(
            'audio',
            {'path': fresh},
            where: 'item_id = ?',
            whereArgs: [r['item_id']],
          );
        }
      }

      // Library files + thumbnails (format 2 backups).
      var m = 0;
      for (final f in media) {
        final dirName = f.name.startsWith('files/') ? 'files' : 'thumbs';
        final dir = Directory(p.join(support.path, dirName));
        await dir.create(recursive: true);
        onStatus?.call('Restoring file ${++m}…');
        await File(p.join(dir.path, p.basename(f.name))).writeAsBytes(_bytes(f), flush: true);
      }
      for (final r in await AppDb.instance.db.query('files', columns: ['item_id', 'path', 'thumb', 'media_key'])) {
        final upd = <String, Object?>{};
        final old = r['path'] as String? ?? '';
        // A photo that lives in the phone's gallery keeps its own place — only
        // BYTE's own files came with the backup.
        final inGallery = (r['media_key'] as String? ?? '').isNotEmpty;
        if (old.isNotEmpty && !inGallery) {
          final fresh = p.join(support.path, 'files', old.split(RegExp(r'[\\/]')).last);
          if (fresh != old) upd['path'] = fresh;
        }
        final oldThumb = r['thumb'] as String? ?? '';
        if (oldThumb.isNotEmpty) {
          final fresh = p.join(support.path, 'thumbs', oldThumb.split(RegExp(r'[\\/]')).last);
          if (fresh != oldThumb) upd['thumb'] = fresh;
        }
        if (upd.isNotEmpty) await AppDb.instance.db.update('files', upd, where: 'item_id = ?', whereArgs: [r['item_id']]);
      }
      final items = (await AppDb.instance.db.rawQuery('SELECT COUNT(*) AS n FROM items')).first['n'] as int;
      changed.value++;
      return RestoreResult(items: items, recordings: n);
    } finally {
      try {
        if (oldVaultSafe && await keep.exists()) await keep.delete();
      } catch (_) {}
      if (swapped) {
        // The private space of the restored vault opens with ITS PIN.
        PrivateSpace.lock();
        // Its private key may not be the one in Drive: locked files wait
        // for the next upload of the vault.
        try {
          await CloudSync.setPrivateKeyInDrive(false);
        } catch (_) {}
        // Gallery numbers belong to one phone: check them all again — also
        // when the restore stopped half-way with the other vault in place.
        try {
          await Gallery.afterRestore();
        } catch (e) {
          debugPrint('[backup] after restore: $e');
        }
      }
    }
  }

  static Uint8List _bytes(ArchiveFile f) => f.content;

  static Future<Directory> _desktopBackupDir() async {
    Directory base;
    try {
      base = (await getDownloadsDirectory()) ?? await getApplicationDocumentsDirectory();
    } catch (_) {
      base = await getApplicationDocumentsDirectory();
    }
    final dir = Directory(p.join(base.path, 'BYTE backups'));
    await dir.create(recursive: true);
    return dir;
  }

  static String _stamp(DateTime t) =>
      '${t.year}${_two(t.month)}${_two(t.day)}-${_two(t.hour)}${_two(t.minute)}';
  static String _two(int n) => n.toString().padLeft(2, '0');
}

class RestoreResult {
  const RestoreResult({required this.items, required this.recordings});
  final int items;
  final int recordings;
}

class RestoreNeedsKey implements Exception {
  const RestoreNeedsKey(this.detail);
  final String detail;
  @override
  String toString() => 'This backup needs its recovery key ($detail)';
}
