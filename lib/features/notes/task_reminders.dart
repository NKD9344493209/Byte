import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/db.dart';
import '../../core/doc_alerts.dart';
import '../library/library_repo.dart';
import 'checklist.dart';
import 'note.dart';
import 'notes_repo.dart';
import 'repeats.dart';

/// Reminders of checklist items ("Pay the fee" at 9 tomorrow): hands Android
/// the whole list of them, so each shows at its time even when BYTE is closed.
class TaskReminders {
  TaskReminders._();

  static const _most = 200;

  static Timer? _soon;
  static bool _watching = false;

  /// A note changed (or went to the bin): the reminders follow. Call once at start.
  static void watch() {
    if (_watching) return;
    _watching = true;
    void later() {
      _soon?.cancel();
      _soon = Timer(const Duration(seconds: 2), reschedule);
    }

    NotesRepo.instance.revision.addListener(later);
    LibraryRepo.instance.revision.addListener(later);
  }

  /// The times a reminder set for [at] comes, after [now]: once for an
  /// ordinary list. On a list that repeats ([kind]) it comes again every day
  /// (the next seven) or every week (the next four) at the same time of day —
  /// for an item that is ticked ([done]), from the next round on.
  static List<DateTime> times(DateTime at, {required String kind, required bool done, required DateTime now}) {
    final step = Repeats.every(kind)?.inDays ?? 0;
    if (step == 0) return done || !at.isAfter(now) ? const [] : [at];
    final from = done ? (Repeats.next(kind, now) ?? now) : now;
    final out = <DateTime>[];
    // Whole days on the calendar, so the time of day never drifts.
    var k = at.isAfter(from) ? 0 : from.difference(at).inDays ~/ step;
    while (out.length < (step == 1 ? 7 : 4)) {
      final t = DateTime(at.year, at.month, at.day + k * step, at.hour, at.minute);
      if (done ? !t.isBefore(from) : t.isAfter(from)) out.add(t);
      k++;
    }
    return out;
  }

  /// Every reminder that is still to come, over all lists (never the private
  /// ones: a reminder shows on the lock screen). Call at start and after changes.
  static Future<void> reschedule() async {
    try {
      // (The mark is a clock sign: only notes that have one are read.)
      final rows = await AppDb.instance.db.query('items', where: "type = 'note' AND deleted_at IS NULL AND private = 0 AND body LIKE '%⏰%'");
      final now = DateTime.now();
      final alarms = <DocAlarm>[];
      // Far from the document wallet's numbers (1, 2, 3 …): Android tells alarms apart by them.
      var id = 100000;
      for (final r in rows) {
        final note = Note.fromRow(r);
        final kind = '${r['repeat'] ?? ''}';
        for (final t in remindersIn(note.body, withDone: true)) {
          for (final at in times(t.at, kind: kind, done: t.done, now: now)) {
            if (alarms.length >= _most) break;
            alarms.add(DocAlarm(id: id++, at: at, title: t.text, text: note.displayTitle, noteId: note.id, index: t.index));
          }
        }
        if (alarms.length >= _most) break;
      }
      await DocAlerts.setAll(alarms, group: 'tasks');
    } catch (e) {
      debugPrint('[task reminders] $e');
    }
  }
}
