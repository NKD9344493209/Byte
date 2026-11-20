import 'package:byte/features/notes/repeats.dart';
import 'package:byte/features/notes/task_reminders.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime(2026, 11, 19, 8);

  test('an ordinary list reminds once, and only for what is still to come', () {
    final at = DateTime(2026, 11, 20, 9);
    expect(TaskReminders.times(at, kind: '', done: false, now: now), [at]);
    expect(TaskReminders.times(at, kind: '', done: true, now: now), isEmpty);
    expect(TaskReminders.times(DateTime(2026, 11, 18, 9), kind: '', done: false, now: now), isEmpty);
  });

  test('a list that repeats every day reminds every day at that time', () {
    final t = TaskReminders.times(DateTime(2026, 11, 18, 7), kind: Repeats.daily, done: false, now: now);
    expect(t.length, 7);
    expect(t.first, DateTime(2026, 11, 20, 7)); // today's 7:00 has passed
    expect(t.last, DateTime(2026, 11, 26, 7));
  });

  test('a ticked item reminds again from the next round', () {
    final t = TaskReminders.times(DateTime(2026, 11, 19, 18), kind: Repeats.daily, done: true, now: now);
    expect(t.first, DateTime(2026, 11, 20, 18)); // not today at 6: it is done for today
  });

  test('every week', () {
    final t = TaskReminders.times(DateTime(2026, 11, 16, 9), kind: Repeats.weekly, done: false, now: now);
    expect(t, [DateTime(2026, 11, 23, 9), DateTime(2026, 11, 30, 9), DateTime(2026, 12, 7, 9), DateTime(2026, 12, 14, 9)]);
  });
}
