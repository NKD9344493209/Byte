import 'package:byte/features/wallet/wallet.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime(2026, 11, 19, 12);

  test('daysLeft counts calendar days', () {
    expect(daysLeft(null, now: now), isNull);
    expect(daysLeft(DateTime(2026, 11, 19, 23), now: now), 0);
    expect(daysLeft(DateTime(2026, 11, 20), now: now), 1);
    expect(daysLeft(DateTime(2026, 11, 18), now: now), -1);
    expect(daysLeft(DateTime(2027, 11, 19), now: now), 365);
  });

  test('validityText', () {
    expect(validityText(null, now: now), 'No end date');
    expect(validityText(DateTime(2026, 12, 19), now: now), 'Valid until 19/12/2026 · 30 days left');
    expect(validityText(DateTime(2026, 11, 20), now: now), 'Valid until 20/11/2026 · 1 day left');
    expect(validityText(DateTime(2026, 11, 19), now: now), 'Runs out today (19/11/2026)');
    expect(validityText(DateTime(2026, 1, 2), now: now), 'Ran out on 2/1/2026');
  });

  test('reminders: a month, a week, a day before and on the day, at 9 — only the ones still ahead', () {
    final all = reminderTimes('Licence', DateTime(2027, 3, 12), now: now);
    expect([for (final r in all) r.at], [DateTime(2027, 2, 10, 9), DateTime(2027, 3, 5, 9), DateTime(2027, 3, 11, 9), DateTime(2027, 3, 12, 9)]);
    expect(all.first.text, 'Licence runs out in a month (12/3/2027).');
    expect(all.last.text, 'Licence runs out today (12/3/2027).');

    // Ten days left: the month reminder is already past.
    final soon = reminderTimes('Licence', DateTime(2026, 11, 29), now: now);
    expect([for (final r in soon) r.at], [DateTime(2026, 11, 22, 9), DateTime(2026, 11, 28, 9), DateTime(2026, 11, 29, 9)]);

    // Already ran out: nothing to remind.
    expect(reminderTimes('Licence', DateTime(2026, 11, 1), now: now), isEmpty);
  });
}
