import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../features/notes/checklist.dart';
import '../features/notes/note.dart';
import '../features/notes/notes_repo.dart';
import '../features/notes/repeats.dart';
import 'db.dart';
import 'prefs.dart';

/// The floating BYTE bubble and the pinned checklist (Android only).
///
/// The bubble itself is drawn by Android (`BubbleService`). The pinned
/// checklist is a COPY of one note's tasks that Android can show in the
/// notification shade and in the bubble, and tick while BYTE is closed.
/// Those ticks wait on the Android side; [applyTicks] writes them into the
/// real note the next time BYTE is open.
class Bubble {
  Bubble._();

  static const _ch = MethodChannel('byte/bubble');
  static const _kPinned = 'pinned_checklist';

  /// The list the user took out of the notifications by hand: it does not put
  /// itself back.
  static const _kTakenOut = 'checklist_taken_out';

  /// Goes up by one each time ticks made outside BYTE were written into a
  /// note, so an open note can show them.
  static final ValueNotifier<int> ticked = ValueNotifier<int>(0);

  /// The note whose checklist is pinned, or ''.
  static String get pinnedId => Prefs.text(_kPinned);

  /// Only Android has the notification and the bubble.
  static bool get supported => Platform.isAndroid;

  // ───────────── the bubble ─────────────

  /// (allowed, on): may BYTE draw over other apps, and is the bubble wanted.
  static Future<(bool, bool)> state() async {
    if (!Platform.isAndroid) return (false, false);
    try {
      final m = await _ch.invokeMapMethod<String, dynamic>('state');
      return (m?['allowed'] == true, m?['on'] == true);
    } catch (e) {
      debugPrint('[bubble] state: $e');
      return (false, false);
    }
  }

  /// Turns the bubble on or off. Turning it on without the "display over
  /// other apps" permission opens that Android settings page and returns
  /// false; call again when the user is back.
  static Future<bool> setOn(bool on) async {
    if (!Platform.isAndroid) return false;
    try {
      return await _ch.invokeMethod<bool>('set', {'on': on}) ?? false;
    } catch (e) {
      debugPrint('[bubble] set: $e');
      return false;
    }
  }

  /// Android 13+: asks once whether BYTE may show notifications.
  static Future<bool> askNotifications() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _ch.invokeMethod<bool>('askNotifications') ?? false;
    } catch (e) {
      debugPrint('[bubble] notifications: $e');
      return false;
    }
  }

  /// Can the phone show the checklist notification right now? False when
  /// notifications are off for BYTE (or for the checklist) in the phone's
  /// settings.
  static Future<bool> canNotify() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _ch.invokeMethod<bool>('canNotify') ?? false;
    } catch (e) {
      debugPrint('[bubble] can notify: $e');
      return false;
    }
  }

  /// Opens the phone's own page where notifications are allowed for BYTE.
  static Future<void> openNotificationSettings() async {
    if (!Platform.isAndroid) return;
    try {
      await _ch.invokeMethod<void>('openNotifySettings');
    } catch (e) {
      debugPrint('[bubble] notification settings: $e');
    }
  }

  /// Asks Android to put the "BYTE checklist" button in the control centre
  /// (the phone shows its own question). Answers 'added', 'there' (it was
  /// there already), 'no' (the user said no) or 'byHand' (this phone cannot
  /// be asked: the button is dragged in by hand).
  static Future<String> addTile() async {
    if (!Platform.isAndroid) return 'byHand';
    try {
      final code = await _ch.invokeMethod<int>('addTile').timeout(const Duration(minutes: 2), onTimeout: () => -1);
      return switch (code) { 2 => 'added', 1 => 'there', 0 => 'no', _ => 'byHand' };
    } catch (e) {
      debugPrint('[bubble] add tile: $e');
      return 'byHand';
    }
  }

  /// Asks the home screen to take the checklist widget (the phone shows its
  /// own "Add to home screen" box). False: this home screen cannot be asked,
  /// and the widget is added by hand.
  static Future<bool> addWidget() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _ch.invokeMethod<bool>('addWidget') ?? false;
    } catch (e) {
      debugPrint('[bubble] add widget: $e');
      return false;
    }
  }

  /// [addTile], but only the first time a list goes into the notifications.
  /// Answers '' when it was offered before.
  static Future<String> offerTileOnce() async {
    if (!Platform.isAndroid || Prefs.flag('checklist_tile_offered')) return '';
    await Prefs.setFlag('checklist_tile_offered', true);
    return addTile();
  }

  // ───────────── the pinned checklist ─────────────

  /// What Android gets: every task of [note], numbered the way
  /// `setTaskDone` numbers them.
  /// [repeat]: how the list repeats ('' = it does not). Android is told when
  /// the next round begins, and un-ticks its copy by itself then.
  static String pinJson(Note note, {String repeat = ''}) {
    final now = DateTime.now();
    final next = Repeats.next(repeat, now);
    return jsonEncode({
      'noteId': note.id,
      'title': note.displayTitle,
      'items': pinItems(note.body),
      if (next != null) 'resetAt': next.millisecondsSinceEpoch,
      if (next != null) 'every': Repeats.every(repeat)!.inMilliseconds,
    });
  }

  /// Pins [note]'s checklist (replacing any other pinned one).
  static Future<void> pin(Note note) async {
    if (Prefs.text(_kTakenOut) == note.id) await Prefs.setText(_kTakenOut, '');
    await Prefs.setText(_kPinned, note.id);
    await _send(pinJson(note));
    // Items added while this was on its way are in the saved note: show those.
    await refreshPin();
  }

  /// [byHand]: the user took this list out; [pinsItself] then leaves it alone.
  static Future<void> unpin({String byHand = ''}) async {
    if (byHand.isNotEmpty) await Prefs.setText(_kTakenOut, byHand);
    await Prefs.setText(_kPinned, '');
    await _send(null);
  }

  /// Should [note] go into the notifications by itself, now that it has got
  /// an item? Yes for a list that was just made, and for an older list when
  /// the notifications hold no list with something still to do. Never a
  /// private list, and never one the user took out by hand.
  static Future<bool> pinsItself(Note note, {required bool fresh}) async {
    if (!Platform.isAndroid) return false;
    if (note.private || openTasks(note.body).isEmpty) return false;
    final pinned = pinnedId;
    if (pinned == note.id || Prefs.text(_kTakenOut) == note.id) return false;
    if (fresh || pinned.isEmpty) return true;
    try {
      final rows = await AppDb.instance.db.query('items', columns: ['body'], where: 'id = ? AND deleted_at IS NULL AND private = 0', whereArgs: [pinned], limit: 1);
      return rows.isEmpty || openTasks(rows.first['body'] as String? ?? '').isEmpty;
    } catch (e) {
      debugPrint('[bubble] pins itself: $e');
      return false;
    }
  }

  static Future<void> _send(String? json) async {
    if (!Platform.isAndroid) return;
    try {
      await _ch.invokeMethod<void>('pin', {'json': json});
    } catch (e) {
      debugPrint('[bubble] pin: $e');
    }
  }

  /// The pinned copy again, from the note as it is now. Unpins when the
  /// note is gone, in the bin, made private, or has no tasks left in it.
  static Future<void> refreshPin() async {
    final id = pinnedId;
    if (id.isEmpty) return;
    try {
      final rows = await AppDb.instance.db.query('items', where: 'id = ? AND deleted_at IS NULL AND private = 0', whereArgs: [id], limit: 1);
      if (pinnedId != id) return; // another list was pinned meanwhile: that one stands
      if (rows.isEmpty) {
        await unpin();
        return;
      }
      final note = Note.fromRow(rows.first);
      if (!isChecklist(note.body)) {
        await unpin();
        return;
      }
      await _send(pinJson(note, repeat: '${rows.first['repeat'] ?? ''}'));
    } catch (e) {
      debugPrint('[bubble] refresh: $e');
    }
  }

  /// Call after a note was saved: keeps the pinned copy the same as the note.
  static Future<void> noteSaved(String noteId) async {
    if (noteId.isNotEmpty && noteId == pinnedId) await refreshPin();
  }

  static Future<void>? _applying;

  /// Android tells BYTE the moment a tick is made in the bubble or the
  /// notification while BYTE is running. Call once at start.
  static void listen() {
    if (!Platform.isAndroid) return;
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'ticked') await applyTicks();
      return null;
    });
  }

  /// Writes what was done outside BYTE — things added in the control-centre
  /// panel or the notification, ticks made there or in the bubble — into
  /// the notes, then refreshes the pinned copy. Safe to call often (every time
  /// BYTE comes to the front).
  /// A call made while one is running waits for that one.
  static Future<void> applyTicks() {
    if (!Platform.isAndroid) return Future<void>.value();
    if (_applying != null) _moreTicks = true; // one more pass when this one is done
    return _applying ??= _applyAll().whenComplete(() => _applying = null);
  }

  static bool _moreTicks = false;

  static Future<void> _applyAll() async {
    do {
      _moreTicks = false;
      await _applyTicks();
    } while (_moreTicks);
  }

  /// Things added outside BYTE go into their note, at the end. A list that
  /// was started out there (no note yet) becomes a note now. True when
  /// something was written.
  static Future<bool> _applyAdds() async {
    // They stay on the Android side until they are written here: an error on
    // the way loses nothing.
    final raw = await _ch.invokeMethod<String>('pendingAdds') ?? '[]';
    final decoded = jsonDecode(raw);
    final list = decoded is List ? decoded : const <dynamic>[];
    if (list.isEmpty) return false;
    var wrote = false;
    // One run of things for the same list at a time, each acknowledged as soon
    // as it is written: a stop in the middle never adds anything twice.
    var i = 0;
    while (i < list.length) {
      final head = list[i];
      final id = head is Map ? '${head['noteId'] ?? ''}' : '';
      final texts = <String>[];
      var fresh = false;
      var j = i;
      while (j < list.length) {
        final a = list[j];
        if ((a is Map ? '${a['noteId'] ?? ''}' : '') != id) break;
        if (a is Map) {
          final text = '${a['text'] ?? ''}'.trim();
          if (text.isNotEmpty) texts.add(text);
          if (a['fresh'] == true) fresh = true;
        }
        j++;
      }
      if (id.isNotEmpty && texts.isNotEmpty && await _writeAdds(id, texts, fresh: fresh)) wrote = true;
      await _ch.invokeMethod<void>('addsWritten', {'count': j - i});
      i = j;
    }
    return wrote;
  }

  /// Writes [texts] at the end of note [id]. [fresh]: the list was started
  /// outside BYTE, so with no note yet one is made under that id.
  static Future<bool> _writeAdds(String id, List<String> texts, {required bool fresh}) async {
    final rows = await AppDb.instance.db.query('items', where: 'id = ?', whereArgs: [id], limit: 1);
    var body = rows.isEmpty ? '' : (rows.first['body'] as String? ?? '');
    for (final t in texts) {
      body = addTask(body, t);
    }
    if (rows.isEmpty) {
      if (!fresh) return false;
      await NotesRepo.instance.create(id: id, title: 'Checklist', body: body);
    } else {
      // In the bin or made private meanwhile: left as it is.
      if (rows.first['type'] != 'note' || rows.first['deleted_at'] != null || rows.first['private'] == 1) return false;
      await NotesRepo.instance.update(Note.fromRow(rows.first).copyWith(body: body));
    }
    // Android shows this list already; BYTE follows, unless another list was pinned since.
    if (fresh && pinnedId.isEmpty) await Prefs.setText(_kPinned, id);
    return true;
  }

  static Future<void> _applyTicks() async {
    try {
      // Lists that repeat start their new round first: a tick made today
      // must not be wiped by it, and a tick left from the last round must
      // not land in the new one (see the times below).
      await Repeats.runDue();
      // Added things next: a tick may be on one of them.
      final added = await _applyAdds();
      final raw = await _ch.invokeMethod<String>('takeTicks') ?? '[]';
      final list = jsonDecode(raw);
      // note → (item number, when it was ticked, the item's words if they came along)
      final byNote = <String, List<(int, int, String)>>{};
      for (final t in list is List ? list : const <dynamic>[]) {
        if (t is! Map) continue;
        final id = '${t['noteId'] ?? ''}';
        final index = t['index'];
        final at = t['at'];
        if (id.isEmpty || index is! int) continue;
        (byNote[id] ??= <(int, int, String)>[]).add((index, at is int ? at : 0, '${t['text'] ?? ''}'));
      }
      var wrote = false;
      final now = DateTime.now();
      for (final e in byNote.entries) {
        final rows = await AppDb.instance.db.query('items', where: "id = ? AND type = 'note' AND deleted_at IS NULL", whereArgs: [e.key], limit: 1);
        if (rows.isEmpty) continue;
        final note = Note.fromRow(rows.first);
        // A repeating list: only the ticks of the round that is running count.
        final since = Repeats.start('${rows.first['repeat'] ?? ''}', now)?.millisecondsSinceEpoch ?? 0;
        var body = note.body;
        for (final (i, at, text) in e.value) {
          if (at != 0 && at < since) continue;
          final which = taskFor(body, i, text);
          if (which >= 0) body = setTaskDone(body, which, done: true);
        }
        if (body == note.body) continue;
        await NotesRepo.instance.update(note.copyWith(body: body));
        wrote = true;
      }
      if (wrote || added) ticked.value++;
      // Ticking a task ticks its sub-tasks too, and the note may have been
      // binned meanwhile: show Android the list as it really is.
      await refreshPin();
    } catch (e) {
      debugPrint('[bubble] ticks: $e');
    }
  }
}
