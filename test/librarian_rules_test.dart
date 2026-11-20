import 'package:byte/features/librarian/librarian_rules.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('which folder a file belongs in', () {
    expect(folderFor(name: 'IMG_1', text: 'Government of India\nAadhaar 1234'), 'ID cards');
    expect(folderFor(name: 'scan', text: 'Anna University\nHall Ticket\nRegister Number 123'), 'College');
    expect(folderFor(name: 'x', text: 'Tax Invoice\nGSTIN 33ABC'), 'Bills & receipts');
    expect(folderFor(name: 'Screenshot_2026-08-12-10-15-00', text: 'hello'), 'Screenshots');
    expect(folderFor(name: 'IMG_2', labels: ['Food', 'Plate']), 'Food');
    expect(folderFor(name: 'IMG_3', labels: ['Sky']), isNull);
    expect(folderFor(name: 'notes', text: 'buy rice'), isNull);
  });

  test('names that say nothing', () {
    expect(looksUnnamed('IMG_20260812_101500'), isTrue);
    expect(looksUnnamed('Screenshot_2026-08-12-10-15-00-123'), isTrue);
    expect(looksUnnamed('scan0001'), isTrue);
    expect(looksUnnamed('IMG-20260812-WA0007'), isTrue);
    expect(looksUnnamed('Voice note · 3/8 10:15 am'), isTrue);
    expect(looksUnnamed(''), isTrue);
    expect(looksUnnamed('Hall ticket sem 5'), isFalse);
    expect(looksUnnamed('Resume'), isFalse);
    expect(looksUnnamed('document final'), isFalse);
  });

  test('a name from the words inside', () {
    expect(suggestTitle('12345\nAnna University Hall Ticket\nReg No 1'), 'Anna University Hall Ticket');
    expect(suggestTitle('Page 1: Tax Invoice for March\nmore'), 'Tax Invoice for March');
    expect(suggestTitle('12/08/2026 10:15\n+91 98765 43210'), isNull);
    expect(suggestTitle(''), isNull);
    final long = suggestTitle('This is a very long first line of a document that keeps going on and on without an end in sight');
    expect(long, isNotNull);
    expect(long!.length <= 60, isTrue);
    expect(long.endsWith(' '), isFalse);
  });

  test('runs of busy days', () {
    final taken = <DateTime>[
      for (var i = 0; i < 8; i++) DateTime(2026, 8, 12, 9, i),
      for (var i = 0; i < 9; i++) DateTime(2026, 8, 13, 9, i),
      // the 14th is quiet
      for (var i = 0; i < 7; i++) DateTime(2026, 8, 15, 9, i),
      for (var i = 0; i < 3; i++) DateTime(2026, 9, 1, 9, i), // an ordinary day
      for (var i = 0; i < 10; i++) DateTime(2026, 10, 2, 9, i), // one busy day, too few in all
    ];
    final runs = busyRuns(taken);
    expect(runs.length, 1);
    expect(runs.single.from, DateTime(2026, 8, 12));
    expect(runs.single.to, DateTime(2026, 8, 15));
    expect(runs.single.count, 24);
    expect(runs.single.label, '12–15 Aug 2026');
    expect(BusyRun(DateTime(2026, 8, 30), DateTime(2026, 9, 2), 30).label, '30 Aug – 2 Sep 2026');
  });
}
