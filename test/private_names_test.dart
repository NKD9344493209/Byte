import 'package:byte/core/private_names.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('locked names', () {
    expect(sealedPath('/a/b/x.jpg'), '/a/b/x.jpg.bytelock');
    expect(sealedPath('/a/b/x.jpg.bytelock'), '/a/b/x.jpg.bytelock');
    expect(plainPath('/a/b/x.jpg.bytelock'), '/a/b/x.jpg');
    expect(plainPath('/a/b/x.jpg'), '/a/b/x.jpg');
    expect(isSealedPath('/a/x.PDF.BYTELOCK'), isTrue);
    expect(isSealedPath('/a/x.pdf'), isFalse);
    expect(isSealedPath(''), isFalse);
  });

  test('PIN rules', () {
    expect(isValidPin('1234'), isTrue);
    expect(isValidPin('123'), isFalse);
    expect(isValidPin('12a4'), isFalse);
    expect(isValidPin('1234567890123'), isFalse);
    expect(isWeakPin('0000'), isTrue);
    expect(isWeakPin('1234'), isTrue);
    expect(isWeakPin('9876'), isTrue);
    expect(isWeakPin('4821'), isFalse);
    expect(isWeakPin('1235'), isFalse);
  });

  test('waiting after wrong PINs', () {
    expect(waitSecondsAfter(0), 0);
    expect(waitSecondsAfter(4), 0);
    expect(waitSecondsAfter(5), 30);
    expect(waitSecondsAfter(6), 60);
    expect(waitSecondsAfter(7), 120);
    expect(waitSecondsAfter(10), 900);
    expect(waitSecondsAfter(50), 900);
    expect(waitText(30), '30 seconds');
    expect(waitText(1), '1 second');
    expect(waitText(60), '1 minute');
    expect(waitText(61), '2 minutes');
  });
}
