import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart' show ConflictAlgorithm;

import 'db.dart';
import 'gallery.dart';
import 'private_space.dart';
import 'vault_key.dart';

/// "Nothing is ever lost": a copy of the whole vault in the user's own
/// Google Drive — every recording, photo, video, file, the encrypted database
/// and (by default) the recovery key. Runs by itself (daily, Wi-Fi) and on
/// demand; a new phone gets everything back with "Restore from Drive".
///
/// Only files BYTE itself created are touched (scope `drive.file`), inside a
/// visible folder "BYTE Vault" so the user can see it in Drive.
class CloudSync {
  CloudSync._();

  static const scopes = ['https://www.googleapis.com/auth/drive.file'];
  static const folderName = 'BYTE Vault';
  static const kWebClientId = 'cloud_web_client_id';
  static const kAuto = 'cloud_auto';
  static const kWifiOnly = 'cloud_wifi_only';
  static const kStoreKey = 'cloud_store_key';
  static const kLastSync = 'cloud_last_sync';
  static const kLastError = 'cloud_last_error';
  static const kEmail = 'cloud_email';
  static const kFolderId = 'cloud_folder_id';
  static const kSubIds = 'cloud_sub_ids';
  static const chunk = 8 * 1024 * 1024;
  static const _ch = MethodChannel('byte/cloud');

  static final ValueNotifier<String> status = ValueNotifier<String>('');
  static final ValueNotifier<int> changed = ValueNotifier<int>(0);
  static bool _inited = false;
  static bool _busy = false;
  static bool get busy => _busy;
  static bool _restoring = false;

  /// A restore is swapping the vault: nothing else may touch media rows.
  static bool get restoring => _restoring;

  // ───────────── settings ─────────────

  static Future<SharedPreferences> get _p => SharedPreferences.getInstance();
  /// The Web OAuth client of the "BYTE" Google Cloud project (byte-514003).
  /// A client id is a public identifier, not a secret; it is here so the
  /// phone only has to tap "Sign in". Settings can still override it.
  static const defaultWebClientId = '127165633149-82ateou3idk8ac0rm6ksf9vlnitklo94.apps.googleusercontent.com';

  static Future<String> webClientId() async {
    final v = ((await _p).getString(kWebClientId) ?? '').trim();
    return v.isEmpty ? defaultWebClientId : v;
  }
  static Future<void> setWebClientId(String v) async {
    await (await _p).setString(kWebClientId, v.trim());
    _inited = false; // re-initialize with the new id
    changed.value++;
  }

  static Future<bool> autoEnabled() async => (await _p).getBool(kAuto) ?? true;
  static Future<void> setAuto(bool v) async {
    await (await _p).setBool(kAuto, v);
    changed.value++;
  }

  static Future<bool> wifiOnly() async => (await _p).getBool(kWifiOnly) ?? true;
  static Future<void> setWifiOnly(bool v) async {
    await (await _p).setBool(kWifiOnly, v);
    changed.value++;
  }

  static Future<bool> storeKey() async => (await _p).getBool(kStoreKey) ?? true;
  static Future<void> setStoreKey(bool v) async {
    await (await _p).setBool(kStoreKey, v);
    changed.value++;
  }

  static Future<DateTime?> lastSync() async {
    final ms = (await _p).getInt(kLastSync);
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  static Future<String> lastError() async => (await _p).getString(kLastError) ?? '';
  static Future<String> email() async => (await _p).getString(kEmail) ?? '';

  /// Is Wi-Fi (an unmetered network) available right now? Android only.
  static Future<bool> onWifi() async {
    if (!Platform.isAndroid) return true;
    try {
      return await _ch.invokeMethod<bool>('isUnmetered') ?? false;
    } catch (_) {
      return false;
    }
  }

  // ───────────── sign in ─────────────

  static Future<void> _init() async {
    if (_inited) return;
    final id = await webClientId();
    await GoogleSignIn.instance.initialize(serverClientId: id.isEmpty ? null : id);
    _inited = true;
  }

  /// Interactive sign-in + Drive permission. Returns the email.
  static Future<String> signIn() async {
    await _init();
    final user = await GoogleSignIn.instance.authenticate(scopeHint: scopes);
    final auth = await user.authorizationClient.authorizeScopes(scopes);
    _user = user;
    _cachedToken = auth.accessToken;
    _tokenAt = DateTime.now();
    await (await _p).setString(kEmail, user.email);
    await (await _p).remove(kLastError);
    changed.value++;
    return user.email;
  }

  static Future<void> signOut() async {
    await _init();
    try {
      await GoogleSignIn.instance.signOut();
    } catch (_) {}
    forgetToken();
    final p0 = await _p;
    await p0.remove(kEmail);
    await p0.remove(kFolderId);
    await p0.remove(kSubIds);
    changed.value++;
  }

  /// A token without any UI (null when the user must sign in again).
  // Google's "lightweight" check shows a "Signing you in" sheet on Android,
  // so it runs once per app session; after that the account object and a
  // short-lived token are reused silently.
  static GoogleSignInAccount? _user;
  static String? _cachedToken;
  static DateTime _tokenAt = DateTime.fromMillisecondsSinceEpoch(0);
  static Future<String?>? _inFlight;

  /// Forget the cached account/token (sign out, or a 401 from Drive).
  static void forgetToken() {
    _user = null;
    _cachedToken = null;
    _tokenAt = DateTime.fromMillisecondsSinceEpoch(0);
    _trashSub = null;
  }

  static Future<String?> _token() {
    // Many callers at once (uploads, thumbs, the pill) share one request.
    final f = _inFlight;
    if (f != null) return f;
    final run = _tokenInner().whenComplete(() => _inFlight = null);
    _inFlight = run;
    return run;
  }

  static Future<String?> _tokenInner() async {
    await _init();
    final t = _cachedToken;
    if (t != null && DateTime.now().difference(_tokenAt) < const Duration(minutes: 45)) return t;
    var user = _user;
    if (user == null) {
      try {
        final f = GoogleSignIn.instance.attemptLightweightAuthentication();
        user = f == null ? null : await f;
      } catch (e) {
        debugPrint('[cloud] lightweight auth: $e');
      }
      if (user == null) return null;
      _user = user;
    }
    try {
      final auth = await user.authorizationClient.authorizationForScopes(scopes);
      final token = auth?.accessToken;
      if (token != null) {
        _cachedToken = token;
        _tokenAt = DateTime.now();
      }
      return token;
    } catch (e) {
      debugPrint('[cloud] authorization: $e');
      _user = null; // next time, check the account again
      return null;
    }
  }

  // ───────────── media in Drive (R3a) ─────────────
  // Photos and videos live in "BYTE Vault/files" — the same folder the daily
  // backup uses, recorded in `cloud_files`, so nothing is uploaded twice.

  /// Signed in to Drive at all (no network call).
  static Future<bool> connected() async => (await email()).isNotEmpty;

  /// A Drive token without any screen, or null (sign in again / offline).
  static Future<String?> accessToken() => _token();

  /// Upload one Library file. Reuses the backup's copy when it is already
  /// there with the same size. Returns the Drive file id.
  /// [name]: the name the copy gets in Drive. Left out, it is the file's own
  /// name — right for BYTE's own files, whose names are unique. A photo from
  /// the phone's gallery is given a unique name by the caller, because two
  /// different gallery photos can both be called "IMG_0001.jpg".
  static Future<String> uploadMedia(File f, {String? name, void Function(int sent, int total)? onProgress}) async {
    final token = await _token();
    if (token == null) throw const CloudNeedsSignIn();
    final drive = _Drive(token);
    final prefs = await _p;
    final root = await _rootFolder(drive, prefs);
    if (root == null) throw const HttpException('Could not create the "BYTE Vault" folder in Drive.');
    final sub = await _subFolders(drive, prefs, root);
    final driveName = name ?? p.basename(f.path);
    final rel = 'files/$driveName';
    final st = await f.stat();
    final db = AppDb.instance.db;
    final known = await db.query('cloud_files', where: 'rel_path = ?', whereArgs: [rel], limit: 1);
    if (known.isNotEmpty && (known.first['size'] as num).toInt() == st.size) {
      final id = known.first['remote_id'] as String;
      // Trust Drive, not our notes: the copy there must really be this size.
      if (await drive.size(id) == st.size) {
        onProgress?.call(st.size, st.size);
        return id;
      }
    }
    final id = await drive.uploadFile(f, name: driveName, parentId: sub['files']!, onProgress: onProgress);
    await db.insert('cloud_files', {'rel_path': rel, 'remote_id': id, 'size': st.size, 'mtime': st.modified.millisecondsSinceEpoch, 'uploaded_at': DateTime.now().millisecondsSinceEpoch}, conflictAlgorithm: ConflictAlgorithm.replace);
    changed.value++;
    return id;
  }

  /// The size of this Drive file, or null when it is gone or in the Trash.
  /// Throws on anything else (offline, rate limit) — so a hiccup never reads
  /// as "not there".
  static Future<int?> mediaSize(String remoteId) async {
    final token = await _token();
    if (token == null) throw const CloudNeedsSignIn();
    return _Drive(token).size(remoteId);
  }

  static Future<void> downloadMedia(String remoteId, File dst, {void Function(int got, int total)? onProgress}) async {
    final token = await _token();
    if (token == null) throw const CloudNeedsSignIn();
    await _Drive(token).downloadTo(remoteId, dst, onProgress: onProgress);
    // The daily backup must see this copy as "already in Drive" — otherwise
    // the new mtime makes it upload the same file again over the Drive copy.
    try {
      final st = await dst.stat();
      await AppDb.instance.db.insert('cloud_files', {'rel_path': 'files/${p.basename(dst.path)}', 'remote_id': remoteId, 'size': st.size, 'mtime': st.modified.millisecondsSinceEpoch, 'uploaded_at': DateTime.now().millisecondsSinceEpoch}, conflictAlgorithm: ConflictAlgorithm.replace);
    } catch (e) {
      debugPrint('[cloud] note download: $e');
    }
  }

  /// Deleted in BYTE → Drive's Trash (recoverable there for 30 days).
  static Future<void> trashMedia(String remoteId) async {
    final token = await _token();
    if (token == null) throw const CloudNeedsSignIn();
    await _Drive(token).trash(remoteId);
    await AppDb.instance.db.delete('cloud_files', where: 'remote_id = ?', whereArgs: [remoteId]);
  }

  /// Direct link a video player can stream with the token header.
  static Uri mediaUrl(String remoteId) => Uri.parse('https://www.googleapis.com/drive/v3/files/$remoteId?alt=media');

  /// (used, limit) bytes of the user's Google storage; limit 0 = unlimited.
  static Future<(int, int)?> quota() async {
    final token = await _token();
    if (token == null) return null;
    try {
      return await _Drive(token).quota();
    } catch (e) {
      debugPrint('[cloud] quota: $e');
      return null;
    }
  }

  // ───────────── sync ─────────────

  /// True while "bring everything back" is under way on the welcome screen:
  /// the automatic backup waits, so this phone's empty vault never goes on
  /// top of the copy that is about to be brought back.
  static bool holdAuto = false;

  static Future<bool> isDue() async {
    if (holdAuto) return false;
    if (!await autoEnabled()) return false;
    if ((await email()).isEmpty) return false;
    final last = await lastSync();
    return last == null || DateTime.now().difference(last) > const Duration(hours: 20);
  }

  /// Called at launch / on resume: sync if it's time and the network allows.
  static Future<void> autoSyncIfDue() async {
    try {
      if (!await isDue()) return;
      if (await wifiOnly() && !await onWifi()) return;
      await syncNow();
    } catch (e) {
      debugPrint('[cloud] auto: $e');
    }
  }

  /// A sync now, if Drive is connected and the network rule allows it
  /// (the private space asks for one when its key is new).
  static Future<void> syncSoon() async {
    try {
      if (!await connected()) return;
      if (await wifiOnly() && !await onWifi()) return;
      await syncNow(background: true);
    } catch (e) {
      debugPrint('[cloud] sync soon: $e');
    }
  }

  /// True once a copy of the vault that holds the private space's (locked)
  /// key is in Drive. Until then locked private files are not sent there:
  /// in Drive they would be files nobody could ever open.
  static const kPrivateKeyUp = 'private_key_in_drive';
  static Future<bool> privateKeyInDrive() async => (await _p).getBool(kPrivateKeyUp) ?? false;
  static Future<void> setPrivateKeyInDrive(bool v) async {
    await (await _p).setBool(kPrivateKeyUp, v);
  }

  /// The Drive copy of a file BYTE has replaced (shrunk, renamed, locked) is
  /// of no use any more: it is put on the list for Drive's Trash, and BYTE
  /// forgets it. [rel] = "files/name.jpg".
  static Future<void> forgetFile(String rel) async {
    final db = AppDb.instance.db;
    for (final c in await db.query('cloud_files', columns: ['remote_id'], where: 'rel_path = ?', whereArgs: [rel])) {
      final rid = '${c['remote_id'] ?? ''}';
      if (rid.isNotEmpty) await db.rawInsert('INSERT OR IGNORE INTO private_trash (remote_id) VALUES (?)', [rid]);
    }
    await db.delete('cloud_files', where: 'rel_path = ?', whereArgs: [rel]);
  }

  // ───────────── sharing (Round 6) ─────────────

  /// The folder shared links live in, inside "BYTE Vault".
  static const sharedFolderName = 'Shared with others';

  static Future<_Drive> _driveOrThrow() async {
    final token = await _token();
    if (token == null) throw const CloudNeedsSignIn();
    return _Drive(token);
  }

  /// Makes an empty folder for one share and returns its Drive id.
  static Future<String> shareFolderCreate(String name) async {
    final drive = await _driveOrThrow();
    final root = await _rootFolder(drive, await _p);
    if (root == null) throw const HttpException('Could not create the "BYTE Vault" folder in Drive.');
    final parent = await drive.findFolder(sharedFolderName, parentId: root) ?? await drive.createFolder(sharedFolderName, parentId: root);
    return drive.createFolder(name, parentId: parent);
  }

  /// Puts a copy of a file that is already in Drive into a share's folder.
  /// Answers the copy's Drive id.
  static Future<String> shareCopyInto(String folderId, {required String remoteId, required String name}) async {
    final drive = await _driveOrThrow();
    return drive.copy(remoteId, name: name, parentId: folderId);
  }

  /// Uploads a file from the phone into a share's folder. Answers its Drive id.
  static Future<String> shareUploadInto(String folderId, File f, {required String name}) async {
    final drive = await _driveOrThrow();
    return drive.uploadFile(f, name: name, parentId: folderId);
  }

  /// A small picture of a file that anyone with its link may see — a photo
  /// in an album a friend shares with you. [width] in pixels.
  static String publicPicture(String fileId, {int width = 400}) => 'https://drive.google.com/thumbnail?id=$fileId&sz=w$width';

  /// Where such a file opens in a browser or the Drive app (a video).
  static String publicPage(String fileId) => 'https://drive.google.com/file/d/$fileId/view';

  /// The file itself, fetched the way a browser would — or null when it
  /// cannot be fetched just now (see [boxRead] for why it is done this way).
  static Future<List<int>?> publicBytes(String fileId) async {
    if (fileId.isEmpty) return null;
    for (final url in ['https://drive.google.com/uc?export=download&id=$fileId', 'https://drive.usercontent.google.com/download?id=$fileId&export=download']) {
      try {
        final r = await http.get(Uri.parse(url)).timeout(const Duration(minutes: 2));
        // (A page of Google's instead of the file is not the picture.)
        if (r.statusCode == 200 && !(r.headers['content-type'] ?? '').startsWith('text/html')) return r.bodyBytes;
      } catch (e) {
        debugPrint('[friends] fetch file: $e');
      }
    }
    return null;
  }

  /// Puts a piece of text (a note, a link) into a share's folder as a file.
  static Future<void> shareTextInto(String folderId, {required String name, required String text}) async {
    final drive = await _driveOrThrow();
    await drive.uploadBytes(utf8.encode(text), name: name, parentId: folderId, type: 'text/plain; charset=utf-8');
  }

  /// Opens the folder to "anyone with the link" and returns that link.
  static Future<String> shareOpen(String folderId, {required bool canAdd}) async {
    final drive = await _driveOrThrow();
    await drive.permitAnyone(folderId, role: canAdd ? 'writer' : 'reader');
    return 'https://drive.google.com/drive/folders/$folderId?usp=sharing';
  }

  /// Takes a share back: the link is closed, then the folder goes to
  /// Drive's Trash. (The Trash alone would leave the link open for 30 days.)
  static Future<void> shareStop(String folderId) async {
    final drive = await _driveOrThrow();
    await drive.unpermitAnyone(folderId);
    await drive.trash(folderId);
  }

  // ───────────── friends ─────────────

  /// The folder the "boxes" for friends live in, inside "BYTE Vault".
  static const friendsFolderName = 'Shared with friends';

  /// Writes this phone's "box" for one friend — a small file that says what
  /// is shared with them — and returns its Drive id. A new box is opened to
  /// "anyone with the link may read": the friend's BYTE reads it by its id.
  /// With [existingId] the same file is written again (its id never changes).
  static Future<String> boxWrite(String name, String json, {String existingId = ''}) async {
    final drive = await _driveOrThrow();
    final bytes = utf8.encode(json);
    if (existingId.isNotEmpty) return drive.uploadBytes(bytes, name: name, parentId: '', existingId: existingId, type: 'application/json');
    final root = await _rootFolder(drive, await _p);
    if (root == null) throw const HttpException('Could not create the "BYTE Vault" folder in Drive.');
    final parent = await drive.findFolder(friendsFolderName, parentId: root) ?? await drive.createFolder(friendsFolderName, parentId: root);
    final id = await drive.uploadBytes(bytes, name: name, parentId: parent, type: 'application/json');
    await drive.permitAnyone(id, role: 'reader');
    return id;
  }

  /// Reads a friend's box, or null when it cannot be read just now.
  ///
  /// It is fetched the way a browser opens a shared link, without signing in:
  /// BYTE's Drive access only reaches files in YOUR Drive, never a file in
  /// someone else's — even one that is shared with you.
  static Future<String?> boxRead(String fileId) async {
    if (fileId.isEmpty) return null;
    for (final url in ['https://drive.google.com/uc?export=download&id=$fileId', 'https://drive.usercontent.google.com/download?id=$fileId&export=download']) {
      try {
        final r = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 25));
        if (r.statusCode != 200) continue;
        final text = utf8.decode(r.bodyBytes, allowMalformed: true).trim();
        // (A page of Google's instead of the file — "sign in", "too many
        // downloads" — is not a box.)
        if (text.startsWith('{')) return text;
      } catch (e) {
        debugPrint('[friends] read box: $e');
      }
    }
    return null;
  }

  static Map<String, String>? _trashSub;
  static DateTime _trashSubAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// Sends every copy called [rel] ("files/name.jpg") in the BYTE Vault
  /// folder to Drive's Trash — also copies BYTE no longer has on its list.
  static Future<void> trashByName(String rel) async {
    final token = await _token();
    if (token == null) throw const CloudNeedsSignIn();
    final drive = _Drive(token);
    final cut = rel.indexOf('/');
    if (cut <= 0) return;
    // The folders are looked up once for a run of names, not for each name.
    var sub = _trashSub;
    if (sub == null || DateTime.now().difference(_trashSubAt) > const Duration(minutes: 5)) {
      final prefs = await _p;
      final root = await _rootFolder(drive, prefs, createIfMissing: false);
      if (root == null) return;
      sub = await _subFolders(drive, prefs, root, createIfMissing: false);
      _trashSub = sub;
      _trashSubAt = DateTime.now();
    }
    final folder = sub[rel.substring(0, cut)];
    if (folder == null) return;
    for (final f in await drive.list(folder, name: rel.substring(cut + 1))) {
      await drive.trash(f.id);
    }
    await AppDb.instance.db.delete('cloud_files', where: 'rel_path = ?', whereArgs: [rel]);
  }

  /// Uploads what changed. Safe to call again after a failure — it continues.
  static Future<SyncReport> syncNow({void Function(String)? onStatus, bool background = false}) async {
    if (_busy) return const SyncReport(uploaded: 0, skipped: 0, bytes: 0, error: 'Already syncing');
    _busy = true;
    void say(String s) {
      status.value = s;
      onStatus?.call(s);
    }

    final prefs = await _p;
    try {
      say('Signing in…');
      final token = await _token();
      if (token == null) throw const CloudNeedsSignIn();
      final drive = _Drive(token);
      say('Finding the BYTE Vault folder…');
      final root = await _rootFolder(drive, prefs);
      if (root == null) throw const HttpException('Could not create the "BYTE Vault" folder in Drive.');
      final sub = await _subFolders(drive, prefs, root);
      // Drive holds a BYTE copy that this phone has never written (a new
      // phone, signed in but nothing brought back yet): this phone's vault
      // must not go on top of it, and this phone's key must not replace the
      // key that opens it.
      final dbFolder = sub['db'];
      if (dbFolder != null) {
        final mine = await AppDb.instance.db.query('cloud_files', columns: ['remote_id'], where: 'rel_path = ?', whereArgs: ['db/${AppDb.vaultName}'], limit: 1);
        if (mine.isEmpty && await _namedId(drive, dbFolder, AppDb.vaultName) != null) throw const CloudHoldsAnotherCopy();
      }

      final db = AppDb.instance.db;
      final support = await getApplicationSupportDirectory();
      var uploaded = 0;
      var skipped = 0;
      var bytes = 0;

      // 1. Media: audio/, files/, thumbs/.
      // A private file leaves the phone only in its locked form. (If this
      // cannot be worked out, nothing is uploaded at all.)
      var held = await PrivateSpace.uploadGuard();
      // Does the vault that goes up in this run already hold the private key?
      final privateKeyInVault = await PrivateSpace.isSetUp();
      for (final dirName in ['audio', 'files', 'thumbs']) {
        final dir = Directory(p.join(support.path, dirName));
        if (!await dir.exists()) continue;
        await for (final f in dir.list()) {
          if (f is! File) continue;
          final rel = '$dirName/${p.basename(f.path)}';
          if (held(rel)) continue;
          final st = await f.stat();
          final known = await db.query('cloud_files', where: 'rel_path = ?', whereArgs: [rel], limit: 1);
          if (known.isNotEmpty && (known.first['size'] as num).toInt() == st.size && (known.first['mtime'] as num).toInt() == st.modified.millisecondsSinceEpoch) {
            skipped++;
            continue;
          }
          // Asked again right before it goes: it may have become private meanwhile.
          held = await PrivateSpace.uploadGuard();
          if (held(rel)) continue;
          say('Uploading ${p.basename(f.path)} (${_mb(st.size)})…');
          final existingId = known.isNotEmpty ? known.first['remote_id'] as String : null;
          final id = await drive.uploadFile(f, name: p.basename(f.path), parentId: sub[dirName]!, existingId: existingId, onProgress: (sent, total) => say('Uploading ${p.basename(f.path)} ${_mb(sent)} / ${_mb(total)}'));
          // …and once more now that it is up: made private during the upload → that copy goes.
          held = await PrivateSpace.uploadGuard();
          if (held(rel)) {
            await drive.trash(id);
            await db.delete('cloud_files', where: 'rel_path = ?', whereArgs: [rel]);
            continue;
          }
          await db.insert('cloud_files', {'rel_path': rel, 'remote_id': id, 'size': st.size, 'mtime': st.modified.millisecondsSinceEpoch, 'uploaded_at': DateTime.now().millisecondsSinceEpoch}, conflictAlgorithm: ConflictAlgorithm.replace);
          uploaded++;
          bytes += st.size;
        }
      }

      // 2. The vault itself (encrypted). Snapshot first so the upload is consistent.
      say('Packing the vault…');
      try {
        await db.rawQuery('PRAGMA wal_checkpoint(TRUNCATE)');
      } catch (_) {}
      final snap = File(p.join(support.path, 'cloud-snapshot.enc.db'));
      await File(AppDb.instance.path!).copy(snap.path);
      try {
        final st = await snap.stat();
        final known = await db.query('cloud_files', where: 'rel_path = ?', whereArgs: ['db/${AppDb.vaultName}'], limit: 1);
        say('Uploading the vault (${_mb(st.size)})…');
        final id = await drive.uploadFile(snap, name: AppDb.vaultName, parentId: sub['db']!, existingId: known.isNotEmpty ? known.first['remote_id'] as String : null);
        await db.insert('cloud_files', {'rel_path': 'db/${AppDb.vaultName}', 'remote_id': id, 'size': st.size, 'mtime': st.modified.millisecondsSinceEpoch, 'uploaded_at': DateTime.now().millisecondsSinceEpoch}, conflictAlgorithm: ConflictAlgorithm.replace);
        uploaded++;
        bytes += st.size;
        // The private space's key (in its locked form) is in Drive now: its files may follow.
        if (privateKeyInVault) await prefs.setBool(kPrivateKeyUp, true);
      } finally {
        try {
          await snap.delete();
        } catch (_) {}
      }

      // 3. Settings (rules, trackers' reminders are in the DB; prefs hold the rest) + manifest.
      say('Saving settings…');
      final prefsJson = <String, Object?>{};
      for (final k in prefs.getKeys()) {
        if (k.contains('key') || k.contains('_native_') || k == kFolderId || k == kSubIds) continue; // never secrets
        prefsJson[k] = prefs.get(k);
      }
      await drive.uploadBytes(utf8.encode(jsonEncode(prefsJson)), name: 'prefs.json', parentId: sub['db']!, existingId: await _namedId(drive, sub['db']!, 'prefs.json'));
      final manifest = <String, Object?>{
        'app': 'BYTE',
        'format': 2,
        'created': DateTime.now().toIso8601String(),
        'device': Platform.operatingSystem,
        if (await storeKey()) 'vaultKey': await VaultKey.get(),
        'note': 'Encrypted vault + media. Restore from BYTE → Settings → Cloud safety.',
      };
      await drive.uploadBytes(utf8.encode(jsonEncode(manifest)), name: 'manifest.json', parentId: root, existingId: await _namedId(drive, root, 'manifest.json'));

      await prefs.setInt(kLastSync, DateTime.now().millisecondsSinceEpoch);
      await prefs.remove(kLastError);
      say(uploaded == 0 ? 'Everything is already in Drive.' : 'Backed up $uploaded file${uploaded == 1 ? '' : 's'} (${_mb(bytes)}).');
      changed.value++;
      return SyncReport(uploaded: uploaded, skipped: skipped, bytes: bytes);
    } catch (e) {
      final msg = e is CloudNeedsSignIn ? 'Sign in to Google Drive first.' : '$e';
      await prefs.setString(kLastError, msg);
      say('Backup failed: $msg');
      changed.value++;
      return SyncReport(uploaded: 0, skipped: 0, bytes: 0, error: msg);
    } finally {
      _busy = false;
    }
  }

  // ───────────── restore ─────────────

  /// What's in Drive right now (for the Restore screen).
  static Future<CloudInventory> inventory() async {
    final token = await _token();
    if (token == null) throw const CloudNeedsSignIn();
    final drive = _Drive(token);
    final prefs = await _p;
    final root = await _rootFolder(drive, prefs, createIfMissing: false);
    if (root == null) return const CloudInventory(hasVault: false, files: 0, bytes: 0, manifest: null);
    final sub = await _subFolders(drive, prefs, root, createIfMissing: false);
    var n = 0;
    var bytes = 0;
    for (final d in ['audio', 'files', 'thumbs']) {
      final id = sub[d];
      if (id == null) continue;
      for (final f in await drive.list(id)) {
        n++;
        bytes += f.size;
      }
    }
    Map<String, Object?>? manifest;
    final mid = await _namedId(drive, root, 'manifest.json');
    if (mid != null) {
      try {
        manifest = jsonDecode(utf8.decode(await drive.downloadBytes(mid))) as Map<String, Object?>;
      } catch (_) {}
    }
    final dbId = sub['db'] == null ? null : await _namedId(drive, sub['db']!, AppDb.vaultName);
    return CloudInventory(hasVault: dbId != null, files: n, bytes: bytes, manifest: manifest, lastSaved: manifest == null ? null : DateTime.tryParse('${manifest['created']}'));
  }

  /// Pulls everything down and replaces the local vault. The old vault is
  /// kept as `.pre-restore` until the new one opens fine.
  static Future<RestoreReport> restore({void Function(String)? onStatus, String? recoveryKey}) async {
    if (_busy) throw StateError('Busy');
    _busy = true;
    _restoring = true;
    // True from the moment the vault file is replaced (also when the restore
    // then stops half-way): the vault in place may be another phone's.
    var swapped = false;
    void say(String s) {
      status.value = s;
      onStatus?.call(s);
    }

    try {
      say('Signing in…');
      final token = await _token();
      if (token == null) throw const CloudNeedsSignIn();
      final drive = _Drive(token);
      final prefs = await _p;
      final root = await _rootFolder(drive, prefs, createIfMissing: false);
      if (root == null) throw const FormatException('No "BYTE Vault" folder in this Google Drive.');
      final sub = await _subFolders(drive, prefs, root, createIfMissing: false);
      final dbFolder = sub['db'];
      final dbId = dbFolder == null ? null : await _namedId(drive, dbFolder, AppDb.vaultName);
      if (dbId == null) throw const FormatException('No vault file in Drive yet.');

      // Key: the one passed in, else the one stored in the manifest, else keep ours.
      var key = recoveryKey;
      if (key == null) {
        final mid = await _namedId(drive, root, 'manifest.json');
        if (mid != null) {
          try {
            final m = jsonDecode(utf8.decode(await drive.downloadBytes(mid))) as Map;
            final k = m['vaultKey'];
            if (k is String && k.isNotEmpty) key = k;
          } catch (_) {}
        }
      }

      // A key that cannot be right is refused before anything is touched.
      if (key != null && !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(key)) {
        throw const CloudNeedsKey('it must be 64 characters: 0-9 and a-f');
      }

      final support = await getApplicationSupportDirectory();
      say('Downloading the vault…');
      final tmp = File(p.join(support.path, 'cloud-restore.enc.db'));
      await drive.downloadTo(dbId, tmp, onProgress: (got, total) => say('Downloading the vault ${_mb(got)}${total > 0 ? ' / ${_mb(total)}' : ''}'));

      final vaultPath = p.join(support.path, AppDb.vaultName);
      final keep = File('$vaultPath.pre-restore');
      say('Swapping vaults…');
      // If the new vault will not open, the old one needs its own key back.
      final oldKey = await VaultKey.get();
      await Gallery.beforeRestore();
      swapped = true;
      await AppDb.instance.close();
      var replaced = false; // the vault file itself has been touched
      try {
        final current = File(vaultPath);
        if (await current.exists()) await current.copy(keep.path);
        for (final suffix in ['-wal', '-shm', '-journal']) {
          final f = File('$vaultPath$suffix');
          if (await f.exists()) await f.delete();
        }
        replaced = true;
        await tmp.rename(vaultPath);
        if (key != null) await VaultKey.set(key);
        await AppDb.instance.open();
        await AppDb.instance.db.rawQuery('SELECT COUNT(*) FROM items');
      } catch (e) {
        // Wrong key, a damaged file, no room: the old vault and its key go back.
        await AppDb.instance.close();
        if (replaced && await keep.exists()) await keep.copy(vaultPath);
        await VaultKey.set(oldKey);
        await AppDb.instance.open();
        try {
          if (await keep.exists()) await keep.delete(); // otherwise a whole vault copy stays behind
        } catch (_) {}
        await Gallery.restoreAborted();
        swapped = false;
        if (e is FileSystemException) rethrow;
        throw CloudNeedsKey('$e');
      }

      // Media. Photos and videos that live in Drive stay there — the new
      // phone streams them like the old one did.
      final driveOnly = <String>{};
      try {
        for (final r in await AppDb.instance.db.rawQuery("SELECT name FROM drive_media WHERE local = 0 AND remote_id != ''")) {
          driveOnly.add('${r['name']}');
        }
      } catch (_) {} // older vaults have no drive_media table
      try {
        // Drive copies of photos that live in the phone's gallery are not
        // pulled into BYTE either: the originals are in the gallery (and if
        // they are not on this phone, BYTE fetches a copy when you open one).
        for (final r in await AppDb.instance.db.rawQuery(
          "SELECT d.name FROM drive_media d JOIN files f ON f.item_id = d.item_id WHERE f.media_key != '' AND d.remote_id != ''",
        )) {
          driveOnly.add('${r['name']}');
        }
      } catch (_) {} // older vaults have no media_key column
      var n = 0;
      for (final d in ['audio', 'files', 'thumbs']) {
        final id = sub[d];
        if (id == null) continue;
        final dir = Directory(p.join(support.path, d));
        await dir.create(recursive: true);
        for (final f in await drive.list(id)) {
          if (d == 'files' && driveOnly.contains(f.name)) continue;
          final dst = File(p.join(dir.path, f.name));
          if (await dst.exists() && await dst.length() == f.size) continue;
          n++;
          say('Downloading ${f.name} ($n)…');
          await drive.downloadTo(f.id, dst);
          await AppDb.instance.db.insert('cloud_files', {'rel_path': '$d/${f.name}', 'remote_id': f.id, 'size': f.size, 'mtime': (await dst.stat()).modified.millisecondsSinceEpoch, 'uploaded_at': DateTime.now().millisecondsSinceEpoch}, conflictAlgorithm: ConflictAlgorithm.replace);
        }
      }

      // Rows store the old phone's absolute paths → point them here.
      say('Fixing paths…');
      final db = AppDb.instance.db;
      // The vault that was brought back is the one in Drive: the next backup
      // writes over that same file. (A vault that was backed up only once
      // does not know its own Drive id yet.)
      await db.rawInsert(
        'INSERT OR IGNORE INTO cloud_files (rel_path, remote_id, size, mtime, uploaded_at) VALUES (?, ?, 0, 0, ?)',
        ['db/${AppDb.vaultName}', dbId, DateTime.now().millisecondsSinceEpoch],
      );
      for (final r in await db.query('audio', columns: ['item_id', 'path'])) {
        final old = r['path'] as String? ?? '';
        if (old.isEmpty) continue;
        final fresh = p.join(support.path, 'audio', old.split(RegExp(r'[\\/]')).last);
        if (fresh != old) await db.update('audio', {'path': fresh}, where: 'item_id = ?', whereArgs: [r['item_id']]);
      }
      for (final r in await db.query('files', columns: ['item_id', 'path', 'thumb', 'media_key'])) {
        final old = r['path'] as String? ?? '';
        final oldThumb = r['thumb'] as String? ?? '';
        final upd = <String, Object?>{};
        // A photo that lives in the phone's gallery keeps its own place — only
        // BYTE's own files moved with the vault.
        final inGallery = (r['media_key'] as String? ?? '').isNotEmpty;
        if (old.isNotEmpty && !inGallery) {
          final fresh = p.join(support.path, 'files', old.split(RegExp(r'[\\/]')).last);
          if (fresh != old) upd['path'] = fresh;
        }
        if (oldThumb.isNotEmpty) {
          final fresh = p.join(support.path, 'thumbs', oldThumb.split(RegExp(r'[\\/]')).last);
          if (fresh != oldThumb) upd['thumb'] = fresh;
        }
        if (upd.isNotEmpty) await db.update('files', upd, where: 'item_id = ?', whereArgs: [r['item_id']]);
      }
      try {
        if (await keep.exists()) await keep.delete();
      } catch (_) {}
      final items = (await db.rawQuery('SELECT COUNT(*) AS n FROM items WHERE deleted_at IS NULL')).first['n'] as int;
      await prefs.setInt(kLastSync, DateTime.now().millisecondsSinceEpoch);
      say('Restored: $items items, $n files.');
      changed.value++;
      return RestoreReport(items: items, files: n);
    } finally {
      _busy = false;
      _restoring = false;
      if (swapped) {
        // The private space of the restored vault opens with ITS PIN.
        PrivateSpace.lock();
        // Gallery numbers belong to one phone: check them all again — also
        // when the restore stopped half-way with the other vault in place.
        try {
          await Gallery.afterRestore();
        } catch (e) {
          debugPrint('[cloud] after restore: $e');
        }
      }
    }
  }

  // ───────────── folders ─────────────

  static Future<String?> _rootFolder(_Drive drive, SharedPreferences prefs, {bool createIfMissing = true}) async {
    final cached = prefs.getString(kFolderId);
    if (cached != null && await drive.exists(cached)) return cached;
    var id = await drive.findFolder(folderName, parentId: 'root');
    if (id == null && createIfMissing) id = await drive.createFolder(folderName, parentId: 'root');
    if (id != null) await prefs.setString(kFolderId, id);
    return id;
  }

  static Future<Map<String, String>> _subFolders(_Drive drive, SharedPreferences prefs, String? root, {bool createIfMissing = true}) async {
    final out = <String, String>{};
    if (root == null) return out;
    final cached = prefs.getString(kSubIds);
    if (cached != null) {
      try {
        final m = jsonDecode(cached) as Map;
        var ok = true;
        for (final e in m.entries) {
          if (!await drive.exists('${e.value}')) {
            ok = false;
            break;
          }
          out['${e.key}'] = '${e.value}';
        }
        if (ok && out.length == 4) return out;
        out.clear();
      } catch (_) {}
    }
    for (final name in ['audio', 'files', 'thumbs', 'db']) {
      var id = await drive.findFolder(name, parentId: root);
      if (id == null && createIfMissing) id = await drive.createFolder(name, parentId: root);
      if (id != null) out[name] = id;
    }
    if (out.length == 4) await prefs.setString(kSubIds, jsonEncode(out));
    return out;
  }

  static Future<String?> _namedId(_Drive drive, String parent, String name) async {
    final list = await drive.list(parent, name: name);
    return list.isEmpty ? null : list.first.id;
  }

  static String _mb(int b) => b >= 1024 * 1024 ? '${(b / (1024 * 1024)).toStringAsFixed(1)} MB' : '${(b / 1024).round()} KB';
}

class SyncReport {
  const SyncReport({required this.uploaded, required this.skipped, required this.bytes, this.error});
  final int uploaded;
  final int skipped;
  final int bytes;
  final String? error;
  bool get ok => error == null;
}

class RestoreReport {
  const RestoreReport({required this.items, required this.files});
  final int items;
  final int files;
}

class CloudInventory {
  const CloudInventory({required this.hasVault, required this.files, required this.bytes, required this.manifest, this.lastSaved});
  final bool hasVault;
  final int files;
  final int bytes;
  final Map<String, Object?>? manifest;
  final DateTime? lastSaved;
  bool get hasKey => manifest?['vaultKey'] is String;
}

class CloudNeedsSignIn implements Exception {
  const CloudNeedsSignIn();
  @override
  String toString() => 'Sign in to Google Drive first.';
}

/// Drive already holds a BYTE copy that this phone has not brought back: a
/// backup from this phone would go on top of it.
class CloudHoldsAnotherCopy implements Exception {
  const CloudHoldsAnotherCopy();
  @override
  String toString() =>
      'Google Drive already holds a BYTE copy from another phone. Bring it back first (Settings, Google Drive, Restore) — backing up from this phone now would go on top of it. To start fresh instead, remove the "BYTE Vault" folder in Google Drive.';
}

class CloudNeedsKey implements Exception {
  const CloudNeedsKey(this.detail);
  final String detail;
  @override
  String toString() => 'The vault in Drive needs its recovery key ($detail)';
}

class _RemoteFile {
  const _RemoteFile({required this.id, required this.name, required this.size});
  final String id;
  final String name;
  final int size;
}

/// The handful of Google Drive REST calls BYTE needs (plain HTTP, no SDK).
class _Drive {
  _Drive(this.token);
  final String token;
  final _client = http.Client();
  static const _api = 'https://www.googleapis.com/drive/v3';
  static const _upload = 'https://www.googleapis.com/upload/drive/v3';

  Map<String, String> get _auth => {'Authorization': 'Bearer $token'};

  Future<bool> exists(String id) async {
    final r = await _client.get(Uri.parse('$_api/files/$id?fields=id,trashed'), headers: _auth).timeout(const Duration(seconds: 20));
    if (r.statusCode != 200) return false;
    final j = jsonDecode(r.body) as Map;
    return j['trashed'] != true;
  }

  /// Size in bytes, or null when the file is gone (404) or trashed.
  Future<int?> size(String id) async {
    final r = await _client.get(Uri.parse('$_api/files/$id?fields=id,size,trashed'), headers: _auth).timeout(const Duration(seconds: 20));
    if (r.statusCode == 404) return null;
    _check(r);
    final j = jsonDecode(r.body) as Map;
    if (j['trashed'] == true) return null;
    return int.tryParse('${j['size'] ?? ''}');
  }

  Future<String?> findFolder(String name, {required String parentId}) async {
    final q = "name = '${_esc(name)}' and mimeType = 'application/vnd.google-apps.folder' and '${_esc(parentId)}' in parents and trashed = false";
    final r = await _client.get(Uri.parse('$_api/files?q=${Uri.encodeQueryComponent(q)}&fields=files(id,name)&pageSize=5'), headers: _auth).timeout(const Duration(seconds: 20));
    _check(r);
    final files = (jsonDecode(r.body) as Map)['files'] as List? ?? const [];
    return files.isEmpty ? null : '${(files.first as Map)['id']}';
  }

  Future<String> createFolder(String name, {required String parentId}) async {
    final r = await _client
        .post(Uri.parse('$_api/files?fields=id'), headers: {..._auth, 'Content-Type': 'application/json'}, body: jsonEncode({'name': name, 'mimeType': 'application/vnd.google-apps.folder', 'parents': [parentId]}))
        .timeout(const Duration(seconds: 20));
    _check(r);
    return '${(jsonDecode(r.body) as Map)['id']}';
  }

  Future<List<_RemoteFile>> list(String parentId, {String? name}) async {
    final out = <_RemoteFile>[];
    String? page;
    do {
      final q = "'${_esc(parentId)}' in parents and trashed = false${name == null ? '' : " and name = '${_esc(name)}'"}";
      final r = await _client
          .get(Uri.parse('$_api/files?q=${Uri.encodeQueryComponent(q)}&fields=nextPageToken,files(id,name,size)&pageSize=1000${page == null ? '' : '&pageToken=$page'}'), headers: _auth)
          .timeout(const Duration(seconds: 30));
      _check(r);
      final j = jsonDecode(r.body) as Map;
      for (final f in (j['files'] as List? ?? const []).whereType<Map>()) {
        out.add(_RemoteFile(id: '${f['id']}', name: '${f['name']}', size: int.tryParse('${f['size'] ?? 0}') ?? 0));
      }
      page = j['nextPageToken'] as String?;
    } while (page != null);
    return out;
  }

  Future<String> uploadBytes(List<int> bytes, {required String name, required String parentId, String? existingId, String type = 'application/octet-stream'}) async {
    final meta = jsonEncode(existingId == null ? {'name': name, 'parents': [parentId]} : {'name': name});
    final uri = Uri.parse(existingId == null ? '$_upload/files?uploadType=multipart&fields=id' : '$_upload/files/$existingId?uploadType=multipart&fields=id');
    const boundary = 'byte_boundary_7f3a';
    final body = <int>[
      ...utf8.encode('--$boundary\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n$meta\r\n--$boundary\r\nContent-Type: $type\r\n\r\n'),
      ...bytes,
      ...utf8.encode('\r\n--$boundary--'),
    ];
    final req = http.Request(existingId == null ? 'POST' : 'PATCH', uri)
      ..headers.addAll({..._auth, 'Content-Type': 'multipart/related; boundary=$boundary'})
      ..bodyBytes = body;
    final r = await http.Response.fromStream(await _client.send(req).timeout(const Duration(seconds: 60)));
    _check(r);
    return '${(jsonDecode(r.body) as Map)['id']}';
  }

  /// Resumable upload in 8 MB chunks (videos can be hundreds of MB).
  Future<String> uploadFile(File f, {required String name, required String parentId, String? existingId, void Function(int sent, int total)? onProgress}) async {
    final total = await f.length();
    final meta = jsonEncode(existingId == null ? {'name': name, 'parents': [parentId]} : {'name': name});
    final start = await _client
        .send(http.Request(existingId == null ? 'POST' : 'PATCH', Uri.parse(existingId == null ? '$_upload/files?uploadType=resumable&fields=id' : '$_upload/files/$existingId?uploadType=resumable&fields=id'))
          ..headers.addAll({..._auth, 'Content-Type': 'application/json; charset=UTF-8', 'X-Upload-Content-Length': '$total'})
          ..body = meta)
        .timeout(const Duration(seconds: 30));
    if (start.statusCode != 200) throw HttpException('Drive upload start: HTTP ${start.statusCode} ${await start.stream.bytesToString()}');
    final session = start.headers['location'];
    if (session == null) throw const HttpException('Drive upload: no session URL');

    final raf = await f.open();
    try {
      var sent = 0;
      if (total == 0) {
        final r = await _client.put(Uri.parse(session), headers: {'Content-Length': '0', 'Content-Range': 'bytes */0'}).timeout(const Duration(seconds: 30));
        _check(r);
        return '${(jsonDecode(r.body) as Map)['id']}';
      }
      while (sent < total) {
        final n = (total - sent) < CloudSync.chunk ? (total - sent) : CloudSync.chunk;
        await raf.setPosition(sent);
        final bytes = await raf.read(n);
        final end = sent + bytes.length - 1;
        final r = await _putChunk(session, bytes, 'bytes $sent-$end/$total');
        if (r.statusCode == 308) {
          // Google tells us how much it has; continue from there.
          final range = r.headers['range'];
          sent = range == null ? end + 1 : int.parse(range.split('-').last) + 1;
          onProgress?.call(sent, total);
          continue;
        }
        if (r.statusCode == 200 || r.statusCode == 201) {
          onProgress?.call(total, total);
          return '${(jsonDecode(r.body) as Map)['id']}';
        }
        throw HttpException('Drive upload: HTTP ${r.statusCode} ${r.body.length > 200 ? r.body.substring(0, 200) : r.body}');
      }
      throw const HttpException('Drive upload ended without a file id');
    } finally {
      await raf.close();
    }
  }

  Future<http.Response> _putChunk(String session, List<int> bytes, String range) async {
    Object? last;
    for (var attempt = 1; attempt <= 3; attempt++) {
      try {
        return await _client.put(Uri.parse(session), headers: {'Content-Length': '${bytes.length}', 'Content-Range': range}, body: bytes).timeout(const Duration(minutes: 3));
      } catch (e) {
        last = e;
        await Future<void>.delayed(Duration(seconds: 2 * attempt));
      }
    }
    throw HttpException('Drive upload chunk failed: $last');
  }

  /// A copy of one of BYTE's own Drive files inside [parentId] (made by
  /// Drive itself: nothing is uploaded again). Returns the copy's id.
  Future<String> copy(String id, {required String name, required String parentId}) async {
    final r = await _client
        .post(Uri.parse('$_api/files/$id/copy?fields=id'), headers: {..._auth, 'Content-Type': 'application/json'}, body: jsonEncode({'name': name, 'parents': [parentId]}))
        .timeout(const Duration(seconds: 60));
    _check(r);
    return '${(jsonDecode(r.body) as Map)['id']}';
  }

  /// "Anyone with the link" may view ([role] 'reader') or also add ('writer').
  Future<void> permitAnyone(String id, {required String role}) async {
    final r = await _client
        .post(Uri.parse('$_api/files/$id/permissions?fields=id'), headers: {..._auth, 'Content-Type': 'application/json'}, body: jsonEncode({'role': role, 'type': 'anyone'}))
        .timeout(const Duration(seconds: 20));
    _check(r);
  }

  /// Takes "anyone with the link" away again.
  Future<void> unpermitAnyone(String id) async {
    final r = await _client.get(Uri.parse('$_api/files/$id/permissions?fields=permissions(id,type)'), headers: _auth).timeout(const Duration(seconds: 20));
    if (r.statusCode == 404) return; // the folder is gone already
    _check(r);
    for (final perm in ((jsonDecode(r.body) as Map)['permissions'] as List? ?? const []).whereType<Map>()) {
      if (perm['type'] != 'anyone') continue;
      final d = await _client.delete(Uri.parse('$_api/files/$id/permissions/${perm['id']}'), headers: _auth).timeout(const Duration(seconds: 20));
      if (d.statusCode != 404) _check(d);
    }
  }

  Future<void> trash(String id) async {
    final r = await _client
        .patch(Uri.parse('$_api/files/$id?fields=id'), headers: {..._auth, 'Content-Type': 'application/json'}, body: jsonEncode({'trashed': true}))
        .timeout(const Duration(seconds: 20));
    if (r.statusCode == 404) return; // already gone
    _check(r);
  }

  Future<(int, int)> quota() async {
    final r = await _client.get(Uri.parse('$_api/about?fields=storageQuota'), headers: _auth).timeout(const Duration(seconds: 20));
    _check(r);
    final q = ((jsonDecode(r.body) as Map)['storageQuota'] as Map?) ?? const {};
    return (int.tryParse('${q['usage'] ?? 0}') ?? 0, int.tryParse('${q['limit'] ?? 0}') ?? 0);
  }

  Future<List<int>> downloadBytes(String id) async {
    final r = await _client.get(Uri.parse('$_api/files/$id?alt=media'), headers: _auth).timeout(const Duration(minutes: 2));
    _check(r);
    return r.bodyBytes;
  }

  Future<void> downloadTo(String id, File dst, {void Function(int got, int total)? onProgress}) async {
    final res = await _client.send(http.Request('GET', Uri.parse('$_api/files/$id?alt=media'))..headers.addAll(_auth)).timeout(const Duration(minutes: 2));
    if (res.statusCode != 200) throw HttpException('Drive download: HTTP ${res.statusCode}');
    final total = res.contentLength ?? 0;
    final tmp = File('${dst.path}.part');
    final sink = tmp.openWrite();
    var got = 0;
    try {
      await for (final chunk in res.stream) {
        sink.add(chunk);
        got += chunk.length;
        onProgress?.call(got, total);
      }
    } finally {
      await sink.close();
    }
    if (total > 0 && got != total) {
      // Cut short: never let half a file stand in for the real one.
      try {
        await tmp.delete();
      } catch (_) {}
      throw HttpException('Drive download cut short ($got of $total bytes)');
    }
    if (await dst.exists()) await dst.delete();
    await tmp.rename(dst.path);
  }

  void _check(http.Response r) {
    if (r.statusCode >= 200 && r.statusCode < 300) return;
    String msg;
    try {
      msg = '${((jsonDecode(r.body) as Map)['error'] as Map?)?['message'] ?? r.body}';
    } catch (_) {
      msg = r.body;
    }
    if (r.statusCode == 401) {
      CloudSync.forgetToken(); // the cached token died early; fetch a fresh one next time
      throw const CloudNeedsSignIn();
    }
    throw HttpException('Drive: HTTP ${r.statusCode} ${msg.length > 200 ? msg.substring(0, 200) : msg}');
  }

  static String _esc(String s) => s.replaceAll("'", "\\'");
}
