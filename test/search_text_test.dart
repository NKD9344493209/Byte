import 'package:byte/features/library/library_item.dart';
import 'package:byte/features/search/search_text.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('queryWords', () {
    test('lower-case words, no empties', () {
      expect(queryWords('  Physics   PAPER '), ['physics', 'paper']);
      expect(queryWords('   '), isEmpty);
    });
  });

  group('findHit', () {
    test('finds one word inside a long text, any letter case', () {
      final hit = findHit('Unit 3\nExplain the Photosynthesis process in plants.', 'photosynthesis');
      expect(hit, isNotNull);
      expect(hit!.match, 'Photosynthesis');
      expect(hit.before, 'Unit 3 Explain the ');
      expect(hit.after, ' process in plants.');
      expect(hit.page, isNull);
    });

    test('says which page of a document the word is on', () {
      final text = joinPages(['alpha one', 'beta two', 'gamma three']);
      expect(findHit(text, 'alpha')!.page, 1);
      expect(findHit(text, 'beta')!.page, 2);
      expect(findHit(text, 'gamma')!.page, 3);
    });

    test('an empty page still counts, so page numbers stay right', () {
      final text = joinPages(['cover', '', 'question seven']);
      expect(findHit(text, 'seven')!.page, 3);
    });

    test('your own word first, a synonym only when the word is not there', () {
      expect(findHit('dog, grass, animal', 'animal')!.match, 'animal');
      expect(findHit('dog, grass', 'animal')!.match, 'dog');
    });

    test('nothing to find', () {
      expect(findHit('some text', ''), isNull);
      expect(findHit('', 'word'), isNull);
      expect(findHit('some text', 'biryani'), isNull);
    });

    test('long text is cut to a short line around the match', () {
      final text = '${'a' * 200} needle ${'b' * 200}';
      final hit = findHit(text, 'needle')!;
      expect(hit.before.length, 40);
      expect(hit.after.length, 70);
    });

    test('the cut never lands in the middle of an emoji', () {
      // An emoji is two code units; a cut between them would show a broken letter.
      expect(findHit('\u{1F600}${'a' * 39}needle', 'needle')!.before, 'a' * 39);
      expect(findHit('needle${'b' * 69}\u{1F600}tail', 'needle')!.after, 'b' * 69);
    });
  });

  group('splitMatches', () {
    test('marks the matching piece', () {
      expect(splitMatches('Physics question paper', ['question']), [('Physics ', false), ('question', true), (' paper', false)]);
    });

    test('every place, any letter case', () {
      expect(splitMatches('Question QUESTION', ['question']), [('Question', true), (' ', false), ('QUESTION', true)]);
    });

    test('no words, or no match → one plain piece', () {
      expect(splitMatches('abc', const []), [('abc', false)]);
      expect(splitMatches('abc', ['x']), [('abc', false)]);
    });
  });

  group('pages', () {
    test('joinPages tidies each page and drops empty pages at the end', () {
      expect(joinPages(['a   b', 'c']), 'a b${pageBreak}c');
      expect(joinPages(['a', '', '']), 'a');
      expect(joinPages(const []), '');
    });

    test('a page break typed inside a page cannot shift the numbering', () {
      expect(joinPages(['a${pageBreak}b']), 'a b');
    });

    test('a huge document stops at the limit', () {
      expect(joinPages(['abcdef', 'ghi'], maxChars: 4), 'abcd');
      expect(joinPages(['ab', 'cdef'], maxChars: 4), 'ab${pageBreak}c');
    });

    test('pageCount', () {
      expect(pageCount(''), 0);
      expect(pageCount('abc'), 1);
      expect(pageCount(joinPages(['a', 'b', 'c'])), 3);
    });

    test('looksScanned: a page that gave almost no text', () {
      expect(looksScanned(''), isTrue);
      expect(looksScanned('  \n 12 '), isTrue);
      expect(looksScanned('This page has real words on it'), isFalse);
    });

    test('readablePages puts "Page N" before each page that has words', () {
      expect(readablePages('plain text'), 'plain text');
      expect(readablePages(joinPages(['one', '', 'three'])), 'Page 1\none\n\nPage 3\nthree');
    });
  });

  group('hitIn', () {
    LibraryItem item({String text = '', String body = '', List<String> labels = const []}) => LibraryItem(
          id: '1',
          kind: LibraryKind.doc,
          title: 'Paper',
          tags: const [],
          createdAt: DateTime(2026),
          text: text,
          body: body,
          labels: labels,
        );

    test('the text read from it first, then your note, then what BYTE saw', () {
      expect(hitIn(item(text: 'marks sheet', body: 'marks are low'), 'marks')!.after, ' sheet');
      expect(hitIn(item(body: 'ask sir about marks'), 'marks')!.before, 'ask sir about ');
      expect(hitIn(item(labels: ['dog', 'grass']), 'grass')!.match, 'grass');
    });

    test('null when only the title could match', () {
      expect(hitIn(item(text: 'other words'), 'paper'), isNull);
    });
  });
}
