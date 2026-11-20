import 'package:byte/core/gallery.dart';
import 'package:byte/features/library/library_item.dart';
import 'package:byte/features/search/search_text.dart';
import 'package:byte/features/search/words.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('wordsOf', () {
    test('lower-case, 3 letters or more, each once', () {
      expect(wordsOf('The Photosynthesis process. THE process, of X1!'), {'the', 'photosynthesis', 'process'});
    });

    test('numbers count as words; other alphabets too', () {
      expect(wordsOf('Roll no 21MDC045, ₹1500'), {'roll', '21mdc045', '1500'});
      expect(wordsOf('வணக்கம் நண்பா'), {'வணக்கம்', 'நண்பா'});
    });

    test('stops at the limit', () {
      expect(wordsOf('aaa bbb ccc ddd', max: 2).length, 2);
      expect(wordsOf(''), isEmpty);
    });
  });

  group('editDistance', () {
    test('one slip: missing, extra, wrong, swapped', () {
      expect(editDistance('photosynthsis', 'photosynthesis'), 1);
      expect(editDistance('aadhar', 'aadhaar'), 1);
      expect(editDistance('marks', 'narks'), 1);
      expect(editDistance('recieve', 'receive'), 1);
      expect(editDistance('same', 'same'), 0);
    });

    test('gives up early when clearly too far', () {
      expect(editDistance('kitten', 'sitting'), 3);
      expect(editDistance('abc', 'abcdefgh'), 3);
      expect(editDistance('abcd', 'xyzw', max: 1), 2);
    });
  });

  group('nearWords', () {
    const vocab = ['photosynthesis', 'physics', 'physical', 'marks', 'parks', 'mark'];

    test('short words are never guessed', () {
      expect(allowedSlips(3), 0);
      expect(allowedSlips(5), 1);
      expect(allowedSlips(9), 2);
      expect(nearWords('mrk', vocab), isEmpty);
    });

    test('closest first; same first letter wins a tie', () {
      expect(nearWords('photosynthsis', vocab), ['photosynthesis']);
      expect(nearWords('physcis', vocab), ['physics']);
      expect(nearWords('narks', vocab).take(2).toList(), ['marks', 'parks']);
      expect(nearWords('barks', vocab, take: 1).length, 1);
    });

    test('nothing near → empty; the word itself is not a suggestion', () {
      expect(nearWords('biryani', vocab), isEmpty);
      expect(nearWords('marks', vocab), ['mark', 'parks']);
    });
  });

  group('sinceFor (Search time filters)', () {
    final now = DateTime(2026, 11, 18, 15, 30);

    test('week = the last 7 days, month and year from their first day', () {
      expect(sinceFor('week', now: now), DateTime(2026, 11, 12));
      expect(sinceFor('month', now: now), DateTime(2026, 11));
      expect(sinceFor('year', now: now), DateTime(2026));
      expect(sinceFor('any', now: now), isNull);
    });
  });

  group('GalleryEntry.fromMap', () {
    final now = DateTime(2026, 11, 18, 12);

    test('a photo row', () {
      final e = GalleryEntry.fromMap(
        'image',
        {
          'id': 42,
          'path': '/storage/emulated/0/DCIM/Camera/IMG_1.jpg',
          'name': 'IMG_1.jpg',
          'mime': 'image/jpeg',
          'size': 1234,
          'taken': DateTime(2026, 11, 1, 9).millisecondsSinceEpoch,
          'added': 1,
          'modified': 1,
          'bucket': 'Camera',
          'duration': 0,
        },
        now: now,
      )!;
      expect(e.key, 'image:42');
      expect(e.libraryKind, LibraryKind.photo);
      expect(e.when, DateTime(2026, 11, 1, 9));
      expect(e.bucket, 'Camera');
      expect(e.size, 1234);
    });

    test('no "taken" date → last changed, then added; never a nonsense date', () {
      final modified = DateTime(2026, 10, 5).millisecondsSinceEpoch ~/ 1000;
      final a = GalleryEntry.fromMap('video', {'id': 7, 'path': '/x/v.mp4', 'taken': 0, 'modified': modified, 'added': 5}, now: now)!;
      expect(a.libraryKind, LibraryKind.video);
      expect(a.when, DateTime.fromMillisecondsSinceEpoch(modified * 1000));
      expect(a.name, 'v.mp4');

      final future = now.add(const Duration(days: 400)).millisecondsSinceEpoch;
      final b = GalleryEntry.fromMap('image', {'id': 8, 'path': '/x/p.jpg', 'taken': future, 'modified': 0, 'added': 0}, now: now)!;
      expect(b.when, now);
    });

    test('unusable rows are skipped', () {
      expect(GalleryEntry.fromMap('image', {'id': 1, 'path': ''}), isNull);
      expect(GalleryEntry.fromMap('image', {'path': '/x/p.jpg'}), isNull);
    });

    test('a call recording is audio; a comma in the album name cannot split the tags', () {
      final e = GalleryEntry.fromMap('audio', {'id': 3, 'path': '/x/call_rec/a.m4a', 'bucket': 'Calls, 2026'}, now: now)!;
      expect(e.libraryKind, LibraryKind.audio);
      expect(e.bucket, 'Calls  2026');
      expect(e.key, 'audio:3');
    });
  });
}
