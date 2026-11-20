/// "BYTE learns your words" — pure text handling, unit-tested.
///
/// When you correct a voice note ("hall take it" → "hall ticket"), the pair
/// is remembered. The next voice note is corrected the same way by itself,
/// and the words you meant are also given to the speech engine as hints.
library;

final RegExp _edge = RegExp(r'^[^\p{L}\p{N}]+|[^\p{L}\p{N}]+$', unicode: true);

/// A word as it is compared: lower-case, without commas/full stops around it.
String _plain(String w) => w.toLowerCase().replaceAll(_edge, '');

List<String> _tokens(String s) => s.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();

/// Too common to ever replace everywhere just because it was changed once.
const _never = {
  'the', 'and', 'for', 'that', 'this', 'with', 'have', 'from', 'they', 'will', 'what', 'when', 'your', 'there', 'their',
  'then', 'than', 'them', 'were', 'been', 'into', 'some', 'also', 'just', 'about', 'which', 'would', 'could', 'should',
};

const _facts = {
  'monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday', 'sunday', 'today', 'tomorrow', 'yesterday',
  'january', 'february', 'march', 'april', 'may', 'june', 'july', 'august', 'september', 'october', 'november', 'december',
  'one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight', 'nine', 'ten', 'eleven', 'twelve', 'thirteen', 'fourteen',
  'fifteen', 'sixteen', 'seventeen', 'eighteen', 'nineteen', 'twenty', 'thirty', 'forty', 'fifty', 'sixty', 'seventy', 'eighty',
  'ninety', 'hundred', 'thousand', 'lakh', 'crore', 'morning', 'evening', 'afternoon', 'night',
};

/// Letters and digits only, lower-case: "Take it" → "takeit".
String _letters(String s) => s.toLowerCase().replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '');

/// How many single-letter changes turn [a] into [b].
int _letterDistance(String a, String b) {
  final x = a.runes.toList();
  final y = b.runes.toList();
  var prev = List<int>.generate(y.length + 1, (j) => j);
  for (var i = 1; i <= x.length; i++) {
    final cur = List<int>.filled(y.length + 1, 0);
    cur[0] = i;
    for (var j = 1; j <= y.length; j++) {
      final swap = prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1);
      final del = prev[j] + 1;
      final ins = cur[j - 1] + 1;
      cur[j] = swap < del ? (swap < ins ? swap : ins) : (del < ins ? del : ins);
    }
    prev = cur;
  }
  return prev[y.length];
}

/// A mis-hearing looks like the word that was meant ("take it" / "ticket",
/// "wreckered" / "record"). A change of mind does not ("market" → "shop"):
/// that is your wording, not something to repeat in every later note.
bool looksMisheard(String heard, String meant) {
  final a = _letters(heard);
  final b = _letters(meant);
  if (a.isEmpty || b.isEmpty) return false;
  // Days, months and numbers look alike ("monday" / "sunday", "five" /
  // "nine") but swapping one for another is a change of fact, not of hearing.
  if (_facts.contains(a) && _facts.contains(b)) return false;
  final longer = a.length > b.length ? a.length : b.length;
  final allowed = (longer * 0.55).floor();
  return _letterDistance(a, b) <= (allowed < 2 ? 2 : allowed);
}

/// What changed between what BYTE [heard] and what you [corrected] it to:
/// heard words → meant words. Only real word swaps are learned — one to
/// three words replaced by one to three words that look alike. Added or
/// removed sentences, changes to tiny or very common words, and words you
/// simply replaced by other words teach nothing.
Map<String, String> learnFixes(String heard, String corrected) {
  final a = _tokens(heard);
  final b = _tokens(corrected);
  if (a.isEmpty || b.isEmpty) return const {};
  if (a.length > 600 || b.length > 600) return const {}; // a whole essay rewritten is not a correction
  final pa = [for (final w in a) _plain(w)];
  final pb = [for (final w in b) _plain(w)];

  // Longest common run of words, by the classic table.
  final n = pa.length;
  final m = pb.length;
  final t = List.generate(n + 1, (_) => List<int>.filled(m + 1, 0));
  for (var i = n - 1; i >= 0; i--) {
    for (var j = m - 1; j >= 0; j--) {
      t[i][j] = pa[i] == pb[j] ? t[i + 1][j + 1] + 1 : (t[i + 1][j] >= t[i][j + 1] ? t[i + 1][j] : t[i][j + 1]);
    }
  }

  final out = <String, String>{};
  var i = 0;
  var j = 0;
  var from = <String>[];
  var to = <String>[];
  void close() {
    if (from.isNotEmpty && to.isNotEmpty && from.length <= 3 && to.length <= 3) {
      final key = from.join(' ');
      final value = to.join(' ');
      final worthIt = from.length > 1 || (key.length >= 4 && !_never.contains(key));
      if (key != value && worthIt && key.isNotEmpty && value.isNotEmpty && looksMisheard(key, value)) out[key] = value;
    }
    from = <String>[];
    to = <String>[];
  }

  while (i < n && j < m) {
    if (pa[i] == pb[j]) {
      close();
      i++;
      j++;
    } else if (t[i + 1][j] >= t[i][j + 1]) {
      if (pa[i].isNotEmpty) from.add(pa[i]);
      i++;
    } else {
      // The meant words keep their capitals ("Karpagam"), minus punctuation.
      final w = b[j].replaceAll(_edge, '');
      if (w.isNotEmpty) to.add(w);
      j++;
    }
  }
  while (i < n) {
    if (pa[i].isNotEmpty) from.add(pa[i]);
    i++;
  }
  while (j < m) {
    final w = b[j].replaceAll(_edge, '');
    if (w.isNotEmpty) to.add(w);
    j++;
  }
  close();
  return out;
}

/// [text] with every learned fix applied (whole words, any letter case,
/// longer phrases first). Returns the text and how many places changed.
(String, int) applyFixes(String text, Map<String, String> fixes) {
  if (text.isEmpty || fixes.isEmpty) return (text, 0);
  final keys = fixes.keys.toList()..sort((x, y) => y.length.compareTo(x.length));
  var out = text;
  var count = 0;
  for (final k in keys) {
    if (k.trim().isEmpty) continue;
    final words = k.split(' ').map(RegExp.escape).join(r'\s+');
    final re = RegExp('(?<![\\p{L}\\p{N}])$words(?![\\p{L}\\p{N}])', caseSensitive: false, unicode: true);
    out = out.replaceAllMapped(re, (_) {
      count++;
      return fixes[k]!;
    });
  }
  return (out, count);
}
