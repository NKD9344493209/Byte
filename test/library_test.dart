import 'package:byte/features/library/library_item.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('LibraryKind', () {
    test('guesses kind from file name', () {
      expect(LibraryKindX.forPath('IMG_2026.JPG'), LibraryKind.photo);
      expect(LibraryKindX.forPath('clip.mp4'), LibraryKind.video);
      expect(LibraryKindX.forPath('note.wav'), LibraryKind.audio);
      expect(LibraryKindX.forPath('marks.pdf'), LibraryKind.doc);
      expect(LibraryKindX.forPath('deck.pptx'), LibraryKind.doc);
    });
  });

  group('search synonyms', () {
    test('animal expands to common animals', () {
      final w = expandQueryWord('animal');
      expect(w, contains('dog'));
      expect(w, contains('cat'));
      expect(w, contains('animal'));
    });

    test('aadhar expands to the words printed on the card', () {
      final w = expandQueryWord('aadhar');
      expect(w, contains('uidai'));
      expect(w, contains('aadhaar'));
    });

    test('unknown words stay as they are', () {
      expect(expandQueryWord('Biryani'), ['biryani']);
      expect(expandQueryWord('  '), isEmpty);
    });
  });

  test('humanSize', () {
    expect(humanSize(512), '512 B');
    expect(humanSize(20 * 1024), '20 KB');
    expect(humanSize(3 * 1024 * 1024 + 200 * 1024), '3.2 MB');
  });

  test('displayTitle falls back sensibly', () {
    final link = LibraryItem(
      id: '1', kind: LibraryKind.link, title: '', tags: const [], createdAt: DateTime(2026), url: 'https://youtu.be/x',
    );
    expect(link.displayTitle, 'https://youtu.be/x');
    final file = LibraryItem(
      id: '2', kind: LibraryKind.doc, title: '', tags: const [], createdAt: DateTime(2026), path: '/a/b/marks.pdf',
    );
    expect(file.displayTitle, 'marks.pdf');
    expect(file.ext, 'pdf');
  });
}
