import 'package:byte/core/call_names.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('who was on the line', () {
    expect(callTitle('Amma(9876543210)_20261119153012'), 'Call with Amma');
    expect(callTitle('9876543210_20261119153012'), 'Call with 9876543210');
    expect(callTitle('(9876543210)_20261119153012'), 'Call with 9876543210');
    expect(callTitle('Call recording Ravi Kumar_20261119_153012'), 'Call with Ravi Kumar');
    expect(callTitle('_20261119153012'), 'Call recording');
  });

  test('a name that is not a call recording stays as it is', () {
    expect(callTitle('My song'), 'My song');
    expect(callTitle('Callum birthday'), 'Callum birthday');
  });
}
