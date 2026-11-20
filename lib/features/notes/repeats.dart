import 'package:flutter/foundation.dart';

import '../../core/db.dart';
import 'checklist.dart';
import 'note.dart';
import 'notes_repo.dart';

/// Lists that start again by themselves: a morning routine every day, the
/// shopping every week. When a new day (or week, from Monday) has begun,
/// every item of the list is un-ticked.
class Repeats {
  Repeats._();

  static const daily = 'daily';
  static const weekly = 'weekly';

  static String label(String kind) => switch (kind) {
        daily => 'Starts again every day',
        weekly => 'Starts again every Monday',
        _ => 'Does not repeat',
      };

  static Duration? every(String kind) => switch (kind) {
        daily => const Duration(days: 1),
        weekly => const Duration(days: 7),
        _ => null,
      };

  /// When the round that is running at [now] began: today at midnight, or
  /// this week's Monday at midnight. Null for a list that does not repeat.
  static DateTime? start(String kind, DateTime now) {
    final today = DateTime(now.year, now.month, now.day);
    return switch (kind) {
      daily => today,
      weekly => DateTime(now.year, now.month, now.day - (now.weekday - 1)),
      _ => null,
    };
  }

  /// When the next round begins.
  static DateTime? next(String kind, DateTime now) {
    final s = start(kind, now);
    if (s == null) return null;
    return kind == daily ? DateTime(s.year, s.month, s.day + 1) : DateTime(s.year, s.month, s.day + 7);
  }

  static String _mark(DateTime start) => '${start.year}-${start.month}-${start.day}';

  /// '' | [daily] | [weekly].
  static Future<String> of(String noteId) async {
    try {
      final rows = await AppDb.instance.db.query('items', columns: ['repeat'], where: 'id = ?', whereArgs: [noteId], limit: 1);
      return rows.isEmpty ? '' : '${rows.first['repeat'] ?? ''}';
    } catch (e) {
      debugPrint('[repeats] of: $e');
      return '';
    }
  }

  /// Sets how [noteId] repeats. The round that is running now counts as
  /// begun: nothing is un-ticked until the next one.
  static Future<void> set(String noteId, String kind) async {
    final s = start(kind, DateTime.now());
    await AppDb.instance.db.update('items', {'repeat': s == null ? '' : kind, 'repeat_mark': s == null ? '' : _mark(s)}, where: 'id = ?', whereArgs: [noteId]);
  }

  /// Every list that repeats: note id → how ([daily] or [weekly]).
  static Future<Map<String, String>> all() async {
    try {
      final rows = await AppDb.instance.db.query('items', columns: ['id', 'repeat'], where: "repeat != '' AND type = 'note' AND deleted_at IS NULL");
      return {for (final r in rows) '${r['id']}': '${r['repeat']}'};
    } catch (e) {
      debugPrint('[repeats] all: $e');
      return const {};
    }
  }

  /// The ready-made routines: (what it is called in the menu, what it says
  /// underneath, the list's name, how it repeats, what it starts with).
  static const starts = <(String, String, String, String, String)>[
    ('Every day', 'A morning routine, medicines, daily habits. Un-ticks itself each morning', 'Daily routine', daily, ''),
    ('Every week', 'The grocery list, weekly chores. Un-ticks itself each Monday', 'Grocery list', weekly, ''),
    ('A plan for the whole week', 'One section for each day, Monday to Sunday. Starts again each Monday', 'This week', weekly, 'Monday\nTuesday\nWednesday\nThursday\nFriday\nSaturday\nSunday'),
  ];

  /// Makes one of the [starts] and answers the new list.
  static Future<Note> make((String, String, String, String, String) start) async {
    final note = await NotesRepo.instance.create(title: start.$3, body: start.$5);
    await set(note.id, start.$4);
    return note;
  }

  static Future<void>? _running;

  /// Un-ticks every repeating list whose new round has begun. Call at start
  /// and whenever BYTE comes back to the front.
  static Future<void> runDue() => _running ??= _run().whenComplete(() => _running = null);

  static Future<void> _run() async {
    try {
      final db = AppDb.instance.db;
      final rows = await db.query('items', where: "repeat != '' AND type = 'note' AND deleted_at IS NULL");
      final now = DateTime.now();
      for (final r in rows) {
        final kind = '${r['repeat'] ?? ''}';
        final s = start(kind, now);
        if (s == null || '${r['repeat_mark'] ?? ''}' == _mark(s)) continue;
        final note = Note.fromRow(r);
        final body = untickAll(note.body, every: every(kind), now: now);
        // The mark first: whatever happens next, this round is not begun twice.
        await db.update('items', {'repeat_mark': _mark(s)}, where: 'id = ?', whereArgs: [note.id]);
        if (body != note.body) await NotesRepo.instance.update(note.copyWith(body: body));
      }
    } catch (e) {
      debugPrint('[repeats] run: $e');
    }
  }
}
