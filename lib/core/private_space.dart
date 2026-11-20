import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../features/capture/audio_repo.dart';
import '../features/library/collections_repo.dart';
import '../features/library/library_item.dart';
import '../features/library/library_repo.dart';
import '../features/notes/notes_repo.dart';
import 'activity.dart';
import 'bubble.dart';
import 'cloud_sync.dart';
import 'db.dart';
import 'drive_media.dart';
import 'gallery.dart';
import 'prefs.dart';
import 'private_names.dart';
import 'vault_key.dart';

/// What happened when a PIN was tried.
enum UnlockResult { ok, wrong, wait, broken }

/// What a "make private" / "move out" did, for the message afterwards.
class PrivateMove {
  const PrivateMove({this.moved = 0, this.failed = 0, this.galleryOriginals = const {}});
  final int moved;
  final int failed;

  /// Gallery number → file: photos that were copied in from the phone's
  /// gallery and whose originals are still there.
  final Map<String, String> galleryOriginals;
}

/// The private space: things shown only behind their own PIN.
///
/// How it keeps them private:
///  * A random 256-bit **private key** is made once. It is stored only in
///    locked form: once locked with a key made from the PIN, once with a key
///    made from the vault's recovery key (so a forgotten PIN can be reset).
///  * Opening the space = typing the PIN = unlocking that key. It lives in
///    memory until the space is locked again (leaving it, or leaving BYTE).
///  * Every file of a private item is **locked (encrypted) on the phone**
///    with that key, as soon as BYTE has finished reading it. From then on
///    every copy — Google Drive, backups — is the locked file.
///  * A private file that is not locked yet is never uploaded or backed up
///    ([uploadGuard]).
///  * Notes, names and the text BYTE read live in the vault, which is
///    encrypted as a whole already.
class PrivateSpace {
  PrivateSpace._();

  static const _ch = MethodChannel('byte/crypt');
  static const _sys = MethodChannel('byte/system');

  /// How hard the PIN is stretched (PBKDF2 rounds). Stored with the key, so
  /// it can be raised later without locking anyone out.
  static const rounds = 150000;

  static bool get supported => Platform.isAndroid;

  /// True while the space is open (the private key is in memory).
  static final ValueNotifier<bool> unlocked = ValueNotifier<bool>(false);

  /// Bumped when private items changed (moved in or out, locked).
  static final ValueNotifier<int> changed = ValueNotifier<int>(0);

  static Uint8List? _key;
  static int _holds = 0;
  static DateTime? _pausedAt;

  // ───────────── small stores ─────────────

  static Future<String> _read(String k) async {
    final rows = await AppDb.instance.db.query('private_space', where: 'k = ?', whereArgs: [k], limit: 1);
    return rows.isEmpty ? '' : '${rows.first['v'] ?? ''}';
  }

  static Future<void> _write(Map<String, String> kv) async {
    await AppDb.instance.db.transaction((txn) async {
      for (final e in kv.entries) {
        await txn.rawInsert('INSERT OR REPLACE INTO private_space (k, v) VALUES (?, ?)', [e.key, e.value]);
      }
    });
  }

  /// A PIN was chosen already (on this phone, or in the vault that was restored).
  static Future<bool> isSetUp() async {
    try {
      return (await _read('wrap_pin')).isNotEmpty;
    } catch (e) {
      debugPrint('[private] isSetUp: $e');
      return false;
    }
  }

  /// How many things are in the private space (works while locked: a count
  /// tells nothing about what they are).
  static Future<int> count() async {
    try {
      final rows = await AppDb.instance.db.rawQuery('SELECT COUNT(*) AS n FROM items WHERE private = 1 AND deleted_at IS NULL');
      return (rows.first['n'] as int?) ?? 0;
    } catch (_) {
      return 0;
    }
  }

  // ───────────── the locks (Android does the maths) ─────────────

  static Future<Uint8List> _random(int n) async => (await _ch.invokeMethod<Uint8List>('random', {'n': n}))!;

  static Future<Uint8List> _kdf(String secret, Uint8List salt, int rounds) async =>
      (await _ch.invokeMethod<Uint8List>('kdf', {'pin': secret, 'salt': salt, 'rounds': rounds}))!;

  static Future<Uint8List> _sealBytes(Uint8List key, Uint8List data) async => (await _ch.invokeMethod<Uint8List>('seal', {'key': key, 'data': data}))!;

  /// null = the key does not fit.
  static Future<Uint8List?> _openBytes(Uint8List key, Uint8List data) => _ch.invokeMethod<Uint8List>('open', {'key': key, 'data': data});

  /// The key that the recovery key gives (the recovery key is long and
  /// random already, so it needs no stretching).
  static Future<Uint8List> _recoveryKek(String recoveryHex) =>
      _kdf(recoveryHex.toLowerCase(), Uint8List.fromList(utf8.encode('BYTE private recovery')), 1);

  static Future<void> _storeLocked(Uint8List master, String pin) async {
    final salt = await _random(16);
    final byPin = await _sealBytes(await _kdf(pin, salt, rounds), master);
    final byRecovery = await _sealBytes(await _recoveryKek(await VaultKey.get()), master);
    await _write({
      'salt': base64Encode(salt),
      'rounds': '$rounds',
      'wrap_pin': base64Encode(byPin),
      'wrap_vault': base64Encode(byRecovery),
    });
    await Prefs.setNumber('private_fails', 0);
    await Prefs.setNumber('private_wait_until', 0);
  }

  // ───────────── PIN ─────────────

  /// First time: choose the PIN. Opens the space.
  static Future<void> setUp(String pin) async {
    if (!supported) throw StateError('The private space works on Android only.');
    if (!isValidPin(pin)) throw ArgumentError('A PIN is 4 to 12 digits.');
    if (await isSetUp()) throw StateError('The private space already has a PIN.');
    final master = await _random(32);
    await _storeLocked(master, pin);
    // The key to every locked file lives only in the vault. Until a copy of
    // the vault with it is in Drive, locked files are not sent there.
    await CloudSync.setPrivateKeyInDrive(false);
    _opened(master);
    unawaited(CloudSync.syncSoon());
  }

  /// Seconds still to wait after too many wrong PINs (0 = may try now).
  static int waitLeft() {
    final until = Prefs.number('private_wait_until');
    final left = until - DateTime.now().millisecondsSinceEpoch;
    if (left <= 0) return 0;
    if (left > 900 * 1000) {
      // The phone's clock was set back: the wait starts again from now, at
      // its longest — so it still counts down.
      unawaited(Prefs.setNumber('private_wait_until', DateTime.now().millisecondsSinceEpoch + 900 * 1000));
      return 900;
    }
    return (left / 1000).ceil();
  }

  static Future<UnlockResult> unlock(String pin) async {
    if (!supported) return UnlockResult.broken;
    if (waitLeft() > 0) return UnlockResult.wait;
    try {
      final wrap = await _read('wrap_pin');
      final salt = await _read('salt');
      if (wrap.isEmpty || salt.isEmpty) return UnlockResult.broken;
      final r = int.tryParse(await _read('rounds')) ?? rounds;
      final master = await _openBytes(await _kdf(pin, base64Decode(salt), r), base64Decode(wrap));
      if (master == null || master.length != 32) {
        final fails = Prefs.number('private_fails') + 1;
        await Prefs.setNumber('private_fails', fails);
        final wait = waitSecondsAfter(fails);
        if (wait > 0) await Prefs.setNumber('private_wait_until', DateTime.now().millisecondsSinceEpoch + wait * 1000);
        return UnlockResult.wrong;
      }
      await Prefs.setNumber('private_fails', 0);
      await Prefs.setNumber('private_wait_until', 0);
      _opened(master);
      return UnlockResult.ok;
    } catch (e) {
      debugPrint('[private] unlock: $e');
      return UnlockResult.broken;
    }
  }

  /// A new PIN for the open space.
  static Future<bool> changePin(String newPin) async {
    final key = _key;
    if (key == null || !isValidPin(newPin)) return false;
    try {
      // A copy: whatever happens to the space meanwhile, this is the key that gets stored.
      await _storeLocked(Uint8List.fromList(key), newPin);
      return true;
    } catch (e) {
      debugPrint('[private] change pin: $e');
      return false;
    }
  }

  /// Forgot the PIN: the vault's recovery key opens the private key instead,
  /// and a new PIN is set. False when the recovery key is not the right one.
  static Future<bool> resetWithRecoveryKey(String typed, String newPin) async {
    if (!supported || !isValidPin(newPin)) return false;
    try {
      final hex = typed.replaceAll(RegExp(r'[^0-9a-fA-F]'), '').toLowerCase();
      if (hex.length != 64) return false;
      final wrap = await _read('wrap_vault');
      if (wrap.isEmpty) return false;
      final master = await _openBytes(await _recoveryKek(hex), base64Decode(wrap));
      if (master == null || master.length != 32) return false;
      await _storeLocked(master, newPin);
      _opened(master);
      return true;
    } catch (e) {
      debugPrint('[private] reset: $e');
      return false;
    }
  }

  static void _opened(Uint8List master) {
    // BYTE left the screen while the PIN was being checked: it stays closed.
    if (_away && _holds == 0 && !_sentAway) return;
    _key = master;
    unlocked.value = true;
    unawaited(_afterUnlock());
  }

  static Future<void> _afterUnlock() async {
    await _serial(() async {
      await _sweepLeftovers();
      await _sealPending();
    });
    await flushTrash();
  }

  /// Moving in, moving out and locking files never run at the same time:
  /// each waits for the one before it.
  static Future<void> _line = Future<void>.value();

  static Future<T> _serial<T>(Future<T> Function() job) {
    final run = _line.then((_) => job());
    _line = run.then<void>((_) {}, onError: (Object _) {});
    return run;
  }

  /// Closes the space: the key is forgotten, opened copies are wiped.
  static void lock() {
    // (The key is only let go of, not overwritten: work that is still running
    // with it — locking a big video — must finish with the right key.)
    _key = null;
    _thumbs.clear();
    _holds = 0;
    _sentAway = false;
    if (unlocked.value) unlocked.value = false;
    // Wiped before anything else can happen (opening the space again at once
    // must not find an old copy that is about to disappear).
    final root = _openRoot;
    if (root != null) {
      try {
        final d = Directory(root);
        if (d.existsSync()) d.deleteSync(recursive: true);
      } catch (e) {
        debugPrint('[private] wipe: $e');
      }
    } else {
      unawaited(wipeOpened());
    }
  }

  // ───────────── leaving BYTE ─────────────

  /// A file picker or the share sheet is about to cover BYTE: do not lock
  /// for that. Pair every [hold] with a [release].
  static void hold() => _holds++;

  static void release() {
    if (_holds > 0) _holds--;
  }

  /// BYTE went to the background: the space locks — unless BYTE itself sent
  /// you to a picker or the share sheet a moment ago.
  static void onAppPaused() {
    _away = true;
    if (_key == null) return;
    if (_holds == 0 && !_sentAway) {
      lock();
    } else {
      // Kept from the first call: on the way back Android reports "hidden"
      // once more before "resumed".
      _pausedAt ??= DateTime.now();
    }
  }

  static bool _away = false;
  static bool _sentAway = false;

  /// BYTE hands a file to another app ("Open in another app"): the space
  /// stays open until you are back — five minutes at most.
  static void holdUntilBack([bool on = true]) => _sentAway = on;

  static void onAppResumed() {
    _away = false;
    _sentAway = false;
    final at = _pausedAt;
    _pausedAt = null;
    // Away for long, even with a picker open: lock anyway.
    if (_key != null && at != null && DateTime.now().difference(at) > const Duration(minutes: 5)) lock();
    unawaited(flushTrash());
  }

  /// App start: nothing opened in the last run may still lie around.
  static Future<void> init() async {
    await wipeOpened();
    await _wipeShared();
  }

  /// No screenshots and a blank card in "recent apps" while private things
  /// are on screen.
  static Future<void> setSecure(bool on) async {
    if (!supported) return;
    try {
      await _sys.invokeMethod<void>('secure', {'on': on});
    } catch (_) {}
  }

  // ───────────── opening a private file ─────────────

  /// Where opened copies live, once it is known (so locking can wipe it at once).
  static String? _openRoot;

  static Future<Directory> _openDir() async {
    final d = Directory(p.join((await getTemporaryDirectory()).path, 'private_open'));
    _openRoot = d.path;
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  /// Deletes every opened (unlocked) copy.
  static Future<void> wipeOpened() async {
    try {
      final d = Directory(p.join((await getTemporaryDirectory()).path, 'private_open'));
      _openRoot = d.path;
      if (await d.exists()) await d.delete(recursive: true);
    } catch (e) {
      debugPrint('[private] wipe: $e');
    }
  }

  /// The share sheet keeps its own copy of what was shared: at the next
  /// start of BYTE (not sooner — the other app may still be reading it) it goes.
  static Future<void> _wipeShared() async {
    try {
      final d = Directory(p.join((await getTemporaryDirectory()).path, 'share_plus'));
      if (await d.exists()) await d.delete(recursive: true);
    } catch (e) {
      debugPrint('[private] wipe shared: $e');
    }
  }

  static final Map<String, Future<String?>> _opening = {};

  /// A readable copy of a private item's file, for viewing. It lives in
  /// BYTE's cache and is wiped when the space locks. null when it cannot be
  /// had (the space is locked, or the file is only in Drive and there is no
  /// internet).
  static Future<String?> openPlain(LibraryItem it) {
    final busy = _opening[it.id];
    if (busy != null) return busy;
    final job = _openPlain(it);
    _opening[it.id] = job;
    return job.whenComplete(() {
      _opening.remove(it.id);
    });
  }

  static Future<String?> _openPlain(LibraryItem it) async {
    final key = _key;
    if (key == null || it.path.isEmpty) return null;
    try {
      // On the phone? If not, the copy in Drive is fetched first.
      if (!await File(it.path).exists()) {
        if (await DriveMedia.ensureLocal(it) == null) return null;
      }
      if (!it.sealed) return it.path; // not locked yet (BYTE is still reading it)
      final dir = await _openDir();
      final dst = p.join(dir.path, '${it.id}${p.extension(plainPath(it.path)).toLowerCase()}');
      if (await File(dst).exists()) return dst; // opened earlier in this visit
      await _ch.invokeMethod<int>('openFile', {'key': key, 'src': it.path, 'dst': dst});
      // Locked meanwhile: the copy must not stay.
      if (_key == null) {
        try {
          await File(dst).delete();
        } catch (_) {}
        return null;
      }
      return dst;
    } catch (e) {
      debugPrint('[private] open ${it.id}: $e');
      return null;
    }
  }

  static final Map<String, Uint8List> _thumbs = {};

  /// The preview picture of a private item, opened in memory only.
  static Future<Uint8List?> thumbBytes(LibraryItem it) async {
    final key = _key;
    if (key == null || !it.thumbSealed) return null;
    final hit = _thumbs[it.thumb];
    if (hit != null) return hit;
    try {
      final b = await _ch.invokeMethod<Uint8List>('openBytes', {'key': key, 'src': it.thumb});
      if (b == null || _key == null) return null;
      if (_thumbs.length >= 400) _thumbs.remove(_thumbs.keys.first);
      _thumbs[it.thumb] = b;
      return b;
    } catch (e) {
      debugPrint('[private] thumb ${it.id}: $e');
      return null;
    }
  }

  // ───────────── locking files ─────────────

  /// Locks the files of private items that are not locked yet. Needs the
  /// space to be open (it does nothing otherwise). Files BYTE is still
  /// reading wait for the next call — the reader calls this when it is done,
  /// and so does every unlock.
  static Future<void> sealPending() async {
    if (_key == null) return;
    await _serial(_sealPending);
  }

  static Future<void> _sealPending() async {
    var did = 0;
    try {
      final own = (await getApplicationSupportDirectory()).path;
      final rows = await AppDb.instance.db.rawQuery('''
        SELECT i.id, f.path AS fpath, f.thumb AS fthumb, f.index_status AS st, f.media_key AS mk, a.path AS apath
        FROM items i LEFT JOIN files f ON f.item_id = i.id LEFT JOIN audio a ON a.item_id = i.id
        WHERE i.private = 1
      ''');
      for (final r in rows) {
        final key = _key;
        if (key == null) break; // locked meanwhile: the rest waits for the next unlock
        try {
          if (await _sealRow(r, key, own)) did++;
        } catch (e) {
          debugPrint('[private] seal ${r['id']}: $e');
        }
      }
    } catch (e) {
      debugPrint('[private] seal: $e');
    }
    if (did > 0) {
      changed.value++;
      LibraryRepo.instance.touch();
      unawaited(DriveMedia.kick()); // locked copies may go to Drive now
      unawaited(flushTrash());
    }
  }

  /// Locks one item's files. True when something was locked.
  static Future<bool> _sealRow(Map<String, Object?> r, Uint8List key, String own) async {
    final id = '${r['id']}';
    final st = '${r['st'] ?? ''}';
    if (st == 'pending' || st == 'working') return false; // BYTE is still reading it
    if ('${r['mk'] ?? ''}'.isNotEmpty) return false; // lives in the phone's gallery: not BYTE's file to lock
    final db = AppDb.instance.db;
    var did = false;

    Future<String?> sealOne(String path) async {
      if (path.isEmpty || isSealedPath(path) || !p.isWithin(own, path)) return null;
      final src = File(path);
      if (!await src.exists()) return null;
      final dst = sealedPath(path);
      await _ch.invokeMethod<int>('sealFile', {'key': key, 'src': path, 'dst': dst});
      return dst;
    }

    // 1. The file itself (a photo, video or document).
    var fpath = '${r['fpath'] ?? ''}';
    if (fpath.isNotEmpty && !isSealedPath(fpath) && p.isWithin(own, fpath) && !await File(fpath).exists()) {
      // Only in Drive (its phone copy was freed): bring it back, then lock it.
      final it = await LibraryRepo.instance.get(id);
      if (it == null || await DriveMedia.ensureLocal(it) == null) return false; // no internet now: next time
    }
    final sealedFile = await sealOne(fpath);
    if (sealedFile != null) {
      final now = DateTime.now().millisecondsSinceEpoch;
      var mine = false;
      await db.transaction((txn) async {
        // Only if the row still names the file that was locked (something
        // else — shrinking, a fix — may have given the item another file meanwhile).
        mine = await txn.rawUpdate('UPDATE files SET path = ? WHERE item_id = ? AND path = ?', [sealedFile, id, fpath]) > 0;
        if (!mine) return;
        final d = await txn.rawQuery('SELECT remote_id FROM drive_media WHERE item_id = ?', [id]);
        if (d.isNotEmpty) {
          final rid = '${d.first['remote_id'] ?? ''}';
          if (rid.isNotEmpty) await txn.rawInsert('INSERT OR IGNORE INTO private_trash (remote_id) VALUES (?)', [rid]);
          // The locked file goes up as a new upload of its own.
          await txn.rawUpdate(
            "UPDATE drive_media SET remote_id = '', state = 'queued', local = 1, name = ?, error = '', tries = 0, updated_at = ? WHERE item_id = ?",
            [p.basename(sealedFile), now, id],
          );
        }
      });
      if (mine) {
        await _forgetRemote(fpath);
        await _deleteQuietly(fpath);
        did = true;
      } else {
        await _deleteQuietly(sealedFile); // locked the wrong file: the next pass takes the right one
      }
    }

    // 2. Its preview picture.
    final fthumb = '${r['fthumb'] ?? ''}';
    final sealedThumb = await sealOne(fthumb);
    if (sealedThumb != null) {
      if (await db.rawUpdate('UPDATE files SET thumb = ? WHERE item_id = ? AND thumb = ?', [sealedThumb, id, fthumb]) > 0) {
        await _forgetRemote(fthumb);
        await _deleteQuietly(fthumb);
        did = true;
      } else {
        await _deleteQuietly(sealedThumb);
      }
    }

    // 3. A voice note's recording.
    final apath = '${r['apath'] ?? ''}';
    final sealedAudio = await sealOne(apath);
    if (sealedAudio != null) {
      if (await db.rawUpdate('UPDATE audio SET path = ? WHERE item_id = ? AND path = ?', [sealedAudio, id, apath]) > 0) {
        await _forgetRemote(apath);
        await _deleteQuietly(apath);
        did = true;
      } else {
        await _deleteQuietly(sealedAudio);
      }
    }
    return did;
  }

  /// The plain copies of [path] that are in Drive must go: the one BYTE has
  /// on its list (put there by the daily backup, or as the photo's own Drive
  /// copy), and older ones under the same name with another ending (the
  /// photo before BYTE shrank it, the recording before it was made smaller).
  /// They are put on the list for Drive's Trash.
  static Future<void> _forgetRemote(String path) async {
    final dir = p.basename(p.dirname(path));
    final name = p.basename(path);
    await CloudSync.forgetFile('$dir/$name');
    final stem = p.basenameWithoutExtension(name);
    final ext = p.extension(name).toLowerCase();
    const pictures = ['.jpg', '.jpeg', '.png', '.webp', '.heic'];
    final names = <String>{
      name,
      if (dir == 'audio') ...['$stem.wav', '$stem.m4a'],
      if (dir == 'thumbs') ...['$stem.png', '$stem.jpg'],
      if (dir == 'files' && pictures.contains(ext))
        for (final e in pictures) '$stem$e',
    };
    final db = AppDb.instance.db;
    for (final n in names) {
      // "name:" = look it up in Drive by its name (BYTE has no number for it).
      await db.rawInsert('INSERT OR IGNORE INTO private_trash (remote_id) VALUES (?)', ['name:$dir/$n']);
    }
  }

  static Future<void> _deleteQuietly(String path) async {
    try {
      final f = File(path);
      if (await f.exists()) await f.delete();
    } catch (e) {
      debugPrint('[private] delete $path: $e');
    }
  }

  /// A locked file whose plain twin is still on disk (BYTE was closed in
  /// the middle of locking it) or still in Drive: the twin goes.
  static Future<void> _sweepLeftovers() async {
    try {
      final own = (await getApplicationSupportDirectory()).path;
      final rows = await AppDb.instance.db.rawQuery('''
        SELECT f.path AS fpath, f.thumb AS fthumb, a.path AS apath
        FROM items i LEFT JOIN files f ON f.item_id = i.id LEFT JOIN audio a ON a.item_id = i.id
        WHERE i.private = 1
      ''');
      for (final r in rows) {
        for (final k in const ['fpath', 'fthumb', 'apath']) {
          final path = '${r[k] ?? ''}';
          if (!isSealedPath(path) || !p.isWithin(own, path)) continue;
          // An upload of the plain file that was still running while it was
          // being locked may have finished afterwards: that copy goes too.
          final plain = plainPath(path);
          await CloudSync.forgetFile('${p.basename(p.dirname(plain))}/${p.basename(plain)}');
          // Only when the locked file really is there.
          if (await File(path).exists()) await _deleteQuietly(plainPath(path));
        }
      }
    } catch (e) {
      debugPrint('[private] leftovers: $e');
    }
  }

  /// Says, for a file "folder/name" (e.g. "files/ab12.jpg"), whether it must
  /// be HELD BACK from an upload or a backup right now: every file of a
  /// private item that is not locked, files BYTE is still making, and
  /// working copies. Works while the space is locked. If the vault cannot be
  /// asked this throws — then nothing is uploaded, rather than everything.
  static Future<bool Function(String rel)> uploadGuard() async {
    final db = AppDb.instance.db;
    final ids = <String>{for (final r in await db.rawQuery('SELECT id FROM items WHERE private = 1')) '${r['id']}'.toLowerCase()};
    final held = <String>{};
    final rows = await db.rawQuery('''
      SELECT f.path AS fpath, f.thumb AS fthumb, a.path AS apath
      FROM items i LEFT JOIN files f ON f.item_id = i.id LEFT JOIN audio a ON a.item_id = i.id
      WHERE i.private = 1
    ''');
    for (final r in rows) {
      for (final k in const ['fpath', 'fthumb', 'apath']) {
        final path = '${r[k] ?? ''}';
        if (path.isEmpty) continue;
        final plain = plainPath(path);
        held.add('${p.basename(p.dirname(plain))}/${p.basename(plain)}');
      }
    }
    // BYTE names its files after the item's id: anything carrying a private
    // item's id is held too, unless it is the locked file itself.
    final idIn = RegExp(r'[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}', caseSensitive: false);
    return (String rel) {
      final name = p.basename(rel).toLowerCase();
      if (name.endsWith('.part') || name.endsWith('.tmp') || name.startsWith('frame-') || name.startsWith('fix-')) return true;
      if (held.contains(rel)) return true;
      if (isSealedPath(name)) return false;
      final m = idIn.firstMatch(name);
      return m != null && ids.contains(m.group(0));
    };
  }

  /// How many private files are not locked yet (BYTE is still reading
  /// them, or they are only in Drive right now).
  static Future<int> unsealedCount() async {
    try {
      final rows = await AppDb.instance.db.rawQuery('''
        SELECT COUNT(*) AS n FROM items i LEFT JOIN files f ON f.item_id = i.id LEFT JOIN audio a ON a.item_id = i.id
        WHERE i.private = 1 AND i.deleted_at IS NULL
          AND ((COALESCE(f.path, '') != '' AND f.path NOT LIKE '%$sealedExt') OR (COALESCE(a.path, '') != '' AND a.path NOT LIKE '%$sealedExt'))
      ''');
      return (rows.first['n'] as int?) ?? 0;
    } catch (e) {
      debugPrint('[private] unsealed: $e');
      return 0;
    }
  }

  /// Every file on the phone that belongs to a private item (its file, its
  /// preview, its recording). Screens that list files by size leave these
  /// out. Works while the space is locked.
  static Future<Set<String>> filePaths() async {
    final out = <String>{};
    try {
      final rows = await AppDb.instance.db.rawQuery('''
        SELECT f.path AS fpath, f.thumb AS fthumb, a.path AS apath
        FROM items i LEFT JOIN files f ON f.item_id = i.id LEFT JOIN audio a ON a.item_id = i.id
        WHERE i.private = 1
      ''');
      for (final r in rows) {
        for (final k in const ['fpath', 'fthumb', 'apath']) {
          final path = '${r[k] ?? ''}';
          if (path.isNotEmpty) out.add(path);
        }
      }
    } catch (e) {
      debugPrint('[private] file paths: $e');
    }
    return out;
  }

  /// Plain copies that were in Drive before their item became private go to
  /// Drive's Trash — now, or the next time there is internet.
  static Future<void> flushTrash() async {
    try {
      final db = AppDb.instance.db;
      final rows = await db.query('private_trash', limit: 200);
      if (rows.isEmpty || !await CloudSync.connected() || !await DriveMedia.isOnline()) return;
      for (final r in rows) {
        final rid = '${r['remote_id']}';
        try {
          if (rid.startsWith('name:')) {
            await CloudSync.trashByName(rid.substring(5));
          } else {
            await CloudSync.trashMedia(rid); // already gone counts as done
          }
          await db.delete('private_trash', where: 'remote_id = ?', whereArgs: [rid]);
        } catch (e) {
          // This one stays on the list for next time; the others still go.
          debugPrint('[private] trash $rid: $e');
          if (e is CloudNeedsSignIn) return;
        }
      }
    } catch (e) {
      debugPrint('[private] trash: $e');
    }
  }

  // ───────────── moving things in and out ─────────────

  static void _tellEveryone() {
    changed.value++;
    LibraryRepo.instance.touch();
    NotesRepo.instance.revision.value++;
    AudioRepo.instance.revision.value++;
    CollectionsRepo.instance.revision.value++;
  }

  /// Makes items private. The space must be open. Each item leaves the
  /// Library, Search and your ordinary folders at once; its files are locked
  /// right after (or as soon as BYTE has finished reading them).
  static Future<PrivateMove> moveIn(Iterable<String> ids) {
    final list = ids.toList();
    return _serial(() => _moveIn(list));
  }

  static Future<PrivateMove> _moveIn(List<String> ids) async {
    if (_key == null) return const PrivateMove();
    final db = AppDb.instance.db;
    var moved = 0;
    var failed = 0;
    final originals = <String, String>{}; // gallery number → the original's place
    final tookOver = <String, String>{}; // gallery number → the item BYTE copied it into
    for (final id in ids) {
      try {
        final it = await LibraryRepo.instance.get(id);
        if (it == null) continue;
        if (it.private) continue;
        if (it.fromGallery) {
          // BYTE only lists this photo; it lives in the phone's gallery. Take
          // a copy of BYTE's own first.
          final took = await Gallery.takeOver(id);
          if (took == null) {
            failed++;
            continue;
          }
          originals[took.$1] = took.$2;
          tookOver[took.$1] = id;
        }
        await db.transaction((txn) async {
          await txn.rawUpdate('UPDATE items SET private = 1 WHERE id = ?', [id]);
          await txn.rawDelete('DELETE FROM collection_items WHERE item_id = ? AND collection_id IN (SELECT id FROM collections WHERE private = 0)', [id]);
          // What the activity list says about it (its name, an Undo that could
          // act on it) goes too.
          await txn.rawDelete('DELETE FROM activity WHERE undo LIKE ?', ['%"$id"%']);
        });
        moved++;
      } catch (e) {
        debugPrint('[private] move in $id: $e');
        failed++;
      }
    }
    if (moved > 0) {
      _tellEveryone();
      Activity.changed.value++;
      unawaited(Bubble.refreshPin()); // a pinned checklist that became private is unpinned
      unawaited(DriveMedia.refresh());
      await _sealPending();
    }
    // An original in the gallery may be offered for deletion only when BYTE's
    // own copy of it is locked and safe now. (One BYTE is still reading stays
    // in the gallery; nothing is lost by that.)
    final safe = <String, String>{};
    for (final e in tookOver.entries) {
      final rows = await db.rawQuery('SELECT path FROM files WHERE item_id = ?', [e.value]);
      final place = originals[e.key];
      if (place != null && rows.isNotEmpty && isSealedPath('${rows.first['path'] ?? ''}')) safe[e.key] = place;
    }
    return PrivateMove(moved: moved, failed: failed, galleryOriginals: safe);
  }

  /// Takes items out of the private space: their files are unlocked and
  /// they are back in the Library. The space must be open.
  static Future<PrivateMove> moveOut(Iterable<String> ids) {
    final list = ids.toList();
    return _serial(() => _moveOut(list));
  }

  static Future<PrivateMove> _moveOut(List<String> ids) async {
    final key = _key;
    if (key == null) return const PrivateMove();
    final db = AppDb.instance.db;
    final own = (await getApplicationSupportDirectory()).path;
    var moved = 0;
    var failed = 0;
    for (final id in ids) {
      try {
        final rows = await db.rawQuery('''
          SELECT i.id, f.path AS fpath, f.thumb AS fthumb, a.path AS apath
          FROM items i LEFT JOIN files f ON f.item_id = i.id LEFT JOIN audio a ON a.item_id = i.id
          WHERE i.id = ? AND i.private = 1
        ''', [id]);
        if (rows.isEmpty) continue;
        final r = rows.first;

        // Every locked file is opened next to itself first; only when all of
        // them opened are the rows changed and the locked files removed.
        final opened = <String, String>{}; // column → plain path
        var ok = true;
        try {
          for (final k in const ['fpath', 'fthumb', 'apath']) {
            final path = '${r[k] ?? ''}';
            if (!isSealedPath(path) || !p.isWithin(own, path)) continue;
            if (!await File(path).exists()) {
              // The locked file is only in Drive: fetch it (the main file only; a preview is simply made again).
              final it = k == 'fpath' ? await LibraryRepo.instance.get(id) : null;
              if (it == null || await DriveMedia.ensureLocal(it) == null) {
                if (k == 'fthumb') {
                  opened[k] = '';
                  continue;
                }
                ok = false;
                break;
              }
            }
            final dst = plainPath(path);
            await _ch.invokeMethod<int>('openFile', {'key': key, 'src': path, 'dst': dst});
            opened[k] = dst;
          }
        } catch (e) {
          debugPrint('[private] open for move out $id: $e');
          ok = false;
        }
        if (!ok) {
          for (final path in opened.values) {
            if (path.isNotEmpty) await _deleteQuietly(path);
          }
          failed++;
          continue;
        }
        final now = DateTime.now().millisecondsSinceEpoch;
        await db.transaction((txn) async {
          if (opened.containsKey('fpath')) await txn.rawUpdate('UPDATE files SET path = ? WHERE item_id = ?', [opened['fpath'], id]);
          if (opened.containsKey('fthumb')) await txn.rawUpdate('UPDATE files SET thumb = ? WHERE item_id = ?', [opened['fthumb'], id]);
          if (opened.containsKey('apath')) await txn.rawUpdate('UPDATE audio SET path = ? WHERE item_id = ?', [opened['apath'], id]);
          if (opened.containsKey('fpath')) {
            final d = await txn.rawQuery('SELECT remote_id FROM drive_media WHERE item_id = ?', [id]);
            if (d.isNotEmpty) {
              // The locked copy in Drive is of no use any more; the open file goes up afresh.
              final rid = '${d.first['remote_id'] ?? ''}';
              if (rid.isNotEmpty) await txn.rawInsert('INSERT OR IGNORE INTO private_trash (remote_id) VALUES (?)', [rid]);
              await txn.rawUpdate(
                "UPDATE drive_media SET remote_id = '', state = 'queued', local = 1, name = ?, error = '', tries = 0, updated_at = ? WHERE item_id = ?",
                [p.basename(opened['fpath']!), now, id],
              );
            }
          }
          // A preview that could not be fetched is made again by the reader.
          if (opened['fthumb'] == '') await txn.rawUpdate("UPDATE files SET index_status = 'pending' WHERE item_id = ?", [id]);
          await txn.rawUpdate('UPDATE items SET private = 0 WHERE id = ?', [id]);
          // Its plain files are wanted in Drive again: they come off the "to Drive's Trash by name" list.
          await txn.rawDelete('DELETE FROM private_trash WHERE remote_id LIKE ?', ['name:%$id%']);
          await txn.rawDelete('DELETE FROM collection_items WHERE item_id = ? AND collection_id IN (SELECT id FROM collections WHERE private = 1)', [id]);
        });
        for (final k in opened.keys) {
          await _deleteQuietly('${r[k] ?? ''}'); // the locked file
        }
        moved++;
      } catch (e) {
        debugPrint('[private] move out $id: $e');
        failed++;
      }
    }
    if (moved > 0) {
      _tellEveryone();
      unawaited(DriveMedia.kick());
      unawaited(flushTrash());
    }
    return PrivateMove(moved: moved, failed: failed);
  }
}
