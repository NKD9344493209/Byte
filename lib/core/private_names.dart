/// Small pure helpers of the private space (no Flutter, no database), so
/// they can be unit-tested and used from anywhere.
library;

import 'dart:math' as math;

/// A locked (encrypted) file keeps its name and gets this ending:
/// `ab12.jpg` → `ab12.jpg.bytelock`.
const sealedExt = '.bytelock';

bool isSealedPath(String path) => path.toLowerCase().endsWith(sealedExt);

/// The name a file gets when it is locked.
String sealedPath(String path) => isSealedPath(path) ? path : '$path$sealedExt';

/// The name it had (and gets back) when it is open.
String plainPath(String path) => isSealedPath(path) ? path.substring(0, path.length - sealedExt.length) : path;

/// A PIN people can type on a number pad: 4 to 12 digits.
bool isValidPin(String pin) => RegExp(r'^\d{4,12}$').hasMatch(pin);

/// Too easy to guess: one digit repeated (0000), or a straight run up or
/// down (1234, 9876).
bool isWeakPin(String pin) {
  if (pin.length < 4) return true;
  final d = pin.codeUnits;
  var same = true;
  var up = true;
  var down = true;
  for (var i = 1; i < d.length; i++) {
    if (d[i] != d[0]) same = false;
    if (d[i] != d[i - 1] + 1) up = false;
    if (d[i] != d[i - 1] - 1) down = false;
  }
  return same || up || down;
}

/// How long to wait before the next try after [fails] wrong PINs in a row:
/// nothing for the first four, then 30 s, 1 min, 2 min… up to 15 minutes.
int waitSecondsAfter(int fails) {
  if (fails < 5) return 0;
  final steps = math.min(fails - 5, 5);
  return math.min(30 * (1 << steps), 900);
}

/// "45 seconds", "2 minutes" — for the lock screen.
String waitText(int seconds) {
  if (seconds < 60) return '$seconds second${seconds == 1 ? '' : 's'}';
  final m = (seconds / 60).ceil();
  return '$m minute${m == 1 ? '' : 's'}';
}
