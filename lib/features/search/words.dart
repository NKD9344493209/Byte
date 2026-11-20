import 'package:flutter/foundation.dart';

import '../../core/db.dart';
import '../../core/prefs.dart';

/// Every word BYTE has read — in notes, inside photos, on the pages of a
/// PDF. Search uses the list to forgive a spelling slip: "photosynthsis"
/// finds the document that says "photosynthesis".
///
/// The pure parts ([wordsOf], [editDistance], [nearWords], [allowedSlips])
/// are unit-tested.

// Letters, digits and the marks that belong to letters (Tamil vowel signs,
// accents) make a word; everything else separates words.
final RegExp _notWord = RegExp(r'[^\p{L}\p{N}\p{M}]+', unicode: true);

/// The distinct words of [text], lower-case, 3 to 32 letters long.
/// At most [max] per text (a 300-page PDF does not need more to be found).
Set<String> wordsOf(String text, {int max = 4000}) {
  final out = <String>{};
  for (final w in text.toLowerCase().split(_notWord)) {
    if (w.length < 3 || w.length > 32) continue;
    out.add(w);
    if (out.length >= max) break;
  }
  return out;
}

/// How many slips a word of this length may have and still count as "the same".
int allowedSlips(int length) => length < 4 ? 0 : (length < 8 ? 1 : 2);

/// Typing slips between [a] and [b]: a wrong, missing or extra letter, or two
/// neighbours swapped, each count as one. Stops early and returns [max] + 1
/// once the answer is known to be above [max].
int editDistance(String a, String b, {int max = 2}) {
  final la = a.length;
  final lb = b.length;
  if ((la - lb).abs() > max) return max + 1;
  if (a == b) return 0;
  if (la == 0) return lb;
  if (lb == 0) return la;
  var prev2 = List<int>.filled(lb + 1, 0);
  var prev = List<int>.generate(lb + 1, (j) => j);
  var cur = List<int>.filled(lb + 1, 0);
  for (var i = 1; i <= la; i++) {
    cur[0] = i;
    var best = cur[0];
    final ca = a.codeUnitAt(i - 1);
    for (var j = 1; j <= lb; j++) {
      final cb = b.codeUnitAt(j - 1);
      final cost = ca == cb ? 0 : 1;
      var v = prev[j] + 1; // a letter missing in b
      if (cur[j - 1] + 1 < v) v = cur[j - 1] + 1; // an extra letter in b
      if (prev[j - 1] + cost < v) v = prev[j - 1] + cost; // a wrong letter
      if (i > 1 && j > 1 && ca == b.codeUnitAt(j - 2) && a.codeUnitAt(i - 2) == cb && prev2[j - 2] + 1 < v) {
        v = prev2[j - 2] + 1; // two neighbours swapped
      }
      cur[j] = v;
      if (v < best) best = v;
    }
    if (best > max) return max + 1;
    final t = prev2;
    prev2 = prev;
    prev = cur;
    cur = t;
  }
  return prev[lb];
}

/// The words of [vocabulary] closest to [word], nearest first, at most [take].
/// Empty when [word] is too short to guess or nothing is near enough.
List<String> nearWords(String word, Iterable<String> vocabulary, {int take = 3}) {
  final w = word.toLowerCase();
  final slips = allowedSlips(w.length);
  if (slips == 0) return const [];
  final found = <(int, int, String)>[];
  for (final v in vocabulary) {
    if (v == w) continue;
    final d = editDistance(w, v, max: slips);
    if (d > slips) continue;
    // A slip is rarely in the first letter: same first letter ranks higher.
    final first = v.isNotEmpty && v.codeUnitAt(0) == w.codeUnitAt(0) ? 0 : 1;
    found.add((d, first, v));
  }
  found.sort((x, y) {
    if (x.$1 != y.$1) return x.$1.compareTo(y.$1);
    if (x.$2 != y.$2) return x.$2.compareTo(y.$2);
    return x.$3.compareTo(y.$3);
  });
  return [for (final f in found.take(take)) f.$3];
}

List<String> _nearest((String, List<String>) job) => nearWords(job.$1, job.$2, take: 1);

class Words {
  Words._();

  /// Adds the words of [texts] to the list. Cheap; safe to call often.
  static Future<void> add(Iterable<String> texts) async {
    final words = <String>{};
    for (final t in texts) {
      if (t.isEmpty) continue;
      words.addAll(wordsOf(t));
    }
    if (words.isEmpty) return;
    try {
      final db = AppDb.instance.db;
      await db.transaction((txn) async {
        final batch = txn.batch();
        for (final w in words) {
          batch.rawInsert('INSERT OR IGNORE INTO words (word) VALUES (?)', [w]);
        }
        await batch.commit(noResult: true);
      });
    } catch (e) {
      debugPrint('[words] add: $e');
    }
  }

  /// Is [word] (or a longer word starting with it) something BYTE has read?
  static Future<bool> known(String word) async {
    final w = word.toLowerCase();
    try {
      // A range scan on the primary key: fast however long the list is.
      final rows = await AppDb.instance.db.rawQuery('SELECT 1 FROM words WHERE word >= ? AND word < ? LIMIT 1', [w, '$w\u{10FFFF}']);
      return rows.isNotEmpty;
    } catch (_) {
      return true; // can't tell → don't second-guess the user
    }
  }

  /// [query] with each word BYTE has never read swapped for the closest word
  /// it has. Returns '' when nothing changes (all words known, or no near
  /// match), so the caller can tell "no better guess".
  static Future<String> respell(String query) async {
    final parts = query.trim().toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    if (parts.isEmpty) return '';
    var changed = false;
    final out = <String>[];
    for (final w in parts) {
      final slips = allowedSlips(w.length);
      if (slips == 0 || await known(w)) {
        out.add(w);
        continue;
      }
      List<Map<String, Object?>> rows;
      try {
        rows = await AppDb.instance.db.rawQuery(
          'SELECT word FROM words WHERE length(word) BETWEEN ? AND ?',
          [w.length - slips, w.length + slips],
        );
      } catch (_) {
        rows = const [];
      }
      // Off the UI thread: with a big word list this is tens of thousands of comparisons.
      final near = await compute(_nearest, (w, [for (final r in rows) r['word'] as String]));
      if (near.isEmpty) {
        out.add(w);
      } else {
        out.add(near.first);
        changed = true;
      }
    }
    return changed ? out.join(' ') : '';
  }

  /// Once, after the update that brought this list: read everything already
  /// in the vault. In small pages, so the app stays smooth meanwhile.
  static Future<void> backfillOnce() async {
    try {
      final db = AppDb.instance.db;
      // The flag lives outside the vault; a vault restored from an older backup
      // has an empty list even though the flag says "done".
      if (Prefs.flag('words_backfilled_2') && (await db.rawQuery('SELECT 1 FROM words LIMIT 1')).isNotEmpty) return;
      var last = '';
      while (true) {
        // By id, not by position: things binned meanwhile cannot make it skip rows.
        final rows = await db.rawQuery(
          // (clean_text: the words of a voice note.)
          'SELECT i.id, i.title, i.body, i.tags, f.text, f.labels, a.clean_text FROM items i '
          'LEFT JOIN files f ON f.item_id = i.id LEFT JOIN audio a ON a.item_id = i.id '
          'WHERE i.deleted_at IS NULL AND i.private = 0 AND i.id > ? ORDER BY i.id LIMIT 100',
          [last],
        );
        if (rows.isEmpty) break;
        for (final r in rows) {
          await add([for (final k in const ['title', 'body', 'tags', 'text', 'labels', 'clean_text']) '${r[k] ?? ''}']);
        }
        last = rows.last['id'] as String;
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
      await Prefs.setFlag('words_backfilled_2', true);
    } catch (e) {
      debugPrint('[words] backfill: $e');
    }
  }
}
