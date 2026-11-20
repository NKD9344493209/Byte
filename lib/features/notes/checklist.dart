/// Checklists inside a note — pure text handling, unit-tested.
///
/// A note's body stays plain text. A task is a line like
///   - [ ] Buy rice
///   - [x] Pay the fee
/// and a sub-task is the same, indented:
///     - [ ] Basmati, 5 kg
/// Everything else in the body is ordinary text and is kept as it is.
///
/// A task can carry a reminder, written at its end:
///   - [ ] Pay the fee ⏰2026-11-20 09:00
/// ([dueOf], [plainTask], [withDue]). What people see never shows that mark.
library;

final RegExp _taskLine = RegExp(r'^(\s*)[-*]\s*\[( |x|X)\]\s?(.*)$');

/// One line of a note: a task (maybe a sub-task) or ordinary text.
class NoteLine {
  const NoteLine.text(this.text)
      : isTask = false,
        done = false,
        level = 0;
  const NoteLine.task(this.text, {this.done = false, this.level = 0}) : isTask = true;

  final bool isTask;
  final String text;
  final bool done;

  /// 0 = a task, 1 = a sub-task of the task above it.
  final int level;

  NoteLine withDone(bool v) => NoteLine.task(text, done: v, level: level);

  String get written => isTask ? '${level > 0 ? '  ' : ''}- [${done ? 'x' : ' '}] $text' : text;
}

// ───────────── reminders ─────────────

final RegExp _dueMark = RegExp(r'\s*⏰\s*(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2})\s*$');

/// When the task [text] should remind, or null.
DateTime? dueOf(String text) {
  final m = _dueMark.firstMatch(text);
  if (m == null) return null;
  final month = int.parse(m.group(2)!);
  final day = int.parse(m.group(3)!);
  final hour = int.parse(m.group(4)!);
  final minute = int.parse(m.group(5)!);
  if (month < 1 || month > 12 || day < 1 || day > 31 || hour > 23 || minute > 59) return null;
  return DateTime(int.parse(m.group(1)!), month, day, hour, minute);
}

/// The task's words, without its reminder mark.
String plainTask(String text) => text.replaceFirst(_dueMark, '').trim();

/// The task's words with a reminder at [at] (null: with none).
String withDue(String text, DateTime? at) {
  final t = plainTask(text);
  if (at == null) return t;
  String two(int v) => v.toString().padLeft(2, '0');
  return '$t ⏰${at.year.toString().padLeft(4, '0')}-${two(at.month)}-${two(at.day)} ${two(at.hour)}:${two(at.minute)}';
}

/// "Today, 6:00 pm" · "Tomorrow, 9:00 am" · "Fri 21 Nov, 9:00 am".
String dueLabel(DateTime at, {DateTime? now}) {
  final n = now ?? DateTime.now();
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  // Noon to noon, so a day with a clock change still counts as one day.
  final apart = (DateTime(at.year, at.month, at.day, 12).difference(DateTime(n.year, n.month, n.day, 12)).inHours / 24).round();
  final hour = at.hour % 12 == 0 ? 12 : at.hour % 12;
  final time = '$hour:${at.minute.toString().padLeft(2, '0')} ${at.hour < 12 ? 'am' : 'pm'}';
  final day = switch (apart) {
    0 => 'Today',
    1 => 'Tomorrow',
    -1 => 'Yesterday',
    _ => '${days[at.weekday - 1]} ${at.day} ${months[at.month - 1]}${at.year == n.year ? '' : ' ${at.year}'}',
  };
  return '$day, $time';
}

List<NoteLine> parseLines(String body) {
  if (body.isEmpty) return <NoteLine>[]; // growable: callers add to it
  final out = <NoteLine>[];
  var sawParent = false;
  for (final raw in body.split('\n')) {
    final m = _taskLine.firstMatch(raw);
    if (m == null) {
      out.add(NoteLine.text(raw));
      // A blank or ordinary line ends the group: what follows cannot be a sub-task of what came before.
      sawParent = false;
      continue;
    }
    final indent = m.group(1)!;
    // A sub-task needs a task above it; an indented first line is just a task.
    final level = (indent.length >= 2 || indent.contains('\t')) && sawParent ? 1 : 0;
    out.add(NoteLine.task(m.group(3)!.trim(), done: m.group(2) != ' ', level: level));
    sawParent = true;
  }
  return out;
}

String writeLines(List<NoteLine> lines) => lines.map((l) => l.written).join('\n');

bool isChecklist(String body) => parseLines(body).any((l) => l.isTask);

/// (done, total) over every task and sub-task.
(int, int) checklistProgress(String body) {
  var done = 0;
  var total = 0;
  for (final l in parseLines(body)) {
    if (!l.isTask) continue;
    total++;
    if (l.done) done++;
  }
  return (done, total);
}

/// Position in [lines] of the [taskIndex]-th task (0-based), or -1.
int _lineOfTask(List<NoteLine> lines, int taskIndex) {
  var n = -1;
  for (var i = 0; i < lines.length; i++) {
    if (!lines[i].isTask) continue;
    if (++n == taskIndex) return i;
  }
  return -1;
}

/// The lines [from]+1 … that are sub-tasks of the task at [from].
int _endOfChildren(List<NoteLine> lines, int from) {
  var i = from + 1;
  while (i < lines.length && lines[i].isTask && lines[i].level == 1) {
    i++;
  }
  return i;
}

int _parentOf(List<NoteLine> lines, int child) {
  for (var i = child - 1; i >= 0; i--) {
    if (!lines[i].isTask) return -1;
    if (lines[i].level == 0) return i;
  }
  return -1;
}

/// Ticks or unticks the [taskIndex]-th task. [done] null = flip it.
///  - Ticking a task ticks its sub-tasks too.
///  - Ticking the last open sub-task ticks the task above it.
///  - Unticking a sub-task unticks the task above it.
String setTaskDone(String body, int taskIndex, {bool? done}) {
  final lines = parseLines(body);
  final at = _lineOfTask(lines, taskIndex);
  if (at < 0) return body;
  final v = done ?? !lines[at].done;
  lines[at] = lines[at].withDone(v);
  if (lines[at].level == 0) {
    if (v) {
      for (var i = at + 1; i < _endOfChildren(lines, at); i++) {
        lines[i] = lines[i].withDone(true);
      }
    }
  } else {
    final parent = _parentOf(lines, at);
    if (parent >= 0) {
      final end = _endOfChildren(lines, parent);
      var allDone = true;
      for (var i = parent + 1; i < end; i++) {
        if (!lines[i].done) allDone = false;
      }
      lines[parent] = lines[parent].withDone(allDone);
    }
  }
  return writeLines(lines);
}

/// Adds a task at the end, or — with [underTask] — a sub-task at the end of
/// that task's sub-tasks. A sub-task asked for under a sub-task goes under
/// the same parent. The parent becomes "not done" again: it has new work.
String addTask(String body, String text, {int? underTask}) {
  // One task is one line, whatever kind of line end was pasted in.
  final t = text.replaceAll(RegExp(r'[\r\n\u2028\u2029]+'), ' ').trim();
  if (t.isEmpty) return body;
  final lines = parseLines(body);
  if (underTask == null) {
    // Drop empty lines at the very end so the new task sits right below the last one.
    while (lines.isNotEmpty && !lines.last.isTask && lines.last.text.trim().isEmpty) {
      lines.removeLast();
    }
    lines.add(NoteLine.task(t));
    return writeLines(lines);
  }
  var at = _lineOfTask(lines, underTask);
  if (at < 0) return addTask(body, text);
  if (lines[at].level == 1) {
    final parent = _parentOf(lines, at);
    if (parent >= 0) at = parent;
  }
  lines.insert(_endOfChildren(lines, at), NoteLine.task(t, level: 1));
  lines[at] = lines[at].withDone(false);
  return writeLines(lines);
}

/// Adds a task under a heading — an ordinary line such as "Monday" at
/// position [line] of the note: it goes below the tasks that already follow
/// that line. (A week plan has one such heading per day.)
String addTaskUnderLine(String body, int line, String text) {
  final t = text.replaceAll(RegExp(r'[\r\n\u2028\u2029]+'), ' ').trim();
  final lines = parseLines(body);
  if (t.isEmpty || line < 0 || line >= lines.length) return body;
  var at = line + 1;
  while (at < lines.length && lines[at].isTask) {
    at++;
  }
  lines.insert(at, NoteLine.task(t));
  return writeLines(lines);
}

/// Changes the words of the [taskIndex]-th task.
String renameTask(String body, int taskIndex, String text) {
  final t = text.trim().replaceAll('\n', ' ');
  final lines = parseLines(body);
  final at = _lineOfTask(lines, taskIndex);
  if (at < 0 || t.isEmpty) return body;
  lines[at] = NoteLine.task(t, done: lines[at].done, level: lines[at].level);
  return writeLines(lines);
}

/// Sets (or, with null, takes away) the reminder of the [taskIndex]-th task.
String setTaskDue(String body, int taskIndex, DateTime? at) {
  final lines = parseLines(body);
  final i = _lineOfTask(lines, taskIndex);
  if (i < 0) return body;
  lines[i] = NoteLine.task(withDue(lines[i].text, at), done: lines[i].done, level: lines[i].level);
  return writeLines(lines);
}

/// The tasks that have a reminder: (taskIndex, words, time, ticked?). The
/// open ones only, unless [withDone].
List<({int index, String text, DateTime at, bool done})> remindersIn(String body, {bool withDone = false}) {
  final out = <({int index, String text, DateTime at, bool done})>[];
  var n = -1;
  for (final l in parseLines(body)) {
    if (!l.isTask) continue;
    n++;
    final at = l.done && !withDone ? null : dueOf(l.text);
    if (at != null) out.add((index: n, text: plainTask(l.text), at: at, done: l.done));
  }
  return out;
}

/// Which task a tick from outside means: number [index] when that task
/// still says [text] (or no words came along); otherwise the first open task
/// that says [text] — the list may have changed since; -1 when there is none.
int taskFor(String body, int index, String text) {
  final want = text.trim();
  final tasks = [
    for (final l in parseLines(body))
      if (l.isTask) l,
  ];
  if (want.isEmpty || (index >= 0 && index < tasks.length && plainTask(tasks[index].text) == want)) return index;
  return tasks.indexWhere((l) => !l.done && plainTask(l.text) == want);
}

/// A list that repeats starts again: every task is un-ticked. With [every]
/// (a day, a week), a reminder whose time has passed moves on to its next
/// time after [now].
String untickAll(String body, {Duration? every, DateTime? now}) {
  final n = now ?? DateTime.now();
  final lines = parseLines(body);
  for (var i = 0; i < lines.length; i++) {
    final l = lines[i];
    if (!l.isTask) continue;
    var text = l.text;
    final due = dueOf(text);
    if (every != null && every.inMinutes > 0 && due != null && !due.isAfter(n)) {
      final rounds = n.difference(due).inMinutes ~/ every.inMinutes + 1;
      text = withDue(text, due.add(every * rounds));
    }
    lines[i] = NoteLine.task(text, level: l.level);
  }
  return writeLines(lines);
}

/// Removes the [taskIndex]-th task — with its sub-tasks, if it has any.
String removeTask(String body, int taskIndex) {
  final lines = parseLines(body);
  final at = _lineOfTask(lines, taskIndex);
  if (at < 0) return body;
  final end = lines[at].level == 0 ? _endOfChildren(lines, at) : at + 1;
  lines.removeRange(at, end);
  return writeLines(lines);
}

/// What you said, as separate tasks: "buy rice, call amma and then pay the
/// fee" → three tasks. Splits at line ends, full stops, semicolons, commas
/// and "and then" / "then" / "also"; each gets a capital letter.
List<String> tasksFromSpeech(String spoken) {
  final parts = spoken.split(RegExp(r'\n+|[.;,]\s+|[.;,]$|\s+(?:and then|then|and also|also)\s+', caseSensitive: false));
  final out = <String>[];
  for (final p in parts) {
    var t = p.trim();
    if (t.toLowerCase().startsWith('and ')) t = t.substring(4).trim();
    if (t.isEmpty) continue;
    out.add(t[0].toUpperCase() + t.substring(1));
  }
  return out;
}

/// What you typed in the "add" box, as separate tasks: "milk, eggs, bread"
/// is three. Splits at line ends, commas and semicolons only, and leaves the
/// words as they were typed.
List<String> tasksFromTyped(String typed) =>
    [for (final p in typed.split(RegExp(r'[\r\n\u2028\u2029,;]+'))) if (p.trim().isNotEmpty) p.trim()];

/// Makes a checklist out of plain lines (a note that was not one yet): every
/// non-empty line becomes a task. Lines that are tasks already stay as they are.
String toChecklist(String body) {
  final out = <NoteLine>[];
  for (final l in parseLines(body)) {
    if (l.isTask) {
      out.add(l);
    } else if (l.text.trim().isNotEmpty) {
      out.add(NoteLine.task(l.text.trim()));
    }
  }
  return writeLines(out);
}

/// The open tasks, in order, as (taskIndex, text, level) — what a pinned
/// checklist shows.
List<(int, String, int)> openTasks(String body) {
  final out = <(int, String, int)>[];
  var n = -1;
  for (final l in parseLines(body)) {
    if (!l.isTask) continue;
    n++;
    if (!l.done) out.add((n, plainTask(l.text), l.level));
  }
  return out;
}

/// A line as people read it: a task line without its "- [ ]" mark.
String plainLine(String line) {
  final m = _taskLine.firstMatch(line);
  return plainTask(m == null ? line : m.group(3)!);
}

/// What a list shows under a note's name. A checklist reads
/// "2 of 5 done · Rice, Call amma" (the open ones); any other note reads as
/// its lines run together. [skipFirst] leaves out the first non-empty line
/// (when that line is already shown as the name).
String notePreview(String body, {bool skipFirst = false}) {
  final lines = parseLines(body).where((l) => l.text.trim().isNotEmpty).toList();
  final rest = skipFirst ? lines.skip(1).toList() : lines;
  if (!lines.any((l) => l.isTask)) return rest.map((l) => l.text.trim()).join(' ').trim();
  final (done, total) = checklistProgress(body);
  final open = [
    for (final l in rest)
      if (l.isTask && !l.done) plainTask(l.text),
  ];
  final head = done == total ? 'All $total done' : '$done of $total done';
  return open.isEmpty ? head : '$head · ${open.take(4).join(', ')}';
}

/// Every task, numbered the way [setTaskDone] numbers them: what the pinned
/// copy (notification and bubble) is given.
List<Map<String, Object?>> pinItems(String body) {
  final out = <Map<String, Object?>>[];
  var n = -1;
  for (final l in parseLines(body)) {
    if (!l.isTask) continue;
    n++;
    out.add({'i': n, 'text': plainTask(l.text), 'level': l.level, 'done': l.done});
  }
  return out;
}
