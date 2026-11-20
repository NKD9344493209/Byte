/// A call recording's file name, as people would say it.
///
/// Dialers name the file after who was on the line and when:
///   Amma(9876543210)_20261119153012   →  Call with Amma
///   9876543210_20261119153012         →  Call with 9876543210
/// A name that does not look like that is left as it is. (The day and time
/// are not repeated in the name: every list shows them already.)
String callTitle(String fileName) {
  final s = fileName.trim();
  final m = RegExp(r'^(.*?)[ _-]*\d{8}[ _-]?\d{6}$').firstMatch(s);
  if (m == null) return s;
  var who = m.group(1)!.trim();
  // "Call recording Ravi", "call_rec_Ravi": the words before the name go.
  who = who.replaceFirst(RegExp(r'^(?:call[ _-]?recording|call[ _-]?rec)(?:[ _-]+|$)', caseSensitive: false), '').trim();
  final numbered = RegExp(r'^(.*?)\s*\(([+\d][\d\s-]*)\)$').firstMatch(who);
  if (numbered != null) {
    final name = numbered.group(1)!.trim();
    who = name.isEmpty ? numbered.group(2)!.trim() : name;
  }
  return who.isEmpty ? 'Call recording' : 'Call with $who';
}
