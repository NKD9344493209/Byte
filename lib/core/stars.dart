import 'package:flutter/foundation.dart';

import 'db.dart';

/// Starred items — the things you want close at hand.
///
/// A star is one flag on the item (`items.pinned`, the column the old sticky
/// board used, so nothing is lost on upgrade). The Library has a "Starred"
/// chip; later rounds keep starred photos on the phone when the rest lives in
/// Google Drive.
class Stars {
  Stars._();

  /// Bumped whenever a star changes (lists listen and reload).
  static final ValueNotifier<int> changed = ValueNotifier<int>(0);

  static Future<bool> isStarred(String id) async {
    final rows = await AppDb.instance.db.query('items', columns: ['pinned'], where: 'id = ?', whereArgs: [id]);
    return rows.isNotEmpty && (rows.first['pinned'] as int? ?? 0) == 1;
  }

  static Future<void> set(String id, bool starred) => setMany([id], starred);

  /// Star or un-star many at once (long-press selection).
  static Future<void> setMany(Iterable<String> ids, bool starred) async {
    final list = ids.toList();
    if (list.isEmpty) return;
    final marks = List.filled(list.length, '?').join(',');
    await AppDb.instance.db.rawUpdate(
      'UPDATE items SET pinned = ?, updated_at = ? WHERE id IN ($marks)',
      [starred ? 1 : 0, DateTime.now().millisecondsSinceEpoch, ...list],
    );
    changed.value++;
  }

  /// If every id is already starred → remove the stars; otherwise star them
  /// all. Returns the new state (true = starred).
  static Future<bool> toggleMany(Iterable<String> ids) async {
    final list = ids.toList();
    if (list.isEmpty) return false;
    final marks = List.filled(list.length, '?').join(',');
    final rows = await AppDb.instance.db.rawQuery(
      'SELECT COUNT(*) AS n FROM items WHERE pinned = 1 AND id IN ($marks)',
      list,
    );
    final all = (rows.first['n'] as int? ?? 0) == list.length;
    await setMany(list, !all);
    return !all;
  }
}
