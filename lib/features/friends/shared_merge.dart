/// A checklist shared with a friend — the pure part: what changed here, what
/// changed there, and how the two become one list. Unit-tested.
///
/// Each phone keeps its own note. An item is known by its words (small
/// letters, single spaces), and carries the time it was last changed; where
/// the two phones differ, the later change wins.
library;

import '../notes/checklist.dart';

/// One item of a shared list, as both phones know it.
class SharedItem {
  const SharedItem({required this.k, required this.text, required this.done, required this.gone, required this.at});

  /// What it is known by: its words in small letters ([itemKey]).
  final String k;

  /// Its words as they were typed.
  final String text;
  final bool done;

  /// Removed from the list (kept for a while, so the other phone learns of it).
  final bool gone;

  /// When it was last ticked, un-ticked, added or removed (milliseconds).
  final int at;

  SharedItem copyWith({String? text, bool? done, bool? gone, int? at}) =>
      SharedItem(k: k, text: text ?? this.text, done: done ?? this.done, gone: gone ?? this.gone, at: at ?? this.at);

  Map<String, Object> toJson() => {'k': k, 'text': text, 'done': done, 'gone': gone, 'at': at};

  static SharedItem? fromJson(Object? o) {
    if (o is! Map) return null;
    final k = '${o['k'] ?? ''}';
    final at = o['at'];
    if (k.isEmpty || at is! int) return null;
    return SharedItem(k: k, text: '${o['text'] ?? k}', done: o['done'] == true, gone: o['gone'] == true, at: at);
  }
}

/// What an item is known by: its words without the reminder mark, in small
/// letters, with single spaces.
String itemKey(String text) => plainTask(text).toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();

/// Is [a] the newer word on an item than [b]? The later change wins; at the
/// very same moment "removed" beats "there" and "done" beats "open", so both
/// phones settle on the same answer.
bool newer(SharedItem a, SharedItem b) {
  if (a.at != b.at) return a.at > b.at;
  if (a.gone != b.gone) return a.gone;
  if (a.done != b.done) return a.done;
  return false;
}

/// What the note on this phone says now, set against what was [known]:
/// new items, ticks and un-ticks, removed items — each stamped [now].
/// Answers the list as it is known from here on, and whether anything changed.
///
/// A change made here is always stamped later than what it changes, even
/// when this phone's clock runs behind the friend's: what you just did must
/// not be undone by the older word it replaced.
(Map<String, SharedItem>, bool) absorb(String body, Map<String, SharedItem> known, int now) {
  final out = Map<String, SharedItem>.of(known);
  final seen = <String>{};
  var changed = false;
  int after(SharedItem was) => now > was.at ? now : was.at + 1;
  for (final l in parseLines(body)) {
    if (!l.isTask) continue;
    final k = itemKey(l.text);
    if (k.isEmpty || !seen.add(k)) continue; // (the same words twice count once)
    final was = out[k];
    final words = plainTask(l.text);
    if (was == null || was.gone) {
      out[k] = SharedItem(k: k, text: words, done: l.done, gone: false, at: was == null ? now : after(was));
      changed = true;
    } else if (was.done != l.done) {
      out[k] = was.copyWith(done: l.done, at: after(was));
      changed = true;
    }
  }
  for (final e in known.entries) {
    if (e.value.gone || seen.contains(e.key)) continue;
    out[e.key] = e.value.copyWith(gone: true, at: after(e.value));
    changed = true;
  }
  return (out, changed);
}

/// What the friend's phone says, laid over what is [known] here: for each
/// item the newer word stands. Answers the result and whether it changed.
(Map<String, SharedItem>, bool) mergeRemote(Map<String, SharedItem> known, Iterable<SharedItem> remote) {
  final out = Map<String, SharedItem>.of(known);
  var changed = false;
  for (final r in remote) {
    final mine = out[r.k];
    if (mine == null || newer(r, mine)) {
      out[r.k] = r;
      changed = true;
    }
  }
  return (out, changed);
}

/// The note's text made to say what is [known]: ticks set, removed items
/// taken out, the friend's new items added at the end. Everything else in the
/// note (ordinary lines, reminders, the order) stays as it is.
String applyTo(String body, Map<String, SharedItem> known) {
  final out = <NoteLine>[];
  final there = <String>{};
  for (final l in parseLines(body)) {
    if (!l.isTask) {
      out.add(l);
      continue;
    }
    final k = itemKey(l.text);
    final item = known[k];
    if (k.isEmpty || item == null) {
      out.add(l); // not an item the two phones know of: left alone
      continue;
    }
    if (item.gone) continue;
    there.add(k);
    out.add(l.done == item.done ? l : l.withDone(item.done));
  }
  // Empty lines at the very end go, so new items sit right below the last one.
  while (out.isNotEmpty && !out.last.isTask && out.last.text.trim().isEmpty) {
    out.removeLast();
  }
  for (final item in known.values) {
    if (item.gone || there.contains(item.k)) continue;
    out.add(NoteLine.task(item.text, done: item.done));
  }
  return writeLines(out);
}

/// Is [item] still worth knowing at [now]? Everything on the list is; a
/// removed item is remembered for 30 days (so the other phone learns of it),
/// then forgotten — on both phones, so neither hands it back to the other.
bool remembered(SharedItem item, int now) => !item.gone || now - item.at < 30 * 24 * 60 * 60 * 1000;

Map<String, SharedItem> forgetOld(Map<String, SharedItem> known, int now) => {
      for (final e in known.entries)
        if (remembered(e.value, now)) e.key: e.value,
    };
