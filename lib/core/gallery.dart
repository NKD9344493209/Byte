import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../features/library/library_item.dart';
import '../features/library/library_repo.dart';
import 'call_names.dart';
import 'cloud_sync.dart';
import 'db.dart';
import 'drive_media.dart';
import 'prefs.dart';

/// One photo, video or call recording as the phone's gallery lists it.
/// Pure (no plugins) — unit-tested.
class GalleryEntry {
  const GalleryEntry({
    required this.kind,
    required this.id,
    required this.path,
    required this.name,
    required this.when,
    this.mime = '',
    this.size = 0,
    this.durationMs = 0,
    this.bucket = '',
  });

  /// image | video | audio
  final String kind;
  final int id;
  final String path;
  final String name;
  final String mime;
  final int size;
  final DateTime when;
  final int durationMs;

  /// The album the phone shows it under: Camera, Screenshots, WhatsApp Images…
  final String bucket;

  /// What BYTE remembers it by: "image:123".
  String get key => '$kind:$id';

  LibraryKind get libraryKind => switch (kind) {
        'video' => LibraryKind.video,
        'audio' => LibraryKind.audio,
        _ => LibraryKind.photo,
      };

  /// From one row of the native "scan". Null when the row is unusable.
  /// The date is the moment the photo was taken when the phone knows it,
  /// else when the file was last changed, else when it was added — and never
  /// a nonsense date (some apps write 1970 or a date in the future).
  static GalleryEntry? fromMap(String kind, Map<Object?, Object?> m, {DateTime? now}) {
    final id = (m['id'] as num?)?.toInt();
    final path = '${m['path'] ?? ''}';
    if (id == null || path.isEmpty) return null;
    final n = now ?? DateTime.now();
    final taken = (m['taken'] as num?)?.toInt() ?? 0;
    final modified = ((m['modified'] as num?)?.toInt() ?? 0) * 1000;
    final added = ((m['added'] as num?)?.toInt() ?? 0) * 1000;
    final floor = DateTime(1995).millisecondsSinceEpoch;
    final ceiling = n.add(const Duration(days: 1)).millisecondsSinceEpoch;
    bool sane(int ms) => ms > floor && ms < ceiling;
    final ms = sane(taken) ? taken : (sane(modified) ? modified : (sane(added) ? added : n.millisecondsSinceEpoch));
    final name = '${m['name'] ?? ''}';
    return GalleryEntry(
      kind: kind,
      id: id,
      path: path,
      name: name.isEmpty ? p.basename(path) : name,
      mime: '${m['mime'] ?? ''}',
      size: (m['size'] as num?)?.toInt() ?? 0,
      when: DateTime.fromMillisecondsSinceEpoch(ms),
      durationMs: (m['duration'] as num?)?.toInt() ?? 0,
      bucket: '${m['bucket'] ?? ''}'.replaceAll(',', ' ').trim(),
    );
  }
}

class GalleryState {
  const GalleryState({this.permission = 'none', this.on = false, this.running = false, this.count = 0, this.added = 0});

  /// all | partial | none
  final String permission;

  /// The user asked for the gallery to be inside BYTE.
  final bool on;

  /// A look at the gallery is running right now.
  final bool running;

  /// Gallery photos and videos BYTE lists in total.
  final int count;

  /// How many the look that is running (or just ended) has added so far.
  final int added;

  bool get allowed => permission != 'none';
}

/// What one "Free up space" pass did.
class FreeUpResult {
  const FreeUpResult({this.freed = 0, this.bytes = 0, this.left = 0, this.declined = false, this.offline = false, this.checking = false});

  /// A vault was restored and BYTE has not yet matched it with this phone's
  /// gallery: nothing is removed until that is done.
  final bool checking;
  final int freed;
  final int bytes;

  /// Still on the phone and safe in Drive — another pass can free them.
  final int left;

  /// Android's "Allow BYTE to delete…?" was answered No.
  final bool declined;

  /// Drive could not be reached, so nothing was checked or deleted.
  final bool offline;
}

/// Your phone's gallery inside BYTE — without copying it.
///
/// BYTE only LISTS the gallery: each photo and video stays where the camera
/// put it, BYTE keeps its path (`files.path`) and its gallery id
/// (`files.media_key`, e.g. "image:123"). New photos are picked up by
/// themselves. Nothing here ever deletes a photo on its own; originals are
/// only removed through Android's confirmation dialog.
class Gallery {
  Gallery._();

  static const _ch = MethodChannel('byte/gallery');
  static const _page = 400;

  static final ValueNotifier<GalleryState> state = ValueNotifier(const GalleryState());

  static bool _running = false;
  static bool _again = false;
  static bool _listening = false;
  static bool _fullAgain = false;
  static DateTime _lastReconcile = DateTime.fromMillisecondsSinceEpoch(0);
  static DateTime _lastCheckNow = DateTime.fromMillisecondsSinceEpoch(0);

  static bool get on => Prefs.flag('gallery_on');
  static bool get backup => Prefs.flag('gallery_backup');
  static bool get calls => Prefs.flag('gallery_calls');

  /// At startup: if the gallery was brought in before, look for what is new.
  static Future<void> init() async {
    if (!Platform.isAndroid) return;
    if (!_listening) {
      _listening = true;
      _ch.setMethodCallHandler((call) async {
        if (call.method == 'changed' && on) unawaited(sync());
      });
    }
    await _refreshState();
    if (!on) return;
    if (!state.value.allowed) return; // permission was taken away in Settings: the card says so
    try {
      await _ch.invokeMethod('watch');
    } catch (_) {}
    // Photos BYTE could not open before (access was reduced for a while) are
    // tried again now that the whole gallery can be seen.
    if (state.value.permission == 'all') {
      try {
        final n = await AppDb.instance.db.rawUpdate("UPDATE files SET index_status = 'pending' WHERE media_key != '' AND index_status = 'failed'");
        if (n > 0) LibraryRepo.instance.touch();
      } catch (e) {
        debugPrint('[gallery] retry unreadable: $e');
      }
    }
    unawaited(sync());
  }

  static Future<String> _permission() async {
    if (!Platform.isAndroid) return 'none';
    try {
      return await _ch.invokeMethod<String>('permission') ?? 'none';
    } catch (_) {
      return 'none';
    }
  }

  static Future<int> _count() async {
    try {
      final rows = await AppDb.instance.db.rawQuery(
        "SELECT COUNT(*) AS n FROM files f JOIN items i ON i.id = f.item_id WHERE f.media_key != '' AND i.deleted_at IS NULL",
      );
      return (rows.first['n'] as int?) ?? 0;
    } catch (_) {
      return 0;
    }
  }

  static Future<void> _refreshState({bool? running, int? added}) async {
    final s = state.value;
    state.value = GalleryState(
      permission: await _permission(),
      on: on,
      running: running ?? s.running,
      count: await _count(),
      added: added ?? s.added,
    );
  }

  /// "Bring in my gallery": asks Android for the permission, then lists
  /// everything. Returns the permission state (all | partial | none).
  static Future<String> turnOn() async {
    if (!Platform.isAndroid) return 'none';
    String perm;
    try {
      perm = await _ch.invokeMethod<String>('request') ?? 'none';
    } catch (_) {
      perm = 'none';
    }
    if (perm == 'none') {
      await _refreshState();
      return perm;
    }
    await Prefs.setFlag('gallery_on', true);
    try {
      await _ch.invokeMethod('watch');
    } catch (_) {}
    // Photos BYTE could not read while access was taken away get another try.
    try {
      final n = await AppDb.instance.db.rawUpdate("UPDATE files SET index_status = 'pending' WHERE media_key != '' AND index_status = 'failed'");
      if (n > 0) LibraryRepo.instance.touch(); // wakes the reader
    } catch (_) {}
    await _refreshState();
    unawaited(sync(full: true));
    return perm;
  }

  /// Stop listing new photos. What BYTE already lists stays (delete or keep
  /// each as you like); nothing on the phone is touched.
  static Future<void> turnOff() async {
    await Prefs.setFlag('gallery_on', false);
    await _refreshState();
  }

  /// Call recordings from the dialer's folder, on or off. Asks for the
  /// "Music and audio" permission when turned on. Returns whether it is on.
  static Future<bool> setCalls(bool v) async {
    if (!v) {
      await Prefs.setFlag('gallery_calls', false);
      return false;
    }
    bool ok;
    try {
      ok = await _ch.invokeMethod<bool>('requestAudio') ?? false;
    } catch (_) {
      ok = false;
    }
    await Prefs.setFlag('gallery_calls', ok);
    if (ok) unawaited(sync());
    return ok;
  }

  /// Copies of gallery photos in Google Drive, on or off. On: everything BYTE
  /// lists from the gallery is queued for upload — after anything you added
  /// to BYTE yourself, and following the "Wi-Fi only" switch of the Drive screen.
  static Future<void> setBackup(bool v) async {
    await Prefs.setFlag('gallery_backup', v);
    if (v) {
      await DriveMedia.queueGallery();
    } else {
      // Off: what was still waiting is no longer sent. What is already in Drive stays there.
      await DriveMedia.unqueueGallery();
    }
  }

  // ───────────── looking at the gallery ─────────────

  /// Lists what is new since the last look. Safe to call any time; a call
  /// while one is running makes it look once more at the end. [full]: go
  /// through the whole gallery list again (cheap — what BYTE already lists is
  /// skipped), not only the photos newer than the last one seen.
  static Future<int> sync({bool full = false}) async {
    if (!Platform.isAndroid || !on || _paused) return 0;
    if (_running) {
      _again = true;
      if (full) _fullAgain = true;
      return 0;
    }
    _running = true;
    var added = 0;
    try {
      if (await _permission() == 'none') return 0;
      await _refreshState(running: true, added: 0);
      await _rekeyIfDue();
      var wantFull = full;
      // Once a day the whole list is compared, not only "what is new": a video
      // that was still being recorded, or a photo taken back out of the
      // gallery's own bin, has an old number and would otherwise be missed.
      final day = DateTime.now().millisecondsSinceEpoch ~/ 86400000;
      final daily = Prefs.number('gallery_full_day') != day;
      if (daily) wantFull = true;
      var wentThroughAll = false;
      do {
        _again = false;
        if (_fullAgain) wantFull = true;
        _fullAgain = false;
        if (wantFull) wentThroughAll = true;
        added += await _pull('image', added, full: wantFull);
        added += await _pull('video', added, full: wantFull);
        if (calls) added += await _pull('audio', added, callsOnly: true, full: wantFull);
        wantFull = false;
      } while (_again);
      if (daily) await Prefs.setNumber('gallery_full_day', day);
      await _reconcile();
      // (After a full look too: photos whose place in the queue was lost while
      // they could not be read are put back.)
      if (backup && (added > 0 || wentThroughAll)) await DriveMedia.queueGallery();
    } catch (e) {
      debugPrint('[gallery] sync: $e');
    } finally {
      _running = false;
      await _refreshState(running: false, added: added);
    }
    // The gallery changed while the last steps ran: look once more.
    if (_again || _fullAgain) {
      _again = false;
      final again = _fullAgain;
      _fullAgain = false;
      unawaited(sync(full: again));
    }
    return added;
  }

  /// An original turned out to be gone: compare with the gallery now instead
  /// of waiting for the usual turn (at most once a minute).
  static Future<void> checkMissingNow() async {
    final now = DateTime.now();
    if (now.difference(_lastCheckNow) < const Duration(minutes: 1)) return;
    _lastCheckNow = now;
    _lastReconcile = DateTime.fromMillisecondsSinceEpoch(0);
    await sync();
  }

  /// One kind, page by page. Normally from where the last look stopped;
  /// [full] from the very beginning.
  static Future<int> _pull(String kind, int addedBefore, {bool callsOnly = false, bool full = false}) async {
    final cursorKey = callsOnly ? 'gallery_after_calls' : 'gallery_after_$kind';
    final saved = Prefs.number(cursorKey);
    var after = full ? 0 : saved;
    var added = 0;
    while (true) {
      final rows = await _ch.invokeMethod<List<dynamic>>('scan', {'kind': kind, 'afterId': after, 'limit': _page, 'calls': callsOnly});
      if (rows == null || rows.isEmpty) break;
      final entries = <GalleryEntry>[];
      var top = after;
      for (final r in rows) {
        if (r is! Map) continue;
        final id = (r['id'] as num?)?.toInt() ?? 0;
        if (id > top) top = id;
        final e = GalleryEntry.fromMap(kind, r);
        if (e != null) entries.add(e);
      }
      added += await _insert(entries, callRecording: callsOnly);
      if (top <= after) break; // no progress: never loop on the same page
      after = top;
      // Saved only after the page is safely in the vault, and never moved back.
      if (after > Prefs.number(cursorKey)) await Prefs.setNumber(cursorKey, after);
      state.value = GalleryState(
        permission: state.value.permission,
        on: true,
        running: true,
        count: state.value.count,
        added: addedBefore + added,
      );
      if (rows.length < _page) break;
    }
    return added;
  }

  /// Adds the entries BYTE does not list yet. One transaction per page.
  static Future<int> _insert(List<GalleryEntry> entries, {bool callRecording = false}) async {
    if (entries.isEmpty) return 0;
    final db = AppDb.instance.db;
    final keys = [for (final e in entries) e.key];
    final marks = List.filled(keys.length, '?').join(',');
    final known = <String>{
      for (final r in await db.rawQuery("SELECT media_key FROM files WHERE media_key != '' AND media_key IN ($marks)", keys)) '${r['media_key']}',
      for (final r in await db.rawQuery('SELECT media_key FROM gallery_skip WHERE media_key IN ($marks)', keys)) '${r['media_key']}',
    };
    final fresh = [
      for (final e in entries)
        if (!known.contains(e.key)) e,
    ];
    if (fresh.isNotEmpty) {
      // A file BYTE already lists, now under a new number (the card was put
      // back in, the photo came back from the gallery's bin): no second row.
      // The row BYTE has takes the new number at the check that follows.
      final pm = List.filled(fresh.length, '?').join(',');
      final listed = <String>{
        for (final r in await db.rawQuery("SELECT path FROM files WHERE media_key != '' AND path IN ($pm)", [for (final e in fresh) e.path])) '${r['path']}',
      };
      if (listed.isNotEmpty) {
        fresh.removeWhere((e) => listed.contains(e.path));
        _lastReconcile = DateTime.fromMillisecondsSinceEpoch(0);
      }
    }
    if (fresh.isEmpty) return 0;
    const uuid = Uuid();
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final e in fresh) {
        final id = uuid.v4();
        final at = e.when.millisecondsSinceEpoch;
        final kind = e.libraryKind;
        batch.insert('items', {
          'id': id,
          'type': kind.name,
          'title': callRecording ? callTitle(p.basenameWithoutExtension(e.name)) : '',
          'body': '',
          'tags': callRecording ? 'Call recording' : e.bucket,
          'sensitivity': 0,
          'source': 'gallery',
          'created_at': at,
          'updated_at': at,
        });
        batch.insert('files', {
          'item_id': id,
          'kind': kind.name,
          'path': e.path,
          'url': '',
          'mime': e.mime,
          'size': e.size,
          'thumb': '',
          'text': '',
          'labels': '',
          'index_status': 'pending',
          'media_key': e.key,
        });
      }
      await batch.commit(noResult: true);
    });
    LibraryRepo.instance.revision.value++;
    return fresh.length;
  }

  /// Keeps BYTE's list in step with the phone's gallery, by ASKING the
  /// gallery (never by guessing from "is the file there?"):
  ///  - a photo that was moved or renamed keeps everything (stars, folders,
  ///    the words BYTE read) and just gets its new place;
  ///  - a photo the gallery no longer lists AND whose file is gone has left
  ///    the phone: if Drive has a copy BYTE keeps it as a photo that lives in
  ///    Drive, otherwise it leaves BYTE's list too.
  /// Does nothing without full access, when the gallery cannot be asked, or
  /// while the storage a photo was on is not there (an SD card taken out).
  static Future<void> _reconcile() async {
    final now = DateTime.now();
    if (now.difference(_lastReconcile) < const Duration(minutes: 10)) return;
    if (await _permission() != 'all') return;
    _lastReconcile = now;
    final db = AppDb.instance.db;
    // Call recordings can only be checked while BYTE may see the phone's audio:
    // without that access "not listed" means nothing, so they are left alone.
    final audioOk = await _audioAllowed();
    final all = [
      for (final r in await db.rawQuery("SELECT item_id, path, thumb, media_key, size FROM files WHERE media_key != ''"))
        if (audioOk || !'${r['media_key']}'.startsWith('audio:')) r,
    ];
    if (all.isEmpty) return;
    var changed = false;
    for (var from = 0; from < all.length; from += 400) {
      final chunk = all.sublist(from, from + 400 > all.length ? all.length : from + 400);
      final answer = await _ch.invokeMethod<Map<dynamic, dynamic>>('paths', {
        'keys': [for (final r in chunk) '${r['media_key']}'],
      });
      if (answer == null) return; // the gallery could not be asked: touch nothing
      final gone = <Map<String, Object?>>[];
      for (final r in chunk) {
        final key = '${r['media_key']}';
        final path = '${r['path']}';
        if (!_storageThere(path)) continue; // decided when its card is back in the phone
        final current = answer[key];
        if (current is String && current.isNotEmpty) {
          if (current == path) continue;
          // A new place is believed only when it is plainly the same file,
          // moved or renamed: the old place is empty, and the name or the
          // size is unchanged.
          final size = (r['size'] as int?) ?? 0;
          final moved = !File(path).existsSync() && (p.basename(current) == p.basename(path) || (size > 0 && _sameSize(current, size)));
          if (!moved) {
            // A different file under this number: these are not this phone's
            // numbers (any more). None is trusted until each photo has been
            // found again by its file — and nothing is deleted meanwhile.
            await Prefs.setFlag('gallery_rekey_due', true);
            _lastReconcile = DateTime.fromMillisecondsSinceEpoch(0);
            _again = true;
            _fullAgain = true;
            return;
          }
          await db.rawUpdate('UPDATE files SET path = ?, sorted = 0 WHERE item_id = ?', [current, r['item_id']]);
          changed = true;
        } else {
          gone.add(r);
        }
      }
      if (gone.isEmpty) continue;
      // Not listed under that number any more. The same file under a new number?
      final found = await _ch.invokeMethod<Map<dynamic, dynamic>>('lookup', {
        'paths': [for (final r in gone) '${r['path']}'],
      });
      if (found == null) return;
      for (final r in gone) {
        final id = '${r['item_id']}';
        final path = '${r['path']}';
        final newKey = found[path];
        // Listed there under a new number. The same file only if its size is
        // unchanged; otherwise another photo has taken that name and the one
        // BYTE listed is gone.
        final listed = newKey is String && newKey.isNotEmpty;
        if (listed && _sameSize(path, (r['size'] as int?) ?? 0)) {
          await _setKey(id, newKey);
          changed = true;
          continue;
        }
        if (!listed) {
          if (path.isEmpty || File(path).existsSync()) continue; // still on the phone: leave it alone
          if (!_storageThere(path)) continue; // its storage is not attached right now
        } else {
          _again = true; // the photo that took the name is listed at the look that follows
          _fullAgain = true; // (a full look: its number is already behind the cursor)
        }
        final e = await DriveMedia.entry(id);
        if (e != null && e.remoteId.isNotEmpty && e.state == 'in_drive') {
          await _adopt(id, path);
        } else {
          await _drop(id, '${r['thumb'] ?? ''}');
        }
        changed = true;
      }
    }
    if (changed) {
      await DriveMedia.sweepDeleted();
      LibraryRepo.instance.revision.value++;
    }
  }

  /// Is the storage that held [path] attached? "/storage/emulated/0/…" →
  /// "/storage/emulated/0"; "/storage/1A2B-3C4D/…" (an SD card) → that card.
  static bool _storageThere(String path) {
    final parts = path.split('/');
    if (parts.length < 4 || parts[1] != 'storage') return true;
    final root = parts[2] == 'emulated' && parts.length > 4 ? '/storage/emulated/${parts[3]}' : '/storage/${parts[2]}';
    return Directory(root).existsSync();
  }

  /// The gallery lists this file under a new number: remember the new one.
  /// (If another row already holds that number, this one is a stale double.)
  static Future<void> _setKey(String itemId, String newKey) async {
    final db = AppDb.instance.db;
    // Another row holds that number: it is a fresh double of this same file.
    // This row carries the stars, folders, words and the Drive copy — the
    // double goes (its row only; no file is touched).
    final taken = await db.rawQuery('SELECT item_id, thumb FROM files WHERE media_key = ? AND item_id != ?', [newKey, itemId]);
    for (final t in taken) {
      await _drop('${t['item_id']}', '${t['thumb'] ?? ''}');
    }
    await db.rawUpdate('UPDATE files SET media_key = ? WHERE item_id = ?', [newKey, itemId]);
  }

  /// May BYTE see the phone's audio files (call recordings)?
  static Future<bool> _audioAllowed() async {
    try {
      return await _ch.invokeMethod<bool>('audioPermission') ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> _drop(String itemId, String thumb) async {
    if (thumb.isNotEmpty) {
      try {
        await File(thumb).delete();
      } catch (_) {}
    }
    await AppDb.instance.db.transaction((txn) async {
      await txn.delete('collection_items', where: 'item_id = ?', whereArgs: [itemId]);
      await txn.delete('item_places', where: 'item_id = ?', whereArgs: [itemId]);
      await txn.delete('files', where: 'item_id = ?', whereArgs: [itemId]);
      await txn.delete('items', where: 'id = ?', whereArgs: [itemId]);
    });
  }

  /// A vault was just restored (from a backup file or from Drive). Gallery
  /// numbers belong to ONE phone: on another phone — or after the phone's
  /// media list was rebuilt — "image:123" is a different photo. So every
  /// number is distrusted until the gallery has been asked again, the
  /// "never list again" memory is emptied, and the next look starts from the
  /// beginning.
  static Future<void> afterRestore() async {
    _paused = false;
    try {
      await AppDb.instance.db.delete('gallery_skip');
    } catch (_) {}
    await Prefs.setNumber('gallery_after_image', 0);
    await Prefs.setNumber('gallery_after_video', 0);
    await Prefs.setNumber('gallery_after_calls', 0);
    await Prefs.setFlag('gallery_rekey_due', true);
    await Prefs.setFlag('gallery_skip_stale', true);
    _lastReconcile = DateTime.fromMillisecondsSinceEpoch(0);
    // "Copy gallery photos to Drive" is this phone's own switch: a queue that
    // came with the vault does not start uploading here by itself.
    if (!backup) await DriveMedia.unqueueGallery();
    if (on) unawaited(sync(full: true));
  }

  static bool _paused = false;
  static bool _rekeyWasDue = false;

  /// A restore is about to swap the vault. From this moment no gallery
  /// number is trusted and no look at the gallery runs, until
  /// [afterRestore] (the restore went through, or stopped half-way with the
  /// other vault in place) or [restoreAborted] (the old vault is back).
  static Future<void> beforeRestore() async {
    _paused = true;
    // A look that is running right now finishes first (it must not go on in the other vault).
    for (var i = 0; i < 100 && _running; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    _rekeyWasDue = keysUntrusted;
    await Prefs.setFlag('gallery_rekey_due', true);
  }

  /// The restore did not happen and the vault is the one from before.
  static Future<void> restoreAborted() async {
    _paused = false;
    if (!_rekeyWasDue) await Prefs.setFlag('gallery_rekey_due', false);
  }

  static bool _sameSize(String path, int size) {
    try {
      return size <= 0 || File(path).lengthSync() == size;
    } catch (_) {
      return false;
    }
  }

  /// True while the numbers in the vault may belong to another phone:
  /// nothing may be deleted by number until [_rekeyIfDue] has run.
  static bool get keysUntrusted => Prefs.flag('gallery_rekey_due');

  /// After a restore: find each listed photo by its FILE and take the number
  /// this phone gives it. A photo that is not on this phone stays if Drive has
  /// it (as a photo that lives in Drive) and leaves the list otherwise.
  static Future<void> _rekeyIfDue() async {
    if (!keysUntrusted) return;
    if (await _permission() != 'all') return; // cannot see the whole gallery: decide later
    final db = AppDb.instance.db;
    final audioOk = await _audioAllowed();
    // A row that cannot be decided now (a call recording while BYTE may not
    // see the phone's audio, a photo on a card that is not in the phone)
    // gives up its number — it may be another phone's — and keeps only its
    // kind. The gallery check finds it again by its file later.
    Future<void> hold(Map<String, Object?> r) async {
      final key = '${r['media_key']}';
      final held = '${key.split(':').first}:held-${r['item_id']}';
      if (key != held) await db.rawUpdate('UPDATE files SET media_key = ? WHERE item_id = ?', [held, r['item_id']]);
    }

    final all = <Map<String, Object?>>[];
    for (final r in await db.rawQuery("SELECT item_id, path, thumb, media_key, size FROM files WHERE media_key != ''")) {
      if (!audioOk && '${r['media_key']}'.startsWith('audio:')) {
        await hold(r);
      } else {
        all.add(r);
      }
    }
    for (var from = 0; from < all.length; from += 200) {
      final chunk = all.sublist(from, from + 200 > all.length ? all.length : from + 200);
      final found = await _ch.invokeMethod<Map<dynamic, dynamic>>('lookup', {
        'paths': [for (final r in chunk) '${r['path']}'],
      });
      if (found == null) return; // try again at the next look
      for (final r in chunk) {
        final id = '${r['item_id']}';
        final path = '${r['path']}';
        final key = found[path];
        // Same place AND same size: another phone can have a different photo under the same name.
        if (key is String && key.isNotEmpty && _sameSize(path, (r['size'] as int?) ?? 0)) {
          if (key != '${r['media_key']}') {
            // Free the number first: another row may be holding it by mistake.
            // (A row for this very file is a double and goes; any other row
            // only gives up the number and is decided in its own turn.)
            for (final h in await db.rawQuery('SELECT item_id, path, thumb, media_key FROM files WHERE media_key = ? AND item_id != ?', [key, id])) {
              if ('${h['path']}' == path) {
                await _drop('${h['item_id']}', '${h['thumb'] ?? ''}');
              } else {
                await hold(h);
              }
            }
            await db.rawUpdate('UPDATE files SET media_key = ? WHERE item_id = ?', [key, id]);
          }
          continue;
        }
        if (path.isNotEmpty && !_storageThere(path)) {
          await hold(r); // its card is not in the phone right now
          continue;
        }
        final e = await DriveMedia.entry(id);
        if (e != null && e.remoteId.isNotEmpty && e.state == 'in_drive') {
          await _adopt(id, path, remember: false);
        } else {
          await _drop(id, '${r['thumb'] ?? ''}');
        }
      }
    }
    await DriveMedia.sweepDeleted();
    LibraryRepo.instance.revision.value++;
    // After a restore: numbers remembered as "never list again" since then
    // belonged to the other phone too. (Not when the numbers were only
    // re-checked on the same phone.)
    if (Prefs.flag('gallery_skip_stale')) {
      try {
        await db.delete('gallery_skip');
      } catch (_) {}
      await Prefs.setFlag('gallery_skip_stale', false);
    }
    await Prefs.setFlag('gallery_rekey_due', false);
  }

  /// A gallery photo whose original left the phone but is safe in Drive
  /// becomes an ordinary BYTE photo: its place (for bringing it back from
  /// Drive) is now inside BYTE's own folder.
  static Future<void> _adopt(String itemId, String oldPath, {bool remember = true}) async {
    final dir = await LibraryRepo.instance.filesDir();
    final own = p.join(dir.path, '$itemId${p.extension(oldPath).toLowerCase()}');
    final db = AppDb.instance.db;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.transaction((txn) async {
      final key = await txn.rawQuery('SELECT media_key FROM files WHERE item_id = ?', [itemId]);
      // [remember] false after a restore: that number means nothing on this phone.
      if (remember && key.isNotEmpty && '${key.first['media_key']}'.isNotEmpty) {
        await txn.rawInsert('INSERT OR IGNORE INTO gallery_skip (media_key) VALUES (?)', ['${key.first['media_key']}']);
      }
      await txn.rawUpdate("UPDATE files SET path = ?, media_key = '' WHERE item_id = ?", [own, itemId]);
      await txn.rawUpdate('UPDATE drive_media SET local = 0, updated_at = ? WHERE item_id = ?', [now, itemId]);
    });
  }

  /// The private space takes a gallery photo over: BYTE makes a copy of its
  /// own and stops listing the gallery one. Returns the gallery number and
  /// where the original is (so Android can be asked to delete it), or null
  /// when the photo could not be copied — then nothing was changed.
  static Future<(String, String)?> takeOver(String itemId) async {
    final db = AppDb.instance.db;
    final rows = await db.rawQuery('SELECT path, media_key FROM files WHERE item_id = ?', [itemId]);
    if (rows.isEmpty) return null;
    final old = '${rows.first['path'] ?? ''}';
    final key = '${rows.first['media_key'] ?? ''}';
    if (key.isEmpty || old.isEmpty) return null;
    final src = File(old);
    final dir = await LibraryRepo.instance.filesDir();
    final own = p.join(dir.path, '$itemId${p.extension(old).toLowerCase()}');
    try {
      if (!await src.exists()) return null;
      await src.copy(own);
      if (await File(own).length() != await src.length()) throw const FileSystemException('copy is not complete');
    } catch (e) {
      debugPrint('[gallery] take over $itemId: $e');
      try {
        final f = File(own);
        if (await f.exists()) await f.delete();
      } catch (_) {}
      return null;
    }
    // After a restore the number may belong to another photo on this phone:
    // then it is not remembered (and nothing is deleted through it).
    final trusted = !keysUntrusted;
    await db.transaction((txn) async {
      if (trusted) await txn.rawInsert('INSERT OR IGNORE INTO gallery_skip (media_key) VALUES (?)', [key]);
      await txn.rawUpdate("UPDATE files SET path = ?, media_key = '' WHERE item_id = ?", [own, itemId]);
    });
    return (key, old);
  }

  // ───────────── deleting originals ─────────────

  /// Deletes originals from the phone. [keyToPath]: gallery number → the
  /// file BYTE believes it is. The native side only offers a number to the
  /// user when the gallery still lists THAT file under it, so a stale number
  /// can never delete someone else's photo. Android asks once for the whole
  /// list. True when the user agreed and they are gone.
  static Future<bool> deleteOriginals(Map<String, String> keyToPath) async {
    if (!Platform.isAndroid || keyToPath.isEmpty) return true;
    if (keysUntrusted) return false; // restored vault, gallery not asked yet
    try {
      return await _ch.invokeMethod<bool>('delete', {
            'keys': keyToPath.keys.toList(),
            'paths': keyToPath.values.toList(),
          }) ??
          false;
    } catch (e) {
      debugPrint('[gallery] delete: $e');
      return false;
    }
  }

  /// Android's ready-made small picture of a gallery photo or video, written
  /// to [out] (a .jpg). Much quicker than reading the whole original.
  static Future<bool> thumb(String mediaKey, String out) async {
    if (!Platform.isAndroid || mediaKey.isEmpty) return false;
    try {
      return await _ch.invokeMethod<bool>('thumb', {'key': mediaKey, 'out': out, 'size': 480}) ?? false;
    } catch (_) {
      return false;
    }
  }

  // ───────────── free up space ─────────────

  static const _freeableSql = '''
    SELECT d.item_id, d.remote_id, d.size, f.path, f.thumb, f.media_key
    FROM drive_media d JOIN files f ON f.item_id = d.item_id JOIN items i ON i.id = d.item_id
    WHERE d.trash = 0 AND d.state = 'in_drive' AND d.local = 1 AND d.keep = 0 AND d.remote_id != ''
      AND f.media_key != '' AND f.thumb != '' AND i.deleted_at IS NULL
      AND f.index_status NOT IN ('pending','working')
    ORDER BY d.size DESC''';

  /// Gallery photos and videos that are safely in Drive and still on the
  /// phone: how many, and how many bytes freeing them would give back.
  static Future<(int, int)> freeable() async {
    try {
      final rows = await AppDb.instance.db.rawQuery('SELECT COUNT(*) AS n, COALESCE(SUM(size), 0) AS b FROM ($_freeableSql)');
      return ((rows.first['n'] as int?) ?? 0, (rows.first['b'] as int?) ?? 0);
    } catch (_) {
      return (0, 0);
    }
  }

  /// Frees up to [batch] of them (biggest first). For each one BYTE first asks
  /// Drive "do you really have this exact file?" — same size, not in the
  /// Trash — and makes sure a preview is kept. Then Android shows ONE dialog
  /// for the whole batch. Only after Android says they are deleted does BYTE
  /// mark them as living in Drive.
  static Future<FreeUpResult> freeUp({int batch = 200, void Function(int done, int total)? onProgress}) async {
    if (!Platform.isAndroid) return const FreeUpResult();
    if (keysUntrusted) return FreeUpResult(checking: true, left: (await freeable()).$1);
    final db = AppDb.instance.db;
    final rows = await db.rawQuery('$_freeableSql LIMIT ?', [batch]);
    if (rows.isEmpty) return const FreeUpResult();
    if (!await DriveMedia.isOnline()) return FreeUpResult(offline: true, left: (await freeable()).$1);

    final safe = <Map<String, Object?>>[];
    var done = 0;
    for (final r in rows) {
      onProgress?.call(done++, rows.length);
      final path = '${r['path']}';
      final thumb = '${r['thumb'] ?? ''}';
      final f = File(path);
      if (!f.existsSync()) continue;
      if (thumb.isEmpty || !File(thumb).existsSync()) continue; // keep something to show
      try {
        final remote = await CloudSync.mediaSize('${r['remote_id']}');
        if (remote == null || remote != await f.length()) {
          // Drive does not have this exact file (changed since, or removed there): send it again, free it later.
          // (A copy that no longer matches goes to Drive's Trash.)
          if (remote != null) await db.rawInsert('INSERT OR IGNORE INTO private_trash (remote_id) VALUES (?)', ['${r['remote_id']}']);
          await db.update(
            'drive_media',
            {'state': 'queued', 'remote_id': '', 'updated_at': DateTime.now().millisecondsSinceEpoch},
            where: 'item_id = ?',
            whereArgs: [r['item_id']],
          );
          continue;
        }
        safe.add(r);
      } on CloudNeedsSignIn {
        return FreeUpResult(offline: true, left: (await freeable()).$1);
      } catch (e) {
        debugPrint('[gallery] free check: $e');
      }
    }
    onProgress?.call(rows.length, rows.length);
    if (safe.isEmpty) {
      unawaited(DriveMedia.kick());
      return FreeUpResult(left: (await freeable()).$1);
    }

    final ok = await deleteOriginals({for (final r in safe) '${r['media_key']}': '${r['path']}'});

    // Whatever Android said: record exactly what really left the phone.
    var freed = 0;
    var bytes = 0;
    for (final r in safe) {
      final path = '${r['path']}';
      if (File(path).existsSync()) continue; // Android kept it: leave everything as it was
      await _adopt('${r['item_id']}', path);
      freed++;
      bytes += (r['size'] as int?) ?? 0;
    }
    if (freed == 0 && !ok) return FreeUpResult(declined: true, left: (await freeable()).$1);
    DriveMedia.changed.value++;
    await DriveMedia.refresh();
    LibraryRepo.instance.revision.value++;
    await _refreshState();
    return FreeUpResult(freed: freed, bytes: bytes, left: (await freeable()).$1);
  }
}
