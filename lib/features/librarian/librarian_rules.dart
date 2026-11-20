/// The librarian's rules — pure functions (no Flutter, no database), so
/// they are unit-tested. Everything here works on the phone, from what BYTE
/// already read: names, the words inside files, and what photos show.
library;

/// A folder BYTE may suggest, and the words that put a file into it.
class FolderRule {
  const FolderRule(this.name, this.words, {this.labels = const [], this.nameHints = const []});

  /// The folder's name, as suggested ("Bills & receipts").
  final String name;

  /// Any of these inside the file's words or name is a match (lower-case).
  final List<String> words;

  /// Any of these among what a photo shows (lower-case labels).
  final List<String> labels;

  /// Any of these inside the file's own name / place (lower-case).
  final List<String> nameHints;
}

/// In order: the first rule that matches wins.
const folderRules = <FolderRule>[
  FolderRule('ID cards', ['aadhaar', 'aadhar', 'uidai', 'permanent account number', 'income tax department', 'passport', 'driving licence', 'driving license', 'voter', 'election commission']),
  FolderRule('College', ['hall ticket', 'question paper', 'semester', 'syllabus', 'assignment', 'internal assessment', 'register number', 'reg. no', 'mark sheet', 'marksheet', 'grade sheet', 'time table', 'timetable', 'university', 'examination']),
  FolderRule('Certificates', ['certificate', 'this is to certify', 'awarded to', 'has successfully completed', 'certificate of']),
  FolderRule('Bills & receipts', ['invoice', 'receipt', 'gstin', 'bill no', 'amount paid', 'total amount', 'payment successful', 'paid to', 'transaction id', 'upi ref', 'order id']),
  FolderRule('Bank', ['account statement', 'ifsc', 'account number', 'a/c no', 'passbook', 'cheque']),
  FolderRule('Tickets & travel', ['pnr no', 'pnr:', 'boarding pass', 'irctc', 'e-ticket', 'seat no', 'redbus']),
  FolderRule('Screenshots', [], nameHints: ['screenshot', 'screen_shot', 'screen shot']),
  FolderRule('Food', [], labels: ['food', 'dish', 'cuisine', 'meal', 'dessert']),
  FolderRule('Pets & animals', [], labels: ['dog', 'cat', 'puppy', 'kitten', 'pet', 'bird']),
];

/// Which suggested folder a file belongs in, or null. [text] = the words
/// read inside it, [labels] = what a photo shows, [name] = its title and its
/// file name.
String? folderFor({required String name, String text = '', List<String> labels = const []}) {
  final hayName = name.toLowerCase();
  final hay = '$hayName\n${text.toLowerCase()}';
  final lab = {for (final l in labels) l.toLowerCase().trim()};
  for (final r in folderRules) {
    if (r.nameHints.any(hayName.contains)) return r.name;
    if (r.words.any(hay.contains)) return r.name;
    if (r.labels.any(lab.contains)) return r.name;
  }
  return null;
}

final RegExp _cameraName = RegExp(
  r'^(img|vid|dsc|dscn|pxl|mvimg|image|photo|video|scan|doc|document|file|screenshot|screen_shot|wp|whatsapp image|whatsapp video|untitled|new doc|camscanner|adobe scan)?[\s_\-.]*[\d\s_\-.()]*(wa\d+)?$',
  caseSensitive: false,
);

/// A name that says nothing: "IMG_20260812_101500", "Screenshot_2026…",
/// "scan0001", "Voice note · 3/8 10:15 am", or no name at all.
bool looksUnnamed(String title) {
  final t = title.trim();
  if (t.isEmpty) return true;
  if (t.startsWith('Voice note ·')) return true;
  return _cameraName.hasMatch(t);
}

/// A name made from the words inside a file: its first line that reads like
/// a heading (at least two letters-words, not just numbers), cut to a
/// sensible length. null when nothing in [text] is good enough.
String? suggestTitle(String text) {
  for (final raw in text.split('\n').take(12)) {
    var line = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    // "Page 1:" marks added by the PDF reader are not part of the document.
    line = line.replaceFirst(RegExp(r'^\[?page \d+\]?:?\s*', caseSensitive: false), '');
    if (line.length < 6) continue;
    // (Letters and their marks: in Tamil or Hindi a vowel sign is a mark, not a letter.)
    final words = line.split(' ').where((w) => RegExp(r'[\p{L}\p{M}]{2,}', unicode: true).hasMatch(w)).toList();
    if (words.length < 2) continue;
    final letters = RegExp(r'[\p{L}\p{M}]', unicode: true).allMatches(line).length;
    if (letters < line.length * 0.5) continue; // mostly digits and signs
    if (line.length > 60) {
      final cut = line.substring(0, 60);
      final at = cut.lastIndexOf(' ');
      line = at > 30 ? cut.substring(0, at) : cut;
    }
    return line.replaceAll(RegExp(r'[\s,;:.\-–—]+$'), '');
  }
  return null;
}

/// A run of days with many photos — a trip, a function, a tour.
class BusyRun {
  const BusyRun(this.from, this.to, this.count);

  /// First and last day (midnight, local time).
  final DateTime from;
  final DateTime to;
  final int count;

  /// "12–15 Aug 2026", "30 Aug – 2 Sep 2026", "12 Aug 2026".
  String get label {
    const m = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    if (from == to) return '${from.day} ${m[from.month - 1]} ${from.year}';
    if (from.month == to.month && from.year == to.year) return '${from.day}–${to.day} ${m[to.month - 1]} ${to.year}';
    if (from.year == to.year) return '${from.day} ${m[from.month - 1]} – ${to.day} ${m[to.month - 1]} ${to.year}';
    return '${from.day} ${m[from.month - 1]} ${from.year} – ${to.day} ${m[to.month - 1]} ${to.year}';
  }

  /// A stable name for remembering "not this one".
  String get key => '${from.year}-${from.month}-${from.day}';
}

/// Finds the runs: days in a row (a gap of one quiet day is allowed) on
/// which you took at least [perDay] photos, [minTotal] or more in all, and
/// no longer than [maxDays] (longer is just "life", not a trip).
List<BusyRun> busyRuns(Iterable<DateTime> taken, {int perDay = 6, int minTotal = 20, int maxDays = 21}) {
  final perDayCount = <DateTime, int>{};
  for (final t in taken) {
    final d = DateTime(t.year, t.month, t.day);
    perDayCount[d] = (perDayCount[d] ?? 0) + 1;
  }
  final busy = perDayCount.keys.where((d) => perDayCount[d]! >= perDay).toList()..sort();
  final out = <BusyRun>[];
  var i = 0;
  while (i < busy.length) {
    var j = i;
    // (Rounded: a day is 23 or 25 hours long when the clocks change.)
    while (j + 1 < busy.length && (busy[j + 1].difference(busy[j]).inHours / 24).round() <= 2) {
      j++;
    }
    final from = busy[i];
    final to = busy[j];
    final days = (to.difference(from).inHours / 24).round() + 1;
    var count = 0;
    for (final e in perDayCount.entries) {
      if (!e.key.isBefore(from) && !e.key.isAfter(to)) count += e.value;
    }
    if (count >= minTotal && days <= maxDays) out.add(BusyRun(from, to, count));
    i = j + 1;
  }
  return out;
}

/// When an item set to "delete itself after…" is due: [days] after [from].
DateTime expiryAfter(DateTime from, int days) => from.add(Duration(days: days));
