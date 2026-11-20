import 'package:byte/features/notes/note.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Note', () {
    test('displayTitle falls back to first body line', () {
      final n = Note(
        id: '1',
        title: '',
        body: '\n  \nMovie idea about a bike\nmore',
        tags: const [],
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      );
      expect(n.displayTitle, 'Movie idea about a bike');
    });

    test('round-trips through a DB row', () {
      final n = Note(
        id: 'abc',
        title: 'T',
        body: 'B',
        tags: const ['idea', 'song'],
        createdAt: DateTime(2026, 1, 2),
        updatedAt: DateTime(2026, 1, 3),
      );
      final back = Note.fromRow(n.toRow());
      expect(back.id, 'abc');
      expect(back.tags, ['idea', 'song']);
      expect(back.createdAt, DateTime(2026, 1, 2));
    });
  });
}
