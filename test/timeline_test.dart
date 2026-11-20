import 'package:byte/features/library/bin_screen.dart';
import 'package:byte/features/library/library_item.dart';
import 'package:byte/features/library/timeline.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('timelineLabel (one heading per day)', () {
    final now = DateTime(2026, 11, 18, 15);

    test('today and yesterday go by the calendar day, not by hours', () {
      expect(timelineLabel(DateTime(2026, 11, 18, 0, 5), now: now), 'Today');
      expect(timelineLabel(DateTime(2026, 11, 17, 23, 59), now: now), 'Yesterday');
    });

    test('older days are named: weekday, day, month — and the year when it is another one', () {
      expect(timelineLabel(DateTime(2026, 11, 16), now: now), 'Mon, 16 Nov');
      expect(timelineLabel(DateTime(2026, 10, 30), now: now), 'Fri, 30 Oct');
      expect(timelineLabel(DateTime(2025, 1, 5), now: now), 'Sun, 5 Jan 2025');
    });

    test('a date ahead of the clock still reads Today', () {
      expect(timelineLabel(DateTime(2026, 11, 19), now: now), 'Today');
    });
  });

  group('timelineRows', () {
    LibraryItem at(String id, DateTime t, [LibraryKind kind = LibraryKind.photo]) => LibraryItem(id: id, kind: kind, title: id, tags: const [], createdAt: t);
    final now = DateTime(2026, 11, 18, 15);

    test('a heading per day, pictures three in a row, other things after them', () {
      final rows = timelineRows([
        at('a', DateTime(2026, 11, 18, 10)),
        at('b', DateTime(2026, 11, 18, 9)),
        at('n', DateTime(2026, 11, 18, 8), LibraryKind.note),
        at('c', DateTime(2026, 11, 18, 7)),
        at('d', DateTime(2026, 11, 18, 6)),
        at('e', DateTime(2026, 11, 17, 20)),
      ], now: now);
      expect(rows.length, 6);
      expect((rows[0] as HeadRow).label, 'Today');
      expect((rows[0] as HeadRow).count, 5);
      expect([for (final i in (rows[1] as TilesRow).items) i.id], ['a', 'b', 'c']);
      expect([for (final i in (rows[2] as TilesRow).items) i.id], ['d']);
      expect((rows[3] as LineRow).item.id, 'n');
      expect((rows[4] as HeadRow).label, 'Yesterday');
      expect([for (final i in (rows[5] as TilesRow).items) i.id], ['e']);
    });

    test('the layout knows which row lies at a height', () {
      final rows = timelineRows([
        at('a', DateTime(2026, 11, 18, 10)),
        at('e', DateTime(2026, 11, 17, 20)),
      ], now: now);
      const m = TimelineMetrics(width: 400, textScale: 1);
      final layout = TimelineLayout(rows, m);
      expect(layout.height, closeTo(2 * m.head + 2 * (m.tile + TimelineMetrics.gap), 0.001));
      expect(layout.rowAt(0), rows[0]);
      expect(layout.rowAt(m.head + 1), rows[1]);
      expect(layout.rowAt(layout.height + 500), rows[3]);
      expect(layout.rowAt(-20), rows[0]);
    });
  });

  group('binDaysLeft', () {
    final now = DateTime(2026, 11, 18, 12);

    test('30 on the day it was deleted, counting down', () {
      expect(binDaysLeft(now, now: now), 30);
      expect(binDaysLeft(now.subtract(const Duration(days: 1)), now: now), 29);
      expect(binDaysLeft(now.subtract(const Duration(days: 29, hours: 23)), now: now), 1);
    });

    test('never below 0 or above 30', () {
      expect(binDaysLeft(now.subtract(const Duration(days: 30)), now: now), 0);
      expect(binDaysLeft(now.subtract(const Duration(days: 45)), now: now), 0);
      expect(binDaysLeft(now.add(const Duration(days: 2)), now: now), 30);
    });
  });
}
