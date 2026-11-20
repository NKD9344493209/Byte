import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../features/library/library_item.dart';
import '../features/library/library_repo.dart';
import 'cloud_sync.dart';
import 'db.dart';
import 'drive_media.dart';

/// One thing you shared: a folder in your Google Drive that holds COPIES of
/// what you chose, open to anyone who has its link.
class SharedLink {
  const SharedLink({required this.id, required this.name, required this.folderId, required this.link, required this.canAdd, required this.createdAt, required this.count, this.expiresAt});
  final String id;
  final String name;
  final String folderId;
  final String link;

  /// People with the link may also add files (they land in the Drive folder).
  final bool canAdd;
  final DateTime createdAt;

  /// The day BYTE stops sharing it by itself (null = until you stop it).
  final DateTime? expiresAt;
  final int count;

  static SharedLink fromRow(Map<String, Object?> r) => SharedLink(
        id: '${r['id']}',
        name: '${r['name'] ?? ''}',
        folderId: '${r['folder_id'] ?? ''}',
        link: '${r['link'] ?? ''}',
        canAdd: r['can_add'] == 1,
        createdAt: DateTime.fromMillisecondsSinceEpoch((r['created_at'] as int?) ?? 0),
        expiresAt: r['expires_at'] == null ? null : DateTime.fromMillisecondsSinceEpoch(r['expires_at'] as int),
        count: (r['count'] as int?) ?? 0,
      );
}

/// What [Shares.create] did.
class ShareOutcome {
  const ShareOutcome({required this.link, required this.shared, required this.skipped});
  final SharedLink link;
  final int shared;

  /// Things that could not be put in (private, or the file is neither on the
  /// phone nor in Drive right now).
  final int skipped;
}

/// Share only what you choose: a few photos, a folder, a note.
///
/// BYTE makes a folder in YOUR Google Drive, puts copies of the chosen
/// things into it and opens that one folder to "anyone with the link".
/// Nothing else of yours is reachable through it. Stopping a share sends the
/// folder to Drive's Trash: the link stops working, your own things are
/// untouched (they were copies).
class Shares {
  Shares._();

  static final ValueNotifier<int> changed = ValueNotifier<int>(0);

  static Future<List<SharedLink>> list() async {
    final rows = await AppDb.instance.db.query('shares', orderBy: 'created_at DESC');
    return [for (final r in rows) SharedLink.fromRow(r)];
  }

  /// A file name that is safe in Drive and still says what it is.
  static String _fileName(LibraryItem it, int n) {
    var base = it.displayTitle.replaceAll(RegExp(r'[\\/:*?"<>|\n\r]+'), ' ').trim();
    if (base.isEmpty) base = 'item';
    if (base.length > 60) base = base.substring(0, 60).trim();
    final ext = it.ext;
    final named = ext.isEmpty || base.toLowerCase().endsWith('.$ext') ? base : '$base.$ext';
    // Numbered, so two things with the same name stay two files.
    return '${n.toString().padLeft(3, '0')} $named';
  }

  /// Shares [itemIds] under [name]. [days]: stop by itself after that many
  /// days (null = until you stop it). Needs Google Drive connected and the
  /// internet. Private things are never shared.
  static Future<ShareOutcome> create({
    required String name,
    required List<String> itemIds,
    bool canAdd = false,
    int? days,
    void Function(int done, int total)? onProgress,
    bool Function()? shouldStop,
    void Function(LibraryItem item, String fileId)? onFile,
  }) async {
    final repo = LibraryRepo.instance;
    // Only what is in the Library now: nothing from the bin or the private space.
    final live = await repo.inLibrary(itemIds);
    if (live.isEmpty) throw const HttpException('Nothing could be shared.');
    final folderId = await CloudSync.shareFolderCreate(name);
    var shared = 0;
    var skipped = 0;
    try {
      for (var i = 0; i < itemIds.length; i++) {
        // "Stop" was tapped: the half-made folder is taken away below.
        if (shouldStop?.call() ?? false) throw const HttpException('Stopped.');
        onProgress?.call(i, itemIds.length);
        final it = live.contains(itemIds[i]) ? await repo.get(itemIds[i]) : null;
        if (it == null || it.private || it.sealed) {
          skipped++;
          continue;
        }
        try {
          final fileName = _fileName(it, i + 1);
          if (it.kind == LibraryKind.note) {
            await CloudSync.shareTextInto(folderId, name: '$fileName.txt', text: it.title.trim().isEmpty ? it.body : '${it.title.trim()}\n\n${it.body}');
          } else if (it.kind == LibraryKind.link) {
            await CloudSync.shareTextInto(folderId, name: '$fileName.txt', text: it.url);
          } else if (it.path.isNotEmpty && File(it.path).existsSync()) {
            // (An album shared with a friend remembers each copy: [onFile].)
            onFile?.call(it, await CloudSync.shareUploadInto(folderId, File(it.path), name: fileName));
          } else {
            // Not on the phone: Drive copies its own copy, nothing is uploaded.
            final e = await DriveMedia.entry(it.id);
            if (e == null || !e.inDrive) {
              skipped++;
              continue;
            }
            onFile?.call(it, await CloudSync.shareCopyInto(folderId, remoteId: e.remoteId, name: fileName));
          }
          shared++;
        } on CloudNeedsSignIn {
          rethrow; // the folder is taken away below; the screen says "sign in again"
        } catch (e) {
          debugPrint('[share] ${it.id}: $e');
          if (e is SocketException) rethrow; // offline: stop now, not after every file has timed out
          skipped++;
        }
      }
      onProgress?.call(itemIds.length, itemIds.length);
      if (shared == 0) throw const HttpException('Nothing could be shared.');
      final link = await CloudSync.shareOpen(folderId, canAdd: canAdd);
      final now = DateTime.now();
      final row = <String, Object?>{
        'id': const Uuid().v4(),
        'name': name,
        'folder_id': folderId,
        'link': link,
        'can_add': canAdd ? 1 : 0,
        'created_at': now.millisecondsSinceEpoch,
        'expires_at': days == null ? null : now.add(Duration(days: days)).millisecondsSinceEpoch,
        'count': shared,
      };
      await AppDb.instance.db.insert('shares', row);
      changed.value++;
      return ShareOutcome(link: SharedLink.fromRow(row), shared: shared, skipped: skipped);
    } catch (_) {
      // Half-made: the folder was never opened to anyone; take it away again.
      try {
        await CloudSync.shareStop(folderId);
      } catch (_) {}
      rethrow;
    }
  }

  /// Takes a share back. Needs the internet (the folder must really go).
  static Future<void> stop(SharedLink s) async {
    await CloudSync.shareStop(s.folderId);
    await AppDb.instance.db.delete('shares', where: 'id = ?', whereArgs: [s.id]);
    changed.value++;
  }

  /// Stops the shares whose last day has passed. Safe to call often; one
  /// that cannot be reached now (offline) is tried again next time.
  static Future<void> runDue() async {
    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      final rows = await AppDb.instance.db.query('shares', where: 'expires_at IS NOT NULL AND expires_at <= ?', whereArgs: [now]);
      // (Never a sign-in question from here: this runs by itself.)
      if (rows.isEmpty || !await CloudSync.connected()) return;
      for (final r in rows) {
        try {
          await stop(SharedLink.fromRow(r));
        } catch (e) {
          debugPrint('[share] stop due: $e');
        }
      }
    } catch (e) {
      debugPrint('[share] due: $e');
    }
  }
}
