import 'package:byte/features/voice/dictation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DictationButton.clean', () {
    test('spoken punctuation', () {
      expect(DictationButton.clean('buy milk comma eggs full stop'), 'buy milk, eggs.');
      expect(DictationButton.clean('first line new line second line'), 'first line\nsecond line');
      expect(DictationButton.clean('are you coming question mark'), 'are you coming?');
      expect(DictationButton.clean('  hello   world  '), 'hello world');
    });
    test('stop words', () {
      expect(DictationButton.isStop('stop'), isTrue);
      expect(DictationButton.isStop('Stop dictation.'), isTrue);
      expect(DictationButton.isStop('stop the bus'), isFalse);
    });
  });

  group('DictationButton.insert', () {
    test('empty field → capitalized, cursor at end', () {
      final v = DictationButton.insert(const TextEditingValue(text: ''), 'hello there');
      expect(v.text, 'Hello there');
      expect(v.selection.baseOffset, 11);
    });
    test('continues a sentence with a space, no capital', () {
      final v = DictationButton.insert(const TextEditingValue(text: 'Buy milk', selection: TextSelection.collapsed(offset: 8)), 'and eggs');
      expect(v.text, 'Buy milk and eggs');
    });
    test('after a full stop → capital', () {
      final v = DictationButton.insert(const TextEditingValue(text: 'Done.', selection: TextSelection.collapsed(offset: 5)), 'next task');
      expect(v.text, 'Done. Next task');
    });
    test('inserts in the middle with spacing', () {
      final v = DictationButton.insert(const TextEditingValue(text: 'Hello world', selection: TextSelection.collapsed(offset: 5)), 'big');
      expect(v.text, 'Hello big world');
      expect(v.selection.baseOffset, 9);
    });
    test('punctuation piece attaches without a space', () {
      final v = DictationButton.insert(const TextEditingValue(text: 'Hello', selection: TextSelection.collapsed(offset: 5)), '.');
      expect(v.text, 'Hello.');
    });
    test('no selection → appends at the end', () {
      final v = DictationButton.insert(const TextEditingValue(text: 'Line one\n'), 'line two');
      expect(v.text, 'Line one\nLine two');
    });
  });
}
