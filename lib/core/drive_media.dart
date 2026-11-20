import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:workmanager/workmanager.dart';

import '../features/library/library_item.dart';
import 'cloud_sync.dart';
import 'db.dart';
import 'gallery.dart';
import 'private_names.dart';

/// What the Drive pill in the Library shows.
class DriveState {
  const DriveState({
    this.online = true,
    this.connected = false,
    this.uploading = false,
    this.progress = 0,
    this.waiting = 0,
    this.waitingBig = false,
    this.justFinished = false,
  });

  /// The phone has working internet.
  final bool online;

  /// Signed in to Google Drive.
  final bool connected;
  final bool uploading;

  /// 0..1 across the current batch.
  final double progress;

  /// Photos/videos not in Drive yet.
  final int waiting;

  /// One of those is over 50 MB (the red pill offers Wi-Fi first).
  final bool waitingBig;

  /// A batch just completed (the pill gives a small tick for a moment).
  final bool justFinished;

  bool get good => online && connected;

  DriveState copyWith({bool? online, bool? connected, bool? uploading, double? progress, int? waiting, bool? waitingBig, bool? justFinished}) => DriveState(
        online: online ?? this.online,
        connected: connected ?? this.connected,
        uploading: uploading ?? this.uploading,
        progress: progress ?? this.progress,
        waiting: waiting ?? this.waiting,
        waitingBig: waitingBig ?? this.waitingBig,
        justFinished: justFinished ?? this.justFinished,
      );
}

/// One photo/video's place in Drive.
class DriveEntry {
  const DriveEntry({required this.itemId, required this.remoteId, required this.state, required this.local, required this.keep, required this.size, required this.error});
  final String itemId;
  final String remoteId;

  /// queued | uploading | in_drive | failed
  final String state;

  /// The full file is on the phone.
  final bool local;

  /// "Keep on this phone" — never freed.
  final bool keep;
  final int size;
  final String error;

  bool get inDrive => state == 'in_drive' && remoteId.isNotEmpty;

  static DriveEntry fromRow(Map<String, Object?> r) => DriveEntry(
        itemId: '${r['item_id']}',
        remoteId: '${r['remote_id'] ?? ''}',
        state: '${r['state'] ?? 'queued'}',
        local: (r['local'] as int? ?? 1) == 1,
        keep: (r['keep'] as int? ?? 0) == 1,
        size: (r['size'] as int?) ?? 0,
        error: '${r['error'] ?? ''}',
      );
}

/// Photos and videos live in Google Drive, not on the phone.
///
/// Send a photo to BYTE → it's queued → uploaded on any network (Wi-Fi or
/// data) → once Drive confirms and BYTE has finished reading it, BYTE's own
/// copy is deleted and only the small preview stays. Opening it later brings
/// the full file back for a day. Nothing is deleted before Drive has it.
class DriveMedia {
  DriveMedia._();

  static const bigBytes = 50 * 1024 * 1024;
  static const _task = 'byte.drive_media';
  static const _ch = MethodChannel('byte/cloud');

  /// Wait this long after adding before freeing the phone copy (share
  /// screens and the AI still read the file in the first minutes).
  static const settleAfter = Duration(minutes: 10);

  /// A full copy brought back for viewing stays this long.
  static const keepViewed = Duration(hours: 24);

  static final ValueNotifier<DriveState> state = ValueNotifier(const DriveState());

  /// Bumped when an item's Drive status changes (the viewer listens).
  static final ValueNotifier<int> changed = ValueNotifier(0);

  static bool _tableReady = false;
  static bool _needsSignIn = false;
  static bool _pumping = false;
  static bool _again = false;
  static bool _listening = false;
  static Timer? _finishTimer;

  /// Downloads in flight, per item: two callers (viewer + indexer, preview +
  /// Share) share one download instead of writing the same `.part` twice.
  static final Map<String, Future<String?>> _bringing = {};

  /// The main app and the background task (another isolate, same vault) must
  /// never work the queue at the same time: a lease row in the vault decides.
  static final String _owner = '${DateTime.now().microsecondsSinceEpoch}-${Object().hashCode}';
  static const _lease = Duration(minutes: 30);

  // ───────────── table ─────────────

  static Future<void> _ensure() async {
    if (_tableReady) return;
    await AppDb.instance.db.execute('''
      CREATE TABLE IF NOT EXISTS drive_media (
        item_id    TEXT PRIMARY KEY,
        remote_id  TEXT NOT NULL DEFAULT '',
        state      TEXT NOT NULL DEFAULT 'queued',
        local      INTEGER NOT NULL DEFAULT 1,
        keep       INTEGER NOT NULL DEFAULT 0,
        size       INTEGER NOT NULL DEFAULT 0,
        name       TEXT NOT NULL DEFAULT '',
        touched_at INTEGER NOT NULL DEFAULT 0,
        trash      INTEGER NOT NULL DEFAULT 0,
        tries      INTEGER NOT NULL DEFAULT 0,
        error      TEXT NOT NULL DEFAULT '',
        added_at   INTEGER NOT NULL DEFAULT 0,
        updated_at INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await AppDb.instance.db.execute('CREATE TABLE IF NOT EXISTS drive_media_lock (id INTEGER PRIMARY KEY, owner TEXT NOT NULL, until INTEGER NOT NULL)');
    _tableReady = true;
  }

  /// Take (or renew) the lease. False when the other isolate holds it.
  static Future<bool> _lock() async {
    final db = AppDb.instance.db;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.rawInsert('INSERT OR IGNORE INTO drive_media_lock (id, owner, until) VALUES (1, ?, 0)', [_owner]);
    final n = await db.rawUpdate('UPDATE drive_media_lock SET owner = ?, until = ? WHERE id = 1 AND (until < ? OR owner = ?)', [_owner, now + _lease.inMilliseconds, now, _owner]);
    return n == 1;
  }

  static Future<void> _unlock() async {
    try {
      await AppDb.instance.db.rawUpdate('UPDATE drive_media_lock SET until = 0 WHERE id = 1 AND owner = ?', [_owner]);
    } catch (_) {}
  }

  static Future<DriveEntry?> entry(String itemId) async {
    await _ensure();
    final rows = await AppDb.instance.db.query('drive_media', where: 'item_id = ?', whereArgs: [itemId], limit: 1);
    return rows.isEmpty ? null : DriveEntry.fromRow(rows.first);
  }

  // ───────────── start-up and network ─────────────

  /// Main app start: listen for the network, refresh the pill, upload.
  static Future<void> init() async {
    if (_listening || !Platform.isAndroid) return;
    _listening = true;
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'net') {
        final online = call.arguments == true;
        final was = state.value.online;
        state.value = state.value.copyWith(online: online);
        if (online && !was) unawaited(kick());
      }
      return null;
    });
    try {
      await _ch.invokeMethod('watchNetwork');
    } catch (_) {}
    CloudSync.changed.addListener(_onCloudChanged);
    await refresh();
    unawaited(kick());
  }

  static void _onCloudChanged() {
    _needsSignIn = false; // signed in (or out) again — ask afresh
    final was = state.value.connected;
    refresh().then((_) {
      if (!was && state.value.connected) unawaited(kick());
    });
  }

  static Future<bool> isOnline() async {
    if (!Platform.isAndroid) return true;
    try {
      return await _ch.invokeMethod<bool>('isOnline') ?? true;
    } catch (_) {
      return true;
    }
  }

  /// Re-read everything the pill shows.
  static Future<void> refresh() async {
    try {
      await _ensure();
      final online = await isOnline();
      final connected = await CloudSync.connected() && !_needsSignIn;
      // Things in the bin are not "waiting": they go up again only if restored.
      final rows = await AppDb.instance.db.rawQuery(
        "SELECT COUNT(*) AS n, MAX(d.size) AS big FROM drive_media d JOIN items i ON i.id = d.item_id "
        "WHERE d.trash = 0 AND d.state != 'in_drive' AND i.deleted_at IS NULL "
        // A private file waits (unseen) until it is locked.
        "AND (i.private = 0 OR EXISTS (SELECT 1 FROM files f WHERE f.item_id = d.item_id AND f.path LIKE '%$sealedExt'))",
      );
      final n = (rows.first['n'] as int?) ?? 0;
      final big = (rows.first['big'] as int?) ?? 0;
      state.value = state.value.copyWith(online: online, connected: connected, waiting: n, waitingBig: big > bigBytes);
    } catch (e) {
      debugPrint('[drive] refresh: $e');
    }
  }

  // ───────────── queue ─────────────

  /// A photo/video just arrived (picker, share, camera). Uploads on its own.
  static Future<void> queue(LibraryItem it) async {
    if (it.kind != LibraryKind.photo && it.kind != LibraryKind.video) return;
    if (it.path.isEmpty) return;
    await _ensure();
    final now = DateTime.now().millisecondsSinceEpoch;
    await AppDb.instance.db.rawInsert(
      'INSERT OR IGNORE INTO drive_media (item_id, state, local, size, name, added_at, updated_at) VALUES (?, ?, 1, ?, ?, ?, ?)',
      [it.id, 'queued', it.size, p.basename(it.path), now, now],
    );
    changed.value++;
    await refresh();
    unawaited(kick());
  }

  /// Gallery backup was switched on (or new gallery photos arrived while it
  /// is on): every photo and video BYTE lists from the phone's gallery that
  /// is not on its way to Drive yet is queued. They are never removed from
  /// the phone by BYTE itself — only "Free up space" does that, with
  /// Android's own confirmation.
  static Future<void> queueGallery() async {
    try {
      await _ensure();
      final now = DateTime.now().millisecondsSinceEpoch;
      await AppDb.instance.db.rawInsert('''
        INSERT OR IGNORE INTO drive_media (item_id, state, local, size, name, added_at, updated_at)
        SELECT i.id, 'queued', 1, f.size, i.id, 0, ?
        FROM items i JOIN files f ON f.item_id = i.id
        WHERE i.deleted_at IS NULL AND i.type IN ('photo','video') AND f.path != '' AND f.media_key != ''
      ''', [now]);
      changed.value++;
      await refresh();
      unawaited(kick());
    } catch (e) {
      debugPrint('[drive] queue gallery: $e');
    }
  }

  /// Gallery backup was switched off: gallery photos still waiting are no
  /// longer sent. Copies already in Drive stay there.
  static Future<void> unqueueGallery() async {
    try {
      await _ensure();
      await AppDb.instance.db.rawDelete(
        "DELETE FROM drive_media WHERE remote_id = '' AND state IN ('queued','failed','uploading') "
        "AND item_id IN (SELECT item_id FROM files WHERE media_key != '')",
      );
      changed.value++;
      await refresh();
    } catch (e) {
      debugPrint('[drive] unqueue gallery: $e');
    }
  }

  /// Storage screen: "Move to Drive" for everything already in the Library.
  /// Returns how many were added and how many bytes that will free.
  /// (BYTE's own copies only — the phone's gallery has its own switch.)
  static Future<(int, int)> queueAllExisting() async {
    await _ensure();
    final db = AppDb.instance.db;
    final rows = await db.rawQuery('''
      SELECT i.id, f.path, f.size FROM items i JOIN files f ON f.item_id = i.id
      WHERE i.deleted_at IS NULL AND i.type IN ('photo','video') AND f.path != '' AND f.media_key = ''
        AND i.id NOT IN (SELECT item_id FROM drive_media)
    ''');
    final now = DateTime.now().millisecondsSinceEpoch;
    var n = 0;
    var bytes = 0;
    for (final r in rows) {
      final path = '${r['path']}';
      if (!File(path).existsSync()) continue;
      final size = (r['size'] as int?) ?? 0;
      await db.rawInsert(
        // Old items are settled already: added_at 0 lets them be freed right after upload.
        'INSERT OR IGNORE INTO drive_media (item_id, state, local, size, name, added_at, updated_at) VALUES (?, ?, 1, ?, ?, 0, ?)',
        ['${r['id']}', 'queued', size, p.basename(path), now],
      );
      n++;
      bytes += size;
    }
    changed.value++;
    await refresh();
    unawaited(kick());
    return (n, bytes);
  }

  /// How much "Move to Drive" would free (photos/videos only on the phone).
  static Future<(int, int)> movable() async {
    await _ensure();
    // New ones go to Drive by themselves; these are the ones from before.
    final rows = await AppDb.instance.db.rawQuery('''
      SELECT f.path, f.size FROM items i JOIN files f ON f.item_id = i.id
      WHERE i.deleted_at IS NULL AND i.type IN ('photo','video') AND f.path != '' AND f.media_key = ''
        AND i.id NOT IN (SELECT item_id FROM drive_media)
    ''');
    var n = 0;
    var b = 0;
    for (final r in rows) {
      if (!File('${r['path']}').existsSync()) continue;
      n++;
      b += (r['size'] as int?) ?? 0;
    }
    return (n, b);
  }

  /// Space already freed on the phone.
  static Future<(int, int)> freed() async {
    await _ensure();
    final rows = await AppDb.instance.db.rawQuery('SELECT COUNT(*) AS n, COALESCE(SUM(size), 0) AS b FROM drive_media WHERE local = 0 AND trash = 0');
    return ((rows.first['n'] as int?) ?? 0, (rows.first['b'] as int?) ?? 0);
  }

  /// Deleted for good in BYTE (the bin was emptied, or its 30 days ran out)
  /// → Drive's Trash (now, or when the internet is back). Moving something
  /// to BYTE's bin does NOT call this: the Drive copy stays so a restore
  /// brings everything back.
  static Future<void> onDeleted(String itemId) async {
    await _ensure();
    final db = AppDb.instance.db;
    final e = await entry(itemId);
    if (e == null) return;
    if (e.remoteId.isEmpty) {
      await db.delete('drive_media', where: 'item_id = ?', whereArgs: [itemId]);
    } else {
      await db.update('drive_media', {'trash': 1, 'updated_at': DateTime.now().millisecondsSinceEpoch}, where: 'item_id = ?', whereArgs: [itemId]);
    }
    await refresh();
    unawaited(kick());
  }

  /// Items were just deleted for good (any number): rows that never reached
  /// Drive are dropped, the rest are marked so their Drive copies go to
  /// Drive's Trash — now, or when the internet is back.
  static Future<void> sweepDeleted() async {
    try {
      await _ensure();
      final db = AppDb.instance.db;
      await db.rawDelete("DELETE FROM drive_media WHERE remote_id = '' AND item_id NOT IN (SELECT id FROM items)");
      await db.rawUpdate(
        'UPDATE drive_media SET trash = 1, updated_at = ? WHERE trash = 0 AND item_id NOT IN (SELECT id FROM items)',
        [DateTime.now().millisecondsSinceEpoch],
      );
      changed.value++;
      await refresh();
      unawaited(kick());
    } catch (e) {
      debugPrint('[drive] sweep: $e');
    }
  }

  /// Back from the bin. The bin never touches the Drive copy, so normally
  /// there is nothing to do. But an older BYTE marked the copy for Drive's
  /// Trash the moment you deleted: take that mark back if it has not happened
  /// yet, and put a photo or video that is not in Drive on its way there again.
  static Future<void> onRestored(Iterable<LibraryItem> items) async {
    final media = [
      for (final it in items)
        // A gallery photo goes to Drive only while "Copy gallery photos to Drive" is on.
        if ((it.kind == LibraryKind.photo || it.kind == LibraryKind.video) && it.path.isNotEmpty && (!it.fromGallery || Gallery.backup)) it,
    ];
    if (media.isEmpty) return;
    try {
      await _ensure();
      final db = AppDb.instance.db;
      final now = DateTime.now().millisecondsSinceEpoch;
      for (final it in media) {
        await db.rawUpdate('UPDATE drive_media SET trash = 0 WHERE item_id = ? AND trash = 1', [it.id]);
        // Adds a row only when there is none (same statement as [queue]).
        await db.rawInsert(
          'INSERT OR IGNORE INTO drive_media (item_id, state, local, size, name, added_at, updated_at) VALUES (?, ?, 1, ?, ?, ?, ?)',
          [it.id, 'queued', it.size, p.basename(it.path), now, now],
        );
      }
      changed.value++;
      await refresh();
      unawaited(kick());
    } catch (e) {
      debugPrint('[drive] restored: $e');
    }
  }

  /// "Keep on this phone" on/off. On → brings the full file back now.
  static Future<bool> setKeep(LibraryItem it, bool keep) async {
    await _ensure();
    await AppDb.instance.db.update('drive_media', {'keep': keep ? 1 : 0, 'updated_at': DateTime.now().millisecondsSinceEpoch}, where: 'item_id = ?', whereArgs: [it.id]);
    changed.value++;
    if (keep) return await ensureLocal(it) != null;
    unawaited(kick());
    return true;
  }

  // ───────────── the full file, when you need it ─────────────

  /// Make sure the full file is on the phone (Share, Open with, Fix photo,
  /// AI). Downloads it back from Drive if needed; it stays for a day.
  /// Returns the path, or null when it can't be had (offline / signed out).
  static Future<String?> ensureLocal(LibraryItem it, {void Function(int got, int total)? onProgress}) async {
    if (it.path.isEmpty) return null;
    final busy = _bringing[it.id];
    if (busy != null) return busy; // already on its way (the second caller's progress is not shown)
    final f = File(it.path);
    if (await f.exists()) {
      await _touch(it.id, DateTime.now().millisecondsSinceEpoch);
      return it.path;
    }
    // A gallery photo whose original is not on this phone (it was removed,
    // or the vault was restored on a new phone). BYTE never writes into the
    // gallery's own folders: its Drive copy goes into BYTE's own folder — the
    // same place the gallery check gives the photo when it adopts it.
    var target = f;
    if (it.mediaKey.isNotEmpty) {
      unawaited(Gallery.checkMissingNow());
      target = File(p.join((await getApplicationSupportDirectory()).path, 'files', '${it.id}${p.extension(it.path).toLowerCase()}'));
      if (await target.exists()) return target.path;
    }
    final job = _bringBack(it, target, onProgress);
    _bringing[it.id] = job;
    try {
      return await job;
    } finally {
      _bringing.remove(it.id);
    }
  }

  static Future<String?> _bringBack(LibraryItem it, File f, void Function(int got, int total)? onProgress) async {
    final e = await entry(it.id);
    if (e == null || e.remoteId.isEmpty) return null;
    try {
      await f.parent.create(recursive: true);
      await CloudSync.downloadMedia(e.remoteId, f, onProgress: onProgress);
      final now = DateTime.now().millisecondsSinceEpoch;
      // (For a gallery photo "local" speaks of the original in the gallery, which is still not there.)
      if (it.mediaKey.isEmpty) {
        await AppDb.instance.db.update('drive_media', {'local': 1, 'touched_at': now, 'updated_at': now}, where: 'item_id = ?', whereArgs: [it.id]);
      }
      changed.value++;
      return f.path;
    } catch (err) {
      debugPrint('[drive] bring back: $err');
      return null;
    }
  }

  /// In use now: keep the phone copy for [keepViewed]. The file is here, so
  /// `local` is true whatever the row said (e.g. after a restore).
  static Future<void> _touch(String id, int now) async {
    try {
      await _ensure();
      await AppDb.instance.db.update('drive_media', {'touched_at': now, 'local': 1}, where: 'item_id = ?', whereArgs: [id]);
    } catch (_) {}
  }

  /// Token for streaming a video straight from Drive.
  static Future<String?> token() => CloudSync.accessToken();

  // ───────────── the worker ─────────────

  /// Upload what's waiting, trash what was deleted, free what's safe.
  /// Safe to call any time, as often as you like.
  static Future<void> kick({bool background = false}) async {
    if (_pumping) {
      _again = true;
      return;
    }
    _pumping = true;
    var locked = false;
    try {
      // A restore is swapping the vault and repointing paths: hands off.
      if (CloudSync.restoring) return;
      await _ensure();
      locked = await _lock();
      if (!locked) return; // the other isolate is on it
      var rounds = 0;
      do {
        _again = false;
        await _pump(background: background);
      } while (_again && ++rounds < 5);
    } catch (e) {
      debugPrint('[drive] pump: $e');
    } finally {
      if (locked) await _unlock();
      _pumping = false;
      await refresh();
    }
  }

  static Future<void> _pump({required bool background}) async {
    await _ensure();
    final db = AppDb.instance.db;
    final online = await isOnline();
    final connected = await CloudSync.connected();
    if (!online || !connected) {
      if (!online) await _scheduleBackground();
      return;
    }

    // 1. Deleted for good in BYTE → Drive Trash. Rows whose item no longer
    //    exists (the bin's 30 days ran out) count as deleted too.
    await db.rawUpdate('UPDATE drive_media SET trash = 1 WHERE trash = 0 AND item_id NOT IN (SELECT id FROM items)');
    for (final r in await db.query('drive_media', where: 'trash = 1')) {
      final e = DriveEntry.fromRow(r);
      try {
        if (e.remoteId.isNotEmpty) await CloudSync.trashMedia(e.remoteId);
        await db.delete('drive_media', where: 'item_id = ?', whereArgs: [e.itemId]);
      } catch (err) {
        if (err is CloudNeedsSignIn) return;
        debugPrint('[drive] trash: $err');
      }
    }

    // 2. Upload, oldest first.
    final todo = await db.rawQuery('''
      SELECT d.*, f.path, f.media_key FROM drive_media d JOIN files f ON f.item_id = d.item_id JOIN items i ON i.id = d.item_id
      WHERE d.trash = 0 AND d.state IN ('queued','failed','uploading') AND i.deleted_at IS NULL
        AND (i.private = 0 OR f.path LIKE '%$sealedExt')
      ORDER BY (f.media_key != '') ASC, d.added_at ASC
    ''');
    // What you add to BYTE yourself goes first and on any network. The gallery
    // (it can be thousands of photos) waits behind it and follows "Wi-Fi only".
    if (todo.isNotEmpty) {
      final total = todo.fold<int>(0, (a, r) => a + ((r['size'] as int?) ?? 0));
      var done = 0;
      state.value = state.value.copyWith(uploading: true, progress: 0, justFinished: false);
      var ok = 0;
      for (final r in todo) {
        if ('${r['media_key'] ?? ''}'.isNotEmpty) {
          // Something of your own was added meanwhile: start the list again, so it goes first.
          // (Any other wake-up call changes nothing here.)
          if (_again) {
            // (Locked private files count only once their key is in Drive; until then they wait anyway.)
            final keyUp = await CloudSync.privateKeyInDrive();
            final mine = await db.rawQuery(
              "SELECT 1 FROM drive_media d JOIN files f ON f.item_id = d.item_id JOIN items i ON i.id = d.item_id "
              "WHERE d.trash = 0 AND d.state = 'queued' AND f.media_key = '' AND i.deleted_at IS NULL "
              "AND (i.private = 0 OR (? = 1 AND f.path LIKE '%$sealedExt')) LIMIT 1",
              [keyUp ? 1 : 0],
            );
            if (mine.isNotEmpty) break;
          }
          // Asked for each photo: a long batch can outlast the Wi-Fi it started on.
          if (await CloudSync.wifiOnly() && !await CloudSync.onWifi()) continue;
        }
        if (!await _lock()) break; // renew the lease per file
        final e = DriveEntry.fromRow(r);
        // Still wanted? "Copy gallery photos" may have been switched off, or
        // the item deleted, since this list was made.
        // Asked again now, not taken from the list made earlier: deleted,
        // switched off, made private, locked or given another file since then?
        final fresh = await db.rawQuery(
          "SELECT f.path, f.media_key, i.private FROM drive_media d JOIN files f ON f.item_id = d.item_id JOIN items i ON i.id = d.item_id "
          "WHERE d.item_id = ? AND d.trash = 0 AND d.state != 'in_drive' AND i.deleted_at IS NULL AND (i.private = 0 OR f.path LIKE '%$sealedExt')",
          [e.itemId],
        );
        if (fresh.isEmpty) continue;
        // A locked private file goes up only once the key that opens it is in
        // Drive too (inside the vault copy) — else Drive would hold a file
        // nobody could ever open.
        if (fresh.first['private'] == 1 && !await CloudSync.privateKeyInDrive()) continue;
        final path = '${fresh.first['path']}';
        final mediaKey = '${fresh.first['media_key'] ?? ''}';
        final f = File(path);
        if (!await f.exists()) {
          // Nothing on the phone and nothing in Drive: there is nothing to upload,
          // so stop counting it as "waiting" (the pill would never settle).
          if (e.remoteId.isEmpty) {
            await db.delete('drive_media', where: 'item_id = ?', whereArgs: [e.itemId]);
          } else {
            await db.update('drive_media', {'state': 'in_drive', 'local': 0, 'error': '', 'updated_at': DateTime.now().millisecondsSinceEpoch}, where: 'item_id = ?', whereArgs: [e.itemId]);
          }
          changed.value++;
          continue;
        }
        await db.update('drive_media', {'state': 'uploading', 'updated_at': DateTime.now().millisecondsSinceEpoch}, where: 'item_id = ?', whereArgs: [e.itemId]);
        changed.value++;
        // A gallery photo keeps its own name on the phone, but in Drive it is
        // named after its BYTE id: two gallery photos may share a file name.
        final driveName = mediaKey.isEmpty ? p.basename(f.path) : '${e.itemId}${p.extension(f.path).toLowerCase()}';
        try {
          final id = await CloudSync.uploadMedia(f, name: driveName, onProgress: (sent, _) {
            final pr = total == 0 ? 1.0 : ((done + sent) / total).clamp(0.0, 1.0);
            state.value = state.value.copyWith(uploading: true, progress: pr.toDouble());
          });
          // Still the same file, and still allowed up? (It may have been made
          // private, locked or replaced while it was uploading.)
          final same = await db.rawQuery(
            "SELECT 1 FROM files f JOIN items i ON i.id = f.item_id WHERE f.item_id = ? AND f.path = ? AND (i.private = 0 OR f.path LIKE '%$sealedExt')",
            [e.itemId, path],
          );
          if (same.isEmpty) {
            try {
              await CloudSync.trashMedia(id);
            } catch (err) {
              debugPrint('[drive] trash after upload: $err');
              await db.rawInsert('INSERT OR IGNORE INTO private_trash (remote_id) VALUES (?)', [id]);
            }
            _again = true;
            continue;
          }
          final size = await f.length();
          // `name` follows the file (Shrink photos may have renamed it) — restore matches on it.
          final n = await db.update('drive_media', {'remote_id': id, 'state': 'in_drive', 'size': size, 'name': driveName, 'error': '', 'tries': 0, 'updated_at': DateTime.now().millisecondsSinceEpoch}, where: 'item_id = ? AND trash = 0', whereArgs: [e.itemId]);
          if (n == 0) {
            // Deleted in BYTE while it was uploading: its Drive copy goes to the Trash too.
            try {
              await CloudSync.trashMedia(id);
            } catch (err) {
              debugPrint('[drive] trash after upload: $err');
            }
          }
          done += e.size;
          ok++;
          changed.value++;
        } catch (err) {
          debugPrint('[drive] upload ${e.itemId}: $err');
          await db.rawUpdate("UPDATE drive_media SET state = 'failed', tries = tries + 1, error = ?, updated_at = ? WHERE item_id = ?", ['$err', DateTime.now().millisecondsSinceEpoch, e.itemId]);
          changed.value++;
          if (err is CloudNeedsSignIn) {
            // A token can simply have expired: one silent retry first. Only
            // when Google really has nothing for us does the pill go red
            // (and only on screen — in the background there is no one to ask).
            if (!background && await CloudSync.accessToken() == null) _needsSignIn = true;
            break;
          }
          if (!await isOnline()) {
            await _scheduleBackground();
            break;
          }
        }
      }
      state.value = state.value.copyWith(uploading: false, progress: 1, justFinished: ok > 0);
      if (ok > 0) {
        _finishTimer?.cancel();
        _finishTimer = Timer(const Duration(milliseconds: 1800), () => state.value = state.value.copyWith(justFinished: false, progress: 0));
      }
    }

    // 3. Free the phone copy where it's safe.
    await _free();
  }

  static const _freeSql = '''
      SELECT d.*, f.path, f.thumb, f.index_status FROM drive_media d JOIN files f ON f.item_id = d.item_id JOIN items i ON i.id = d.item_id
      WHERE f.media_key = '' AND d.trash = 0 AND d.state = 'in_drive' AND d.local = 1 AND d.keep = 0 AND d.remote_id != '' AND i.deleted_at IS NULL''';

  /// Every rule that must hold for BYTE to drop its own copy of [r].
  static bool _mayFree(Map<String, Object?> r, int now, String filesRoot) {
    final added = (r['added_at'] as int?) ?? 0;
    final touched = (r['touched_at'] as int?) ?? 0;
    if (now - added < settleAfter.inMilliseconds) return false;
    if (touched > 0 && now - touched < keepViewed.inMilliseconds) return false;
    final status = '${r['index_status'] ?? ''}';
    if (status == 'pending' || status == 'working') return false; // BYTE still reading it
    final thumb = '${r['thumb'] ?? ''}';
    if (thumb.isEmpty || !File(thumb).existsSync()) return false; // keep something to show
    final path = '${r['path'] ?? ''}';
    // Only BYTE's own copies, inside <support>/files/ — never anything else.
    return path.isNotEmpty && p.isWithin(filesRoot, path);
  }

  static Future<void> _free() async {
    final db = AppDb.instance.db;
    final filesRoot = p.join((await getApplicationSupportDirectory()).path, 'files');
    var now = DateTime.now().millisecondsSinceEpoch;
    final rows = await db.rawQuery(_freeSql);
    for (final r in rows) {
      final e = DriveEntry.fromRow(r);
      if (!_mayFree(r, now, filesRoot)) continue;
      final path = '${r['path']}';
      try {
        if (!await _lock()) return;
        final f = File(path);
        if (!await f.exists()) {
          // Already gone from the phone (Drive has it — checked when it went up).
          await db.update('drive_media', {'local': 0, 'updated_at': now}, where: 'item_id = ?', whereArgs: [e.itemId]);
          changed.value++;
          continue;
        }
        // Last check before deleting anything: Drive really has THIS file —
        // there, not in the Trash, and the same size as the copy on the phone
        // (a photo changed after upload goes up again first).
        final remote = await CloudSync.mediaSize(e.remoteId);
        final localSize = await f.length();
        if (remote == null || remote != localSize) {
          // (The copy that no longer matches goes to Drive's Trash.)
          if (remote != null) await db.rawInsert('INSERT OR IGNORE INTO private_trash (remote_id) VALUES (?)', [e.remoteId]);
          await db.update('drive_media', {'state': 'queued', 'remote_id': '', 'updated_at': now}, where: 'item_id = ?', whereArgs: [e.itemId]);
          _again = true;
          changed.value++;
          continue;
        }
        // The check took a network round-trip: re-read the row so a photo
        // opened, kept, deleted or re-indexed meanwhile is left alone.
        now = DateTime.now().millisecondsSinceEpoch;
        final fresh = await db.rawQuery('$_freeSql AND d.item_id = ?', [e.itemId]);
        if (fresh.isEmpty || !_mayFree(fresh.first, now, filesRoot) || '${fresh.first['path']}' != path || '${fresh.first['remote_id']}' != e.remoteId) continue;
        await f.delete();
        await db.update('drive_media', {'local': 0, 'updated_at': now}, where: 'item_id = ?', whereArgs: [e.itemId]);
        changed.value++;
      } catch (err) {
        debugPrint('[drive] free ${e.itemId}: $err');
        if (err is CloudNeedsSignIn) return;
      }
    }
  }

  /// When the internet comes back, Android runs the upload even if BYTE is
  /// closed (best effort: if Google sign-in needs a screen, the next open does it).
  static Future<void> _scheduleBackground() async {
    if (!Platform.isAndroid) return;
    try {
      await Workmanager().registerOneOffTask(
        _task,
        _task,
        constraints: Constraints(networkType: NetworkType.connected),
        existingWorkPolicy: ExistingWorkPolicy.replace,
        initialDelay: const Duration(seconds: 5),
      );
    } catch (e) {
      debugPrint('[drive] schedule: $e');
    }
  }

  static const backgroundTask = _task;

  // ───────────── the pill's taps ─────────────

  /// Red pill: fix the first thing that's wrong. Returns what it did:
  /// 'internet' | 'wifi' | 'drive' | 'ok'.
  static Future<String> fixFirst() async {
    final online = await isOnline();
    if (!online) {
      final big = state.value.waitingBig;
      try {
        await _ch.invokeMethod(big ? 'openWifiPanel' : 'openInternetPanel');
      } catch (_) {}
      return big ? 'wifi' : 'internet';
    }
    if (!await CloudSync.connected() || _needsSignIn) return 'drive';
    return 'ok';
  }
}
