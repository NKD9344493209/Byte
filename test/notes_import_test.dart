import 'dart:convert';
import 'dart:typed_data';

import 'package:byte/features/notes/notes_import.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('plain text / markdown', () {
    test('short first line becomes the title', () {
      final n = NotesImport.parseText('a.txt', 'Dosa batter\r\n\r\n3 cups rice\n1 cup urad')!;
      expect(n.title, 'Dosa batter');
      expect(n.body, '3 cups rice\n1 cup urad');
    });
    test('markdown heading loses the #', () {
      final n = NotesImport.parseText('x.md', '# Rent\npay by 5th')!;
      expect(n.title, 'Rent');
      expect(n.body, 'pay by 5th');
    });
    test('one long line → file name is the title', () {
      final long = 'a' * 120;
      final n = NotesImport.parseText('Shopping_list.txt', long)!;
      expect(n.title, 'Shopping list');
      expect(n.body, long);
    });
    test('one short line → it is the title, empty body', () {
      final n = NotesImport.parseText('a.txt', 'Call amma')!;
      expect(n.title, 'Call amma');
      expect(n.body, '');
    });
    test('empty file → nothing', () {
      expect(NotesImport.parseText('a.txt', '  \n '), isNull);
    });
  });

  group('google keep', () {
    test('json with list and labels', () {
      final j = jsonEncode({
        'title': 'Groceries',
        'listContent': [
          {'text': 'milk', 'isChecked': true},
          {'text': 'eggs', 'isChecked': false},
        ],
        'labels': [
          {'name': 'home'}
        ],
        'isTrashed': false,
      });
      final n = NotesImport.parseKeepJson('g.json', j)!;
      expect(n.title, 'Groceries');
      expect(n.body, '☑ milk\n☐ eggs');
      expect(n.tags, ['home']);
    });
    test('trashed notes are skipped', () {
      expect(NotesImport.parseKeepJson('g.json', '{"title":"x","textContent":"y","isTrashed":true}'), isNull);
    });
    test('html export', () {
      const html = '''
<html><head><title>Hackathon ideas</title></head><body>
<div class="heading">Mar 3, 2026</div>
<div class="title">Hackathon ideas</div>
<div class="content">voice first app<br>offline &amp; fast</div>
<div class="labels"><span class="label-name">work</span></div>
</body></html>''';
      final n = NotesImport.parseHtml('h.html', html)!;
      expect(n.title, 'Hackathon ideas');
      expect(n.body, contains('voice first app\noffline & fast'));
      expect(n.body, isNot(contains('Mar 3')));
      expect(n.tags, ['work']);
    });
  });

  group('files', () {
    test('unsupported extension is empty', () {
      expect(NotesImport.parseFile('a.pdf', Uint8List.fromList([1, 2, 3])), isEmpty);
    });
    test('supported()', () {
      expect(NotesImport.supported('Takeout.zip'), isTrue);
      expect(NotesImport.supported('note.MD'), isTrue);
      expect(NotesImport.supported('photo.jpg'), isFalse);
    });
  });
}
