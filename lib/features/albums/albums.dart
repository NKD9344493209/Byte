import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart' show ConflictAlgorithm;

import '../../core/db.dart';
import '../../core/user_busy.dart';
import '../librarian/librarian_rules.dart';
import '../library/library_item.dart';
import '../library/library_repo.dart';
import 'places.dart';

/// One album BYTE keeps by itself.
class Album {
  const Album({required this.title, required this.count, this.place, this.from, this.until, this.onDay, this.cover, this.source = false});

  /// "Camera", "Bills & receipts", or the days of a busy run ("12–14 Oct 2026").
  final String title;
  final int count;

  /// The sorted album it shows (null for a run of busy days).
  final String? place;

  /// A run of busy days: from (first day) until (the day after the last).
  final DateTime? from;
  final DateTime? until;

  /// "On this day": the camera photos taken on this day of the year in
  /// earlier years.
  final DateTime? onDay;

  /// Its newest picture.
  final LibraryItem? cover;

  /// A "where it came from" album (Camera, Screenshots, WhatsApp…).
  final bool source;

  bool get isDays => from != null;
}

/// BYTE's own filing: every photo, video and document is put into albums
/// without being asked — by where it came from, what kind of paper it is and
/// what it shows. Nothing is moved, renamed or sent anywhere; an album is
/// only a way of looking, so there is nothing to undo.
class Albums {
  Albums._();

  /// Raise this when the rules in places.dart change: everything is sorted again.
  static const version = 3;

  /// Goes up when the albums changed.
  static final ValueNotifier<int> changed = ValueNotifier<int>(0);

  static Timer? _soon;
  static Future<void>? _sorting;
  static bool _cleaned = false;

  /// Call once at start: sorts what is new, now and after every change.
  static void start() {
    LibraryRepo.instance.revision.addListener(_later);
    _later();
  }

  static void _later() {
    _soon?.cancel();
    _soon = Timer(const Duration(milliseconds: 1500), sort);
  }

  /// Sorts everything that is not sorted yet. A call made while a pass is
  /// running gets that pass.
  static Future<void> sort() => _sorting ??= _sort().whenComplete(() => _sorting = null);

  static Future<void> _sort() async {
    var any = false;
    try {
      final db = AppDb.instance.db;
      if (!_cleaned) {
        _cleaned = true;
        await db.execute('DELETE FROM item_places WHERE item_id NOT IN (SELECT id FROM items)');
      }
      // (A limit on the rounds: a row that could not be written must not spin this for ever.)
      for (var round = 0; round < 400; round++) {
        final rows = await db.rawQuery('''
          SELECT i.id, i.type, i.title, f.path, f.media_key, f.seen, f.index_status, f.src, f.fixed,
                 substr(COALESCE(f.text, ''), 1, 1500) AS text
          FROM items i JOIN files f ON f.item_id = i.id
          WHERE i.private = 0 AND i.type IN ('photo','video','doc')
            AND ((f.index_status IN ('pending','working') AND f.sorted < 1)
              OR (f.index_status NOT IN ('pending','working') AND f.sorted < $version))
          LIMIT 300
        ''');
        if (rows.isEmpty) break;
        await db.transaction((txn) async {
          final b = txn.batch();
          for (final r in rows) {
            final id = '${r['id']}';
            final kind = '${r['type']}';
            final path = '${r['path'] ?? ''}';
            final status = '${r['index_status'] ?? ''}';
            final fromGallery = '${r['media_key'] ?? ''}'.isNotEmpty;
            // A gallery photo BYTE took into its own folder (Free up space)
            // keeps the album it came from.
            final was = '${r['src'] ?? ''}';
            final seenRaw = '${r['seen'] ?? ''}';
            final fixedRaw = '${r['fixed'] ?? ''}';
            final adopted = !fromGallery && kind != 'doc' && was.isNotEmpty;
            final places = placesFor(
              kind: kind,
              path: path,
              fromGallery: fromGallery,
              scores: parseScores(seenRaw),
              text: '${r['text'] ?? ''}',
              name: '${r['title'] ?? ''} ${p.basename(path)}',
              knownSource: adopted ? was : null,
              fixed: fixedRaw,
            );
            b.delete('item_places', where: 'item_id = ?', whereArgs: [id]);
            for (final pl in places) {
              b.insert('item_places', {'item_id': id, 'place': pl}, conflictAlgorithm: ConflictAlgorithm.ignore);
            }
            // Not read yet: sorted by its place for now (1), by what is in it later.
            final waiting = status == 'pending' || status == 'working';
            b.rawUpdate(
              // (Only when it is still as it was read: a second look that came in between is sorted next round.)
              'UPDATE files SET src = ?, sorted = ? WHERE item_id = ? AND index_status = ? AND seen = ? AND fixed = ?',
              [(fromGallery || adopted) && kind != 'doc' && places.isNotEmpty ? places.first : '', waiting ? 1 : version, id, status, seenRaw, fixedRaw],
            );
          }
          await b.commit(noResult: true);
        });
        any = true;
        // A whole gallery takes many rounds: the screens hear of it on the way.
        if (round % 5 == 4) changed.value++;
        // A breath between rounds, and out of the way of a finger on the screen.
        await UserBusy.whenIdle(quietMs: 400, maxWaitMs: 3000);
      }
    } catch (e) {
      debugPrint('[albums] sort: $e');
    } finally {
      if (any) changed.value++;
    }
  }

  static List<Album> _last = const [];

  /// What [list] answered last time (to show at once while a new look runs).
  static List<Album> get last => _last;

  /// The albums that have something in them, in the order of the strip.
  static Future<List<Album>> list() async {
    try {
      final db = AppDb.instance.db;
      final repo = LibraryRepo.instance;
      final counts = await db.rawQuery('''
        SELECT pl.place AS place, COUNT(*) AS n FROM item_places pl JOIN items i ON i.id = pl.item_id
        WHERE i.deleted_at IS NULL AND i.private = 0 GROUP BY pl.place
      ''');
      final sources = <String>{
        for (final r in await db.rawQuery("SELECT DISTINCT src FROM files WHERE src != ''")) '${r['src']}',
      };
      // An album you put a thing into yourself shows from its first picture.
      final chosen = <String>{
        for (final r in await db.rawQuery("SELECT DISTINCT f.fixed AS place FROM files f JOIN items i ON i.id = f.item_id WHERE f.fixed NOT IN ('', '-') AND i.deleted_at IS NULL AND i.private = 0")) '${r['place']}',
      };
      final albums = <Album>[];
      for (final r in counts) {
        final place = '${r['place']}';
        final n = (r['n'] as int?) ?? 0;
        if (n < placeMinimum(place) && !chosen.contains(place)) continue;
        final cover = await repo.list(place: place, limit: 1, withText: false);
        albums.add(Album(title: place, count: n, place: place, cover: cover.isEmpty ? null : cover.first, source: sources.contains(place) || place == Places.saved));
      }
      albums.sort((a, b) {
        final ra = placeRank(a.title);
        final rb = placeRank(b.title);
        if (ra != rb) return ra.compareTo(rb);
        return b.count.compareTo(a.count);
      });

      // Runs of busy days among your camera photos: a trip, a function.
      final taken = await db.rawQuery('''
        SELECT i.created_at AS at FROM items i JOIN files f ON f.item_id = i.id
        WHERE f.src = 'Camera' AND i.deleted_at IS NULL AND i.private = 0 AND i.type IN ('photo','video')
        ORDER BY i.created_at DESC LIMIT 20000
      ''');
      final runs = busyRuns([for (final r in taken) DateTime.fromMillisecondsSinceEpoch(r['at'] as int)]);
      final days = <Album>[];
      for (final run in runs.reversed.take(8)) {
        final until = DateTime(run.to.year, run.to.month, run.to.day + 1);
        final cover = await repo.list(place: Places.camera, since: run.from, until: until, limit: 1, withText: false);
        days.add(Album(title: run.label, count: run.count, from: run.from, until: until, cover: cover.isEmpty ? null : cover.first));
      }

      // Your own pictures first, then the busy days, then papers and the
      // albums of other apps.
      final at = albums.indexWhere((a) => placeRank(a.title) >= 20);
      final out = at < 0 ? [...albums, ...days] : [...albums.sublist(0, at), ...days, ...albums.sublist(at)];

      // "On this day": what you took on this date in earlier years comes
      // first — it is only there on days that have something.
      final today = DateTime.now();
      final back = await repo.list(onDay: today, mainOnly: true, pictures: true, limit: 500, withText: false);
      if (back.isNotEmpty) out.insert(0, Album(title: 'On this day', count: back.length, onDay: today, cover: back.first));
      _last = out;
      return out;
    } catch (e) {
      debugPrint('[albums] list: $e');
      return _last;
    }
  }
}
