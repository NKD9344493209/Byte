import 'package:byte/features/voice/heard.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('learnFixes', () {
    test('one wrong word', () {
      expect(learnFixes('meet me at karpagam college', 'meet me at Karpagam college'), isEmpty); // only a capital
      expect(learnFixes('submit the wreckered tomorrow', 'submit the record tomorrow'), {'wreckered': 'record'});
    });

    test('a phrase heard as other words', () {
      expect(learnFixes('print the hall take it today', 'print the hall ticket today'), {'take it': 'ticket'});
      expect(learnFixes('call sandy rue now', 'call Sandhru now'), {'sandy rue': 'Sandhru'});
    });

    test('punctuation and added sentences teach nothing', () {
      expect(learnFixes('buy rice call amma', 'Buy rice. Call amma.'), isEmpty);
      expect(learnFixes('buy rice', 'buy rice and also pay the fee'), isEmpty);
      expect(learnFixes('', 'x'), isEmpty);
    });

    test('a change of mind is not a mis-hearing', () {
      expect(learnFixes('go to the market today', 'go to the shop today'), isEmpty);
      expect(learnFixes('meet on monday evening', 'meet on tuesday evening'), isEmpty);
      expect(looksMisheard('take it', 'ticket'), isTrue);
      expect(looksMisheard('there', 'their'), isTrue);
      expect(looksMisheard('big', 'large'), isFalse);
    });

    test('tiny and very common words are never learned alone', () {
      expect(learnFixes('go to the bank', 'go to a bank'), isEmpty);
      expect(learnFixes('that is fine', 'this is fine'), isEmpty);
    });
  });

  group('applyFixes', () {
    const fixes = {'wreckered': 'record', 'take it': 'ticket', 'sandy rue': 'Sandhru'};

    test('whole words, any case, phrases too', () {
      expect(applyFixes('Wreckered book and hall take it', fixes), ('record book and hall ticket', 2));
      expect(applyFixes('ask sandy  rue', fixes), ('ask Sandhru', 1));
    });

    test('never inside another word', () {
      expect(applyFixes('wreckeredness', fixes), ('wreckeredness', 0));
      expect(applyFixes('', fixes), ('', 0));
      expect(applyFixes('nothing here', const {}), ('nothing here', 0));
    });
  });
}
