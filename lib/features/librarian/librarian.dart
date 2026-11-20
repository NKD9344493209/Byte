import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../core/activity.dart';
import '../../core/db.dart';
import '../../core/prefs.dart';
import '../capture/audio_repo.dart';
import '../library/collections_repo.dart';
import '../library/library_repo.dart';
import 'librarian_rules.dart';

/// One thing BYTE offers to tidy. Nothing happens until you say "Do it".
class TidyIdea {
  const TidyIdea({
    required this.key,
    required this.kind,
    required this.title,
    required this.detail,
    this.ids = const [],
    this.folderName = '',
    this.names = const [],
    this.examples = const [],
  });

  /// Remembers "not this one" (e.g. "folder:Bills & receipts").
  final String key;

  /// folder | trip | names | screens | copies
  final String kind;
  final String title;
  final String detail;

  /// The items it is about.
  final List<String> ids;

  /// folder / trip: the folder they would go into.
  final String folderName;

  /// names: (item id, the name it has, the name it would get).
  final List<(String, String, String)> names;

  /// A few names to show what it is about.
  final List<String> examples;
}

/// The librarian looks at what BYTE already read — names, words inside
/// files, what photos show, dates — and offers to tidy: files that belong
/// together into a folder, busy days into an album, real names for
/// "IMG_1234", old screenshots and extra copies into the bin. Everything is worked out on
/// the phone; nothing is sent anywhere. It only ever suggests.
class Librarian {
  Librarian._();

  static const _kDismissed = 'tidy_dismissed';
  static const _kNext = 'tidy_card_next';

  /// How many ideas there are right now (for the card in the Library).
  static final ValueNotifier<int> waiting = ValueNotifier<int>(0);

  static Set<String> get _dismissed => Prefs.text(_kDismissed).split('\n').where((s) => s.isNotEmpty).toSet();

  static Future<void> dismiss(TidyIdea idea) async {
    final d = _dismissed..add(idea.key);
    // Not an endless list: the newest 300 are enough.
    final keep = d.length > 300 ? d.skip(d.length - 300) : d;
    await Prefs.setText(_kDismissed, keep.join('\n'));
    if (waiting.value > 0) waiting.value--;
  }

  /// The card in the Library shows at most once a week.
  static bool get cardDue => waiting.value > 0 && Prefs.number(_kNext) <= DateTime.now().millisecondsSinceEpoch;

  static Future<void> snoozeCard() async {
    await Prefs.setNumber(_kNext, DateTime.now().add(const Duration(days: 7)).millisecondsSinceEpoch);
  }

  /// An idea was carried out: one less is waiting. (It is not remembered as
  /// "not this one" — when new files of the same kind arrive, BYTE may offer
  /// again.)
  static void _oneLess() {
    if (waiting.value > 0) waiting.value--;
  }

  /// What [apply] answers when there was nothing it could do.
  static const nothingDone = 'Nothing to do.';

  static Future<List<TidyIdea>>? _looking;

  /// Looks through the library and returns what could be tidied. A call
  /// made while a look is running gets that look's answer.
  static Future<List<TidyIdea>> ideas() => _looking ??= _look().whenComplete(() => _looking = null);

  static Future<List<TidyIdea>> _look() async {
    try {
      final out = await _ideas();
      waiting.value = out.length;
      return out;
    } catch (e) {
      debugPrint('[librarian] $e');
      return const [];
    }
  }

  static Future<List<TidyIdea>> _ideas() async {
    final db = AppDb.instance.db;
    final dismissed = _dismissed;
    final rows = await db.rawQuery('''
      SELECT i.id, i.type, i.title, i.created_at, f.path, f.labels,
             substr(COALESCE(f.text, ''), 1, 600) AS text,
             substr(COALESCE(a.clean_text, ''), 1, 200) AS said
      FROM items i LEFT JOIN files f ON f.item_id = i.id LEFT JOIN audio a ON a.item_id = i.id
      WHERE i.deleted_at IS NULL AND i.private = 0 AND i.type IN ('photo','video','doc','audio')
      ORDER BY i.created_at DESC LIMIT 12000
    ''');
    final filed = await CollectionsRepo.instance.filedItemIds();
    final folders = {for (final c in await CollectionsRepo.instance.list()) c.name.toLowerCase(): c};

    final byFolder = <String, List<Map<String, Object?>>>{};
    final media = <Map<String, Object?>>[];
    final names = <(String, String, String)>[];
    final oldShots = <Map<String, Object?>>[];
    final shotCutoff = DateTime.now().subtract(const Duration(days: 90)).millisecondsSinceEpoch;

    var seen = 0;
    for (final r in rows) {
      // A breath now and then: the screen stays smooth while BYTE thinks.
      if (++seen % 250 == 0) await Future<void>.delayed(Duration.zero);
      final id = '${r['id']}';
      final type = '${r['type']}';
      final title = '${r['title'] ?? ''}';
      final path = '${r['path'] ?? ''}';
      final text = '${r['text'] ?? ''}';
      final labels = '${r['labels'] ?? ''}'.split(',').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
      final at = (r['created_at'] as int?) ?? 0;

      // A real name for "IMG_1234" / "Voice note · …", from the words inside.
      if (names.length < 200 && looksUnnamed(title)) {
        final better = suggestTitle(type == 'audio' ? '${r['said'] ?? ''}' : text);
        if (better != null && better != title.trim()) names.add((id, title, better));
      }
      if (filed.contains(id) || type == 'audio') continue; // already in a folder of yours

      final folder = folderFor(name: '$title ${p.basename(path)}', text: text, labels: labels);
      if (folder == 'Screenshots' && at < shotCutoff) {
        oldShots.add(r);
      } else if (folder != null) {
        (byFolder[folder] ??= []).add(r);
      }
      if (type == 'photo' || type == 'video') media.add(r);
    }

    final out = <TidyIdea>[];

    // 1. Files that belong together.
    for (final e in byFolder.entries) {
      if (e.value.length < 3) continue;
      final key = 'folder:${e.key}';
      if (dismissed.contains(key)) continue;
      final exists = folders.containsKey(e.key.toLowerCase());
      final n = e.value.length;
      out.add(TidyIdea(
        key: key,
        kind: 'folder',
        title: exists ? 'Add $n more to "${e.key}"' : 'Make a folder "${e.key}"',
        detail: '$n ${n == 1 ? 'file looks' : 'files look'} like ${_what(e.key)}. They stay in your Library too.',
        ids: [for (final r in e.value.take(500)) '${r['id']}'],
        folderName: e.key,
        examples: [for (final r in e.value.take(3)) _show(r)],
      ));
    }

    // 2. Busy days: a trip, a function, a tour.
    final runs = busyRuns([for (final r in media) DateTime.fromMillisecondsSinceEpoch((r['created_at'] as int?) ?? 0)]);
    for (final run in runs.reversed.take(4)) {
      final key = 'trip:${run.key}';
      if (dismissed.contains(key)) continue;
      final from = run.from.millisecondsSinceEpoch;
      final to = DateTime(run.to.year, run.to.month, run.to.day + 1).millisecondsSinceEpoch;
      final ids = [
        for (final r in media)
          if (((r['created_at'] as int?) ?? 0) >= from && ((r['created_at'] as int?) ?? 0) < to) '${r['id']}',
      ];
      if (ids.length < 20) continue;
      out.add(TidyIdea(
        key: key,
        kind: 'trip',
        title: '${ids.length} photos from ${run.label}',
        detail: 'You took a lot of photos on these days — a trip or a function? BYTE can put them in one folder. You choose its name.',
        ids: ids.take(2000).toList(),
        folderName: 'Trip, ${run.label}',
      ));
    }

    // 3. Names.
    if (names.length >= 3 && !dismissed.contains('names')) {
      out.add(TidyIdea(
        key: 'names',
        kind: 'names',
        title: 'Give ${names.length} files a real name',
        detail: 'Their names say nothing ("IMG_1234"). BYTE can name each one after the first line it read inside. You can undo it.',
        names: names,
        examples: [for (final n in names.take(3)) '${n.$2.trim().isEmpty ? 'No name' : n.$2} → ${n.$3}'],
      ));
    }

    // 4. Old screenshots.
    if (oldShots.length >= 5 && !dismissed.contains('screens')) {
      out.add(TidyIdea(
        key: 'screens',
        kind: 'screens',
        title: 'Move ${oldShots.length} old screenshots to the bin',
        detail: 'Screenshots older than three months that are in no folder. They wait in the bin for 30 days, so nothing is lost by mistake.',
        ids: [for (final r in oldShots.take(2000)) '${r['id']}'],
        examples: [for (final r in oldShots.take(3)) _show(r)],
      ));
    }

    // 5. The very same photo or video, kept more than once.
    if (!dismissed.contains('copies')) {
      final extra = await _extraCopies();
      if (extra.isNotEmpty) {
        out.add(TidyIdea(
          key: 'copies',
          kind: 'copies',
          title: extra.length == 1 ? 'Move 1 extra copy to the bin' : 'Move ${extra.length} extra copies to the bin',
          detail: 'The very same photo or video is kept more than once. The oldest of each stays; the extra copies wait in the bin for 30 days.',
          ids: [for (final r in extra) '${r['id']}'],
          examples: [for (final r in extra.take(3)) _show(r)],
        ));
      }
    }
    return out;
  }

  /// What a file looked like the last time it was compared ("id:size" →
  /// print), so the same files are not read again on every look.
  static final Map<String, String> _prints = <String, String>{};

  /// The start and the end of the file, pressed into a short print. Two files
  /// of the same size with the same print are the same picture.
  static Future<String?> _printOf(String path) async {
    RandomAccessFile? f;
    try {
      f = await File(path).open();
      const part = 64 * 1024;
      final length = await f.length();
      final head = await f.read(part);
      var tail = const <int>[];
      if (length > part) {
        // The last part — or, in a small file, everything after the first part.
        await f.setPosition(length - part > part ? length - part : part);
        tail = await f.read(part);
      }
      return md5.convert([...head, ...tail]).toString();
    } catch (_) {
      return null; // (a file that is not on the phone right now is simply left out)
    } finally {
      await f?.close();
    }
  }

  /// Photos and videos that are a second (third…) copy of an older one:
  /// the same kind, the same size, and the same start and end of the file.
  static Future<List<Map<String, Object?>>> _extraCopies() async {
    final rows = await AppDb.instance.db.rawQuery('''
      SELECT i.id, i.type, i.title, f.path, f.size
      FROM items i JOIN files f ON f.item_id = i.id
      WHERE i.deleted_at IS NULL AND i.private = 0 AND i.type IN ('photo','video') AND f.size > 0 AND f.path != ''
        AND f.size IN (
          SELECT f2.size FROM files f2 JOIN items i2 ON i2.id = f2.item_id
          WHERE i2.deleted_at IS NULL AND i2.private = 0 AND i2.type IN ('photo','video') AND f2.size > 0
          GROUP BY f2.size HAVING COUNT(*) > 1
        )
      ORDER BY f.size, i.created_at, i.id LIMIT 800
    ''');
    final kept = <String, String>{}; // "type:size:print" of the oldest copy → where that file is
    final extra = <Map<String, Object?>>[];
    var read = 0;
    for (final r in rows) {
      final size = (r['size'] as int?) ?? 0;
      final key = '${r['id']}:$size';
      var mark = _prints[key];
      if (mark == null) {
        // A breath now and then: the screen stays smooth while BYTE compares.
        if (++read % 20 == 0) await Future<void>.delayed(Duration.zero);
        mark = await _printOf('${r['path'] ?? ''}');
        if (mark == null) continue;
        _prints[key] = mark;
      }
      // (The rows come oldest first within a size: the first one seen stays.)
      final path = '${r['path'] ?? ''}';
      final first = kept.putIfAbsent('${r['type']}:$size:$mark', () => path);
      // Two rows for one and the same file are not copies: binning one would
      // take the only file there is.
      if (first != path) extra.add(r);
    }
    return extra;
  }

  static String _show(Map<String, Object?> r) {
    final t = '${r['title'] ?? ''}'.trim();
    return t.isNotEmpty ? t : p.basename('${r['path'] ?? ''}');
  }

  static String _what(String folder) => switch (folder) {
        'ID cards' => 'ID cards and documents',
        'College' => 'college papers',
        'Certificates' => 'certificates',
        'Bills & receipts' => 'bills and receipts',
        'Bank' => 'bank papers',
        'Tickets & travel' => 'tickets',
        'Screenshots' => 'screenshots',
        'Food' => 'photos of food',
        'Pets & animals' => 'photos of animals',
        _ => folder.toLowerCase(),
      };

  /// Does what [idea] offered. [folderName]: the name you chose for the
  /// folder (folder and trip ideas). Returns what to tell the user.
  static Future<String> apply(TidyIdea idea, {String? folderName}) async {
    final db = AppDb.instance.db;
    switch (idea.kind) {
      case 'folder':
      case 'trip':
        final name = (folderName ?? idea.folderName).trim();
        if (name.isEmpty || idea.ids.isEmpty) return nothingDone;
        final existing = await CollectionsRepo.instance.byName(name);
        final Collection folder;
        final bool had; // the folder was there before (so Undo must not remove it)
        if (existing != null && existing.name.toLowerCase() == name.toLowerCase()) {
          folder = existing;
          had = true;
        } else {
          folder = await CollectionsRepo.instance.create(name);
          had = false;
        }
        final now = DateTime.now().millisecondsSinceEpoch;
        final added = <String>[];
        await db.transaction((txn) async {
          var pos = ((await txn.rawQuery('SELECT COALESCE(MAX(position), 0) AS m FROM collection_items WHERE collection_id = ?', [folder.id])).first['m'] as int?) ?? 0;
          for (final id in idea.ids) {
            final n = await txn.rawInsert(
              'INSERT OR IGNORE INTO collection_items (collection_id, item_id, added_at, position) VALUES (?, ?, ?, ?)',
              [folder.id, id, now, ++pos],
            );
            if (n > 0) added.add(id);
          }
        });
        CollectionsRepo.instance.revision.value++;
        LibraryRepo.instance.touch();
        await Activity.log('folder', 'Put ${added.length} item${added.length == 1 ? '' : 's'} in "${folder.name}"', undo: {'folder': folder.id, 'ids': added, 'created': !had});
        _oneLess();
        return '${added.length} item${added.length == 1 ? ' is' : 's are'} in "${folder.name}" now.';
      case 'names':
        final done = <Map<String, String>>[];
        await db.transaction((txn) async {
          for (final (id, old, fresh) in idea.names) {
            // Only where the name is still the one BYTE looked at.
            final n = await txn.rawUpdate('UPDATE items SET title = ? WHERE id = ? AND title = ?', [fresh, id, old]);
            if (n > 0) done.add({'id': id, 'old': old, 'new': fresh});
          }
        });
        LibraryRepo.instance.touch();
        AudioRepo.instance.revision.value++;
        await Activity.log('names', 'Named ${done.length} file${done.length == 1 ? '' : 's'} after what is inside', undo: {'items': done});
        _oneLess();
        return '${done.length} file${done.length == 1 ? ' has' : 's have'} a real name now.';
      case 'screens':
        await LibraryRepo.instance.deleteMany(idea.ids);
        _oneLess();
        return '${idea.ids.length} screenshots are in the bin.';
      case 'copies':
        await LibraryRepo.instance.deleteMany(idea.ids);
        _oneLess();
        return '${idea.ids.length} extra ${idea.ids.length == 1 ? 'copy is' : 'copies are'} in the bin.';
      default:
        return nothingDone;
    }
  }
}
