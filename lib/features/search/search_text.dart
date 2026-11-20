import '../library/library_item.dart';

/// Pure text helpers for search: where a word was found, which page it is
/// on, and how to cut a line into matching / non-matching pieces so the
/// match can be highlighted. No Flutter here, so all of it is unit-tested.

/// Pages of a document are stored in one string with a form feed between
/// them (the indexer writes it, the viewer and search read it).
const String pageBreak = '\f';

/// A search hit inside a longer text: a few words before, the match itself,
/// a few words after, and the page it is on (multi-page documents only).
class SearchHit {
  const SearchHit({required this.before, required this.match, required this.after, this.page});
  final String before;
  final String match;
  final String after;

  /// 1-based page number, or null when the text has no pages.
  final int? page;

  @override
  String toString() => '${page == null ? '' : 'p$page '}…$before[$match]$after…';
}

/// The words of a query, lower-cased, without empties.
List<String> queryWords(String query) => query.trim().toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();

/// The first place a query word appears in [text]. The words you typed are
/// tried first; only when none of them is there are their synonyms tried
/// ("animal" finds a photo labelled "dog").
SearchHit? findHit(String text, String query, {int lead = 40, int trail = 70}) {
  if (text.trim().isEmpty) return null;
  final words = queryWords(query);
  if (words.isEmpty) return null;
  final low = text.toLowerCase();
  final candidates = <String>[
    ...words,
    for (final w in words)
      for (final s in expandQueryWord(w))
        if (!words.contains(s)) s,
  ];
  for (final w in candidates) {
    final i = low.indexOf(w);
    if (i < 0) continue;
    var start = i - lead < 0 ? 0 : i - lead;
    var end = i + w.length + trail > text.length ? text.length : i + w.length + trail;
    // Never cut an emoji in half (it is two code units): step off the half.
    if (start > 0 && start < i && _isLowHalf(text.codeUnitAt(start))) start++;
    if (end < text.length && end > i + w.length && _isHighHalf(text.codeUnitAt(end - 1))) end--;
    int? page;
    if (text.contains(pageBreak)) page = pageBreak.allMatches(text.substring(0, i)).length + 1;
    return SearchHit(
      before: _oneLine(text.substring(start, i)),
      match: text.substring(i, i + w.length),
      after: _oneLine(text.substring(i + w.length, end)),
      page: page,
    );
  }
  return null;
}

bool _isHighHalf(int c) => c >= 0xD800 && c <= 0xDBFF;
bool _isLowHalf(int c) => c >= 0xDC00 && c <= 0xDFFF;

String _oneLine(String s) => s.replaceAll(RegExp(r'[\n\r\f\t]+'), ' ').replaceAll(RegExp(r' {2,}'), ' ');

/// Cuts [text] into pieces, each marked true when it matches one of [words]
/// (case-insensitive). Used to highlight the match inside a title.
List<(String, bool)> splitMatches(String text, List<String> words) {
  final ws = words.where((w) => w.trim().isNotEmpty).map((w) => w.toLowerCase()).toList()..sort((a, b) => b.length.compareTo(a.length));
  if (text.isEmpty || ws.isEmpty) return [(text, false)];
  final low = text.toLowerCase();
  final out = <(String, bool)>[];
  var at = 0;
  while (at < text.length) {
    var best = -1;
    var bestLen = 0;
    for (final w in ws) {
      final i = low.indexOf(w, at);
      if (i >= 0 && (best < 0 || i < best)) {
        best = i;
        bestLen = w.length;
      }
    }
    if (best < 0) break;
    if (best > at) out.add((text.substring(at, best), false));
    out.add((text.substring(best, best + bestLen), true));
    at = best + bestLen;
  }
  if (at < text.length) out.add((text.substring(at), false));
  return out;
}

/// The pages of a document as one stored text: each page tidied, a form
/// feed between pages (Search turns that into "Page 3"), nothing after
/// the last page that has words. Pure, unit-tested.
String joinPages(List<String> pages, {int maxChars = 400000}) {
  final clean = [
    for (final t in pages) t.replaceAll(pageBreak, ' ').replaceAll(RegExp(r'[ \t]+'), ' ').replaceAll(RegExp(r'\n{3,}'), '\n\n').trim(),
  ];
  while (clean.isNotEmpty && clean.last.isEmpty) {
    clean.removeLast();
  }
  final buf = StringBuffer();
  for (var i = 0; i < clean.length; i++) {
    final room = maxChars - buf.length - (i > 0 ? 1 : 0);
    if (room <= 0) break;
    if (i > 0) buf.write('\f');
    final page = clean[i];
    if (page.length > room) {
      buf.write(page.substring(0, room)); // a huge document stops here
      break;
    }
    buf.write(page);
  }
  return buf.toString();
}

/// True when a page gave (almost) no text: it is a picture of a page.
bool looksScanned(String pageText) => pageText.replaceAll(RegExp(r'\s'), '').length < 12;

/// How many pages a stored document text has (1 when it has no page breaks).
int pageCount(String text) => text.isEmpty ? 0 : pageBreak.allMatches(text).length + 1;

/// The stored text made readable: a "Page N" line before every page of a
/// multi-page document. Text without pages comes back unchanged.
String readablePages(String text) {
  if (!text.contains(pageBreak)) return text;
  final pages = text.split(pageBreak);
  final buf = StringBuffer();
  for (var i = 0; i < pages.length; i++) {
    final p = pages[i].trim();
    if (p.isEmpty) continue;
    if (buf.isNotEmpty) buf.write('\n\n');
    buf.write('Page ${i + 1}\n$p');
  }
  return buf.toString();
}

/// Where a query hits one Library item: the text BYTE read from it first,
/// then your own note on it, then what BYTE saw in it. Null when the query
/// only matches the title, the tags or the link.
SearchHit? hitIn(LibraryItem it, String query) {
  return findHit(it.text, query) ?? findHit(it.body, query) ?? findHit(it.labels.join(', '), query);
}

/// The time filters of Search: 'week' = the last 7 days, 'month' = since the
/// 1st of this month, 'year' = since 1 January. Anything else = no limit.
DateTime? sinceFor(String when, {DateTime? now}) {
  final n = now ?? DateTime.now();
  return switch (when) {
    'week' => DateTime(n.year, n.month, n.day - 6),
    'month' => DateTime(n.year, n.month),
    'year' => DateTime(n.year),
    _ => null,
  };
}
