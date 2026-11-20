import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/widgets.dart';
import 'package:uuid/uuid.dart';

import '../features/friends/shared_merge.dart';
import '../features/library/library_item.dart';
import '../features/library/library_repo.dart';
import '../features/notes/checklist.dart';
import '../features/notes/note.dart';
import '../features/notes/notes_repo.dart';
import 'cloud_sync.dart';
import 'db.dart';
import 'prefs.dart';
import 'shares.dart';

/// Someone you added on BYTE.
class Friend {
  const Friend({required this.id, required this.name, required this.myBox, required this.theirBox});
  final String id;
  final String name;

  /// The file in MY Drive that says what I share with them.
  final String myBox;

  /// The file in THEIR Drive that says what they share with me.
  final String theirBox;

  static Friend fromRow(Map<String, Object?> r) =>
      Friend(id: '${r['id']}', name: '${r['name'] ?? ''}', myBox: '${r['my_box'] ?? ''}', theirBox: '${r['their_box'] ?? ''}');
}

/// An album you share with a friend: photos and videos from both of you.
class FriendAlbum {
  const FriendAlbum({required this.id, required this.title, required this.friend, required this.count, required this.cover});
  final String id;
  final String title;
  final String friend;
  final int count;

  /// The Drive id of its newest picture ('' when it is empty).
  final String cover;
}

/// One photo or video in a [FriendAlbum].
class FriendPhoto {
  const FriendPhoto({required this.k, required this.name, required this.video, required this.mine, required this.at});

  /// The Drive id of the copy (in the Drive of whoever added it).
  final String k;
  final String name;
  final bool video;

  /// Added from this phone.
  final bool mine;
  final int at;
}

/// What pasting a code led to.
class FriendAdded {
  const FriendAdded(this.friend, {this.reply = ''});
  final Friend friend;

  /// Not empty: the message to send back, so the friend's BYTE knows this
  /// phone too.
  final String reply;
}

/// A code could not be used; [toString] says why, in plain words.
class FriendProblem implements Exception {
  const FriendProblem(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Friends, and the checklists shared with them.
///
/// There is no BYTE server. Each phone keeps a small file per friend in its
/// own Google Drive — a "box" — that says what it shares with that friend
/// and how each item stands. The friend's BYTE reads that box (it is open to
/// whoever has its id), lays it over its own copy, and writes its own box
/// back. So a tick travels: note here → my box → their BYTE → their note.
///
/// Two people become friends by swapping codes once: an invite one way, an
/// answer the other way. A code holds a name and the id of a box.
class Friends {
  Friends._();

  static const _uuid = Uuid();
  static const _kId = 'friend_me_id';
  static const _kName = 'friend_me_name';
  static const _mark = 'BYTE-FRIEND:';

  /// Goes up when friends or shared lists changed.
  static final ValueNotifier<int> changed = ValueNotifier<int>(0);

  /// The name friends see for you.
  static String get myName => Prefs.text(_kName);
  static Future<void> setMyName(String v) => Prefs.setText(_kName, v.trim());

  static Future<String> _myId() async {
    var id = Prefs.text(_kId);
    if (id.isEmpty) {
      id = _uuid.v4();
      await Prefs.setText(_kId, id);
    }
    return id;
  }

  static Future<List<Friend>> list() async {
    final rows = await AppDb.instance.db.query('friends', orderBy: 'name COLLATE NOCASE');
    return rows.map(Friend.fromRow).toList();
  }

  // ───────────── becoming friends ─────────────

  static String _code(Map<String, Object> m) => '$_mark${base64Url.encode(utf8.encode(jsonEncode(m)))}';

  static Map<String, Object?>? _read(String pasted) {
    final m = RegExp('$_mark([A-Za-z0-9_=-]+)').firstMatch(pasted);
    if (m == null) return null;
    try {
      final o = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(m.group(1)!))));
      return o is Map<String, dynamic> ? o : null;
    } catch (_) {
      return null;
    }
  }

  static String _emptyBox(String me, String to) => jsonEncode({
        'v': 1,
        'from': {'id': me, 'name': myName},
        'to': to,
        'lists': <Object>[],
      });

  /// Makes an invite and returns the message to send to the friend.
  static Future<String> invite() async {
    final me = await _myId();
    final box = await CloudSync.boxWrite('box-${me.substring(0, 8)}-${DateTime.now().millisecondsSinceEpoch}.json', _emptyBox(me, ''));
    await AppDb.instance.db.insert('friend_invites', {'box': box, 'made_at': DateTime.now().millisecondsSinceEpoch});
    return 'Add me on BYTE, so we can share lists.\n'
        '1. Copy this whole message.\n'
        '2. In BYTE: Folders, then Friends, then "I got a code".\n\n'
        '${_code({'v': 1, 'id': me, 'name': myName, 'box': box})}';
  }

  /// Uses a code that was pasted in: a friend's invite (the answer to send
  /// back comes with the result), or a friend's answer to your invite.
  static Future<FriendAdded> accept(String pasted) async {
    final code = _read(pasted);
    if (code == null) throw const FriendProblem('No BYTE code in that text. Copy the whole message your friend sent, then paste it here.');
    final id = '${code['id'] ?? ''}';
    final box = '${code['box'] ?? ''}';
    final re = '${code['re'] ?? ''}';
    final name = '${code['name'] ?? ''}'.trim();
    final me = await _myId();
    if (id.isEmpty || box.isEmpty) throw const FriendProblem('That code is not complete. Ask your friend to send it again.');
    if (id == me) throw const FriendProblem('That is your own code. It is for your friend to paste, not you.');
    final db = AppDb.instance.db;
    final had = await db.query('friends', where: 'id = ?', whereArgs: [id], limit: 1);

    if (re.isEmpty) {
      // An invite. Already friends (the same invite pasted twice, or a new
      // invite because the first answer got lost): the answer is given
      // again, and the box named in THIS invite is the one read from now on.
      if (had.isNotEmpty) {
        final old = Friend.fromRow(had.first);
        await db.update('friends', {'their_box': box}, where: 'id = ?', whereArgs: [id]);
        changed.value++;
        syncSoon();
        return FriendAdded(Friend(id: old.id, name: old.name, myBox: old.myBox, theirBox: box), reply: _answer(me, old.myBox, box));
      }
      final mine = await CloudSync.boxWrite('box-${me.substring(0, 8)}-${DateTime.now().millisecondsSinceEpoch}.json', _emptyBox(me, id));
      final f = Friend(id: id, name: name.isEmpty ? 'Friend' : name, myBox: mine, theirBox: box);
      await _keep(f);
      return FriendAdded(f, reply: _answer(me, mine, box));
    }

    // An answer to an invite made on this phone.
    final invite = await db.query('friend_invites', where: 'box = ?', whereArgs: [re], limit: 1);
    if (had.isNotEmpty) {
      // Friends already. An answer to a NEW invite of mine moves both boxes
      // to the ones this exchange names; the same answer pasted twice changes nothing.
      final old = Friend.fromRow(had.first);
      if (invite.isEmpty) return FriendAdded(old);
      await db.update('friends', {'my_box': re, 'their_box': box}, where: 'id = ?', whereArgs: [id]);
      await db.delete('friend_invites', where: 'box = ?', whereArgs: [re]);
      await Prefs.setText('friend_box_said_$id', ''); // the new box has not said anything yet
      changed.value++;
      syncSoon();
      return FriendAdded(Friend(id: old.id, name: old.name, myBox: re, theirBox: box));
    }
    if (invite.isEmpty) throw const FriendProblem('This code answers an invite that was not made on this phone. Send your friend a new invite.');
    final f = Friend(id: id, name: name.isEmpty ? 'Friend' : name, myBox: re, theirBox: box);
    await _keep(f);
    await db.delete('friend_invites', where: 'box = ?', whereArgs: [re]);
    return FriendAdded(f);
  }

  static String _answer(String me, String myBox, String theirBox) => 'Done. Paste this in BYTE (Folders, then Friends, then "I got a code") and we are connected.\n\n'
      '${_code({'v': 1, 'id': me, 'name': myName, 'box': myBox, 're': theirBox})}';

  static Future<void> _keep(Friend f) async {
    await AppDb.instance.db.insert('friends', {'id': f.id, 'name': f.name, 'my_box': f.myBox, 'their_box': f.theirBox, 'added_at': DateTime.now().millisecondsSinceEpoch});
    await Prefs.setText('friend_box_said_${f.id}', ''); // this box has not said anything yet
    changed.value++;
    syncSoon();
  }

  /// Takes a friend off this phone. The lists stay as ordinary lists — here,
  /// and on the friend's phone, which is told with a last, empty box.
  static Future<void> remove(Friend f) async {
    final db = AppDb.instance.db;
    // The albums with them go too: what you put in stops being shared.
    for (final a in await db.query('shared_albums', columns: ['album_id'], where: 'friend_id = ?', whereArgs: [f.id])) {
      await leaveAlbum('${a['album_id']}');
    }
    final lists = await db.query('shared_lists', columns: ['list_id'], where: 'friend_id = ?', whereArgs: [f.id]);
    await db.transaction((txn) async {
      for (final l in lists) {
        await txn.delete('shared_items', where: 'list_id = ?', whereArgs: [l['list_id']]);
      }
      // The rows stay, as "sharing has stopped": a list the friend's phone
      // still names is then not taken for a new one.
      await txn.update('shared_lists', {'closed': 1}, where: 'friend_id = ?', whereArgs: [f.id]);
      await txn.delete('friends', where: 'id = ?', whereArgs: [f.id]);
    });
    await Prefs.setText('friend_box_said_${f.id}', '');
    changed.value++;
    try {
      // "Goodbye": nothing of yours is left in the box, and their BYTE stops
      // following every list.
      final me = await _myId();
      await CloudSync.boxWrite(
        'box-${me.substring(0, 8)}.json',
        jsonEncode({
          'v': 1,
          'from': {'id': me, 'name': myName},
          'to': f.id,
          'bye': true,
          'lists': <Object>[],
        }),
        existingId: f.myBox,
      );
    } catch (e) {
      debugPrint('[friends] goodbye box: $e');
    }
  }

  // ───────────── sharing a list ─────────────

  /// The friend this note is shared with right now, or null.
  static Future<Friend?> sharedWith(String noteId) async {
    final rows = await AppDb.instance.db.rawQuery(
      'SELECT f.* FROM shared_lists s JOIN friends f ON f.id = s.friend_id WHERE s.note_id = ? AND s.closed = 0 LIMIT 1',
      [noteId],
    );
    return rows.isEmpty ? null : Friend.fromRow(rows.first);
  }

  /// Shares the checklist [note] with [f]: from now on both phones see the
  /// same items and ticks.
  static Future<void> share(Note note, Friend f) async {
    if (note.private) return; // never a list of the private space
    final db = AppDb.instance.db;
    final now = DateTime.now().millisecondsSinceEpoch;
    final listId = _uuid.v4();
    final (items, _) = absorb(note.body, const {}, now);
    await db.transaction((txn) async {
      // A list that was shared before starts as a new one. The old row stays,
      // as "sharing has stopped", so the other phone is still told so; only
      // its items go.
      for (final old in await txn.query('shared_lists', columns: ['list_id'], where: 'note_id = ?', whereArgs: [note.id])) {
        await txn.delete('shared_items', where: 'list_id = ?', whereArgs: [old['list_id']]);
      }
      await txn.update('shared_lists', {'closed': 1}, where: 'note_id = ?', whereArgs: [note.id]);
      await txn.insert('shared_lists', {'list_id': listId, 'friend_id': f.id, 'note_id': note.id, 'title': note.displayTitle, 'closed': 0});
      for (final i in items.values) {
        await txn.insert('shared_items', {'list_id': listId, 'k': i.k, 'text': i.text, 'done': i.done ? 1 : 0, 'gone': 0, 'at': i.at});
      }
    });
    changed.value++;
    syncSoon();
  }

  /// Stops sharing [noteId]. Both phones keep the list as it is; it only
  /// stops following the other one.
  static Future<void> stop(String noteId) async {
    await AppDb.instance.db.update('shared_lists', {'closed': 1}, where: 'note_id = ?', whereArgs: [noteId]);
    changed.value++;
    syncSoon();
  }

  /// [body] — what is typed in the open editor and not saved yet — with what
  /// the friend changed laid over it. Null when the note is not shared. (So
  /// that saving the typed text does not wipe what just came in.)
  static Future<String?> laidOver(String noteId, String body) async {
    final rows = await AppDb.instance.db.query('shared_lists', columns: ['list_id'], where: 'note_id = ? AND closed = 0', whereArgs: [noteId], limit: 1);
    if (rows.isEmpty) return null;
    return applyTo(body, await _known('${rows.first['list_id']}'));
  }

  // ───────────── an album with a friend ─────────────

  /// The albums shared with friends, newest first.
  static Future<List<FriendAlbum>> albums() async {
    final rows = await AppDb.instance.db.rawQuery('''
      SELECT a.album_id, a.title, COALESCE(f.name, '') AS friend,
             (SELECT COUNT(*) FROM shared_photos p WHERE p.album_id = a.album_id) AS n,
             COALESCE((SELECT p.k FROM shared_photos p WHERE p.album_id = a.album_id ORDER BY p.at DESC, p.k LIMIT 1), '') AS cover
      FROM shared_albums a LEFT JOIN friends f ON f.id = a.friend_id
      ORDER BY a.made_at DESC
    ''');
    return [
      for (final r in rows)
        FriendAlbum(id: '${r['album_id']}', title: '${r['title'] ?? ''}', friend: '${r['friend'] ?? ''}', count: (r['n'] as int?) ?? 0, cover: '${r['cover'] ?? ''}'),
    ];
  }

  /// The albums shared with [f] (to add more photos to one).
  static Future<List<FriendAlbum>> albumsWith(Friend f) async {
    final all = await albums();
    final mine = await AppDb.instance.db.query('shared_albums', columns: ['album_id'], where: 'friend_id = ?', whereArgs: [f.id]);
    final ids = {for (final r in mine) '${r['album_id']}'};
    return [
      for (final a in all)
        if (ids.contains(a.id)) a,
    ];
  }

  /// Everything in the album, newest first.
  static Future<List<FriendPhoto>> photos(String albumId) async {
    final rows = await AppDb.instance.db.query('shared_photos', where: 'album_id = ?', whereArgs: [albumId], orderBy: 'at DESC, k');
    return [
      for (final r in rows)
        FriendPhoto(k: '${r['k']}', name: '${r['name'] ?? ''}', video: r['kind'] == 'video', mine: r['mine'] == 1, at: (r['at'] as int?) ?? 0),
    ];
  }

  /// Puts the photos and videos among [itemIds] into an album shared with
  /// [f]: a new one called [title], or — with [albumId] — one you already
  /// share. Copies go into a folder in your Google Drive that anyone with
  /// its link may see; your friend's BYTE shows them inside the album.
  /// Answers how many went in. Needs the internet.
  static Future<int> addToAlbum(
    Friend f, {
    required List<String> itemIds,
    String albumId = '',
    String title = '',
    void Function(int done, int total)? onProgress,
    bool Function()? shouldStop,
  }) async {
    final db = AppDb.instance.db;
    final name = title.trim().isEmpty ? 'Album' : title.trim();
    // An album holds photos and videos; anything else that was picked stays out.
    final media = <String>[];
    for (final id in itemIds) {
      final it = await LibraryRepo.instance.get(id);
      if (it != null && (it.kind == LibraryKind.photo || it.kind == LibraryKind.video)) media.add(id);
    }
    if (media.isEmpty) throw const FriendProblem('An album takes photos and videos. Pick some of those.');
    final files = <(LibraryItem, String)>[];
    final made = await Shares.create(
      name: albumId.isEmpty ? '$name (with ${f.name})' : 'More for ${f.name}',
      itemIds: media,
      onProgress: onProgress,
      shouldStop: shouldStop,
      onFile: (item, fileId) {
        files.add((item, fileId));
      },
    );
    final now = DateTime.now().millisecondsSinceEpoch;
    final id = albumId.isEmpty ? _uuid.v4() : albumId;
    await db.transaction((txn) async {
      if (albumId.isEmpty) await txn.insert('shared_albums', {'album_id': id, 'friend_id': f.id, 'title': name, 'made_at': now});
      var n = 0;
      for (final (item, fileId) in files) {
        await txn.rawInsert(
          'INSERT OR REPLACE INTO shared_photos (album_id, k, name, kind, mine, share_id, at) VALUES (?, ?, ?, ?, 1, ?, ?)',
          [id, fileId, item.title, item.kind == LibraryKind.video ? 'video' : 'photo', made.link.id, now + n++],
        );
      }
    });
    changed.value++;
    syncSoon();
    return files.length;
  }

  /// Takes the album off this phone. Your own copies in it stop being
  /// shared (their links are closed); your friend's photos stay theirs.
  static Future<void> leaveAlbum(String albumId) async {
    final db = AppDb.instance.db;
    final mine = await db.rawQuery("SELECT DISTINCT share_id FROM shared_photos WHERE album_id = ? AND mine = 1 AND share_id != ''", [albumId]);
    for (final r in mine) {
      final rows = await db.query('shares', where: 'id = ?', whereArgs: [r['share_id']], limit: 1);
      if (rows.isEmpty) continue;
      try {
        await Shares.stop(SharedLink.fromRow(rows.first));
      } catch (e) {
        debugPrint('[friends] close album link: $e');
      }
    }
    await db.transaction((txn) async {
      await txn.delete('shared_photos', where: 'album_id = ?', whereArgs: [albumId]);
      await txn.delete('shared_albums', where: 'album_id = ?', whereArgs: [albumId]);
    });
    await Prefs.setText('friend_album_left', '${Prefs.text('friend_album_left')}\n$albumId'.trim());
    changed.value++;
    syncSoon();
  }

  /// Albums taken off this phone: a friend's box that still names one does
  /// not bring it back.
  static Set<String> get _leftAlbums => Prefs.text('friend_album_left').split('\n').where((s) => s.isNotEmpty).toSet();

  // ───────────── keeping both phones the same ─────────────

  static Timer? _soon;
  static bool _started = false;
  static Future<void>? _running;
  static bool _again = false;

  /// Call once at start: follows every change of a note, and looks at the
  /// friends' boxes every little while as long as BYTE is on screen.
  static void start() {
    if (_started) return;
    _started = true;
    NotesRepo.instance.revision.addListener(syncSoon);
    LibraryRepo.instance.revision.addListener(syncSoon);
    Timer.periodic(const Duration(seconds: 45), (_) {
      if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) unawaited(sync());
    });
    syncSoon();
  }

  /// In a moment (several changes in a row make one round).
  static void syncSoon() {
    _soon?.cancel();
    _soon = Timer(const Duration(seconds: 2), () => unawaited(sync()));
  }

  /// One round with every friend. A call made while a round is running
  /// makes one more round follow it.
  static Future<void> sync() {
    final running = _running;
    if (running != null) {
      _again = true;
      return running;
    }
    return _running = _rounds().whenComplete(() => _running = null);
  }

  static Future<void> _rounds() async {
    do {
      _again = false;
      try {
        final friends = await list();
        if (friends.isEmpty) return;
        if (!await CloudSync.connected()) return;
        for (final f in friends) {
          // Each friend on their own: one that cannot be reached does not hold up the others.
          try {
            await _round(f);
          } catch (e) {
            debugPrint('[friends] ${f.name}: $e');
          }
        }
      } catch (e) {
        debugPrint('[friends] sync: $e');
      }
    } while (_again);
  }

  static Future<Map<String, SharedItem>> _known(String listId) async {
    final rows = await AppDb.instance.db.query('shared_items', where: 'list_id = ?', whereArgs: [listId]);
    return {
      for (final r in rows)
        '${r['k']}': SharedItem(k: '${r['k']}', text: '${r['text'] ?? ''}', done: r['done'] == 1, gone: r['gone'] == 1, at: (r['at'] as int?) ?? 0),
    };
  }

  static Future<void> _save(String listId, Map<String, SharedItem> items) async {
    await AppDb.instance.db.transaction((txn) async {
      await txn.delete('shared_items', where: 'list_id = ?', whereArgs: [listId]);
      for (final i in items.values) {
        await txn.insert('shared_items', {'list_id': listId, 'k': i.k, 'text': i.text, 'done': i.done ? 1 : 0, 'gone': i.gone ? 1 : 0, 'at': i.at});
      }
    });
  }

  /// One friend: what changed here is noted, what changed there is laid over
  /// it, the notes are made to match, and this phone's box is written again
  /// if it now says something new.
  static Future<void> _round(Friend f) async {
    final db = AppDb.instance.db;
    final now = DateTime.now().millisecondsSinceEpoch;

    // 1. What changed on this phone.
    for (final l in await db.query('shared_lists', where: 'friend_id = ? AND closed = 0', whereArgs: [f.id])) {
      final listId = '${l['list_id']}';
      final noteId = '${l['note_id']}';
      // In the bin, or made private: sharing stops (the list itself is yours to keep).
      if ((await LibraryRepo.instance.inLibrary([noteId])).isEmpty) {
        await db.update('shared_lists', {'closed': 1}, where: 'list_id = ?', whereArgs: [listId]);
        continue;
      }
      final note = await NotesRepo.instance.get(noteId);
      if (note == null) continue;
      final (items, changedHere) = absorb(note.body, await _known(listId), now);
      if (changedHere) await _save(listId, forgetOld(items, now));
    }

    // 2. What the friend's box says.
    final raw = await CloudSync.boxRead(f.theirBox);
    if (raw != null) {
      try {
        await _takeIn(f, jsonDecode(raw));
      } catch (e) {
        debugPrint('[friends] their box: $e');
      }
    }

    // 3. This phone's box, when it has something new to say.
    final lists = <Map<String, Object>>[];
    for (final l in await db.query('shared_lists', where: 'friend_id = ?', whereArgs: [f.id], orderBy: 'list_id')) {
      final listId = '${l['list_id']}';
      final closed = l['closed'] == 1;
      final items = closed ? <SharedItem>[] : (await _known(listId)).values.toList();
      if (items.isNotEmpty) {
        // In the order of the note (so a list that is new on the friend's
        // phone reads the same way); what the note no longer has comes last.
        final note = await NotesRepo.instance.get('${l['note_id']}');
        final place = <String, int>{};
        for (final line in parseLines(note?.body ?? '')) {
          if (line.isTask) place.putIfAbsent(itemKey(line.text), () => place.length);
        }
        items.sort((a, b) {
          final byPlace = (place[a.k] ?? 1 << 30).compareTo(place[b.k] ?? 1 << 30);
          return byPlace != 0 ? byPlace : a.k.compareTo(b.k);
        });
      }
      // (A list that is no longer shared says nothing but that.)
      lists.add({'id': listId, 'title': closed ? '' : '${l['title'] ?? ''}', 'closed': closed, 'items': [for (final i in items) i.toJson()]});
    }
    // The albums: only this phone's own photos (the friend lists theirs).
    // A copy whose link was closed ("Links you made" → Stop) is no longer there.
    await db.rawDelete("DELETE FROM shared_photos WHERE mine = 1 AND share_id NOT IN (SELECT id FROM shares)");
    final albums = <Map<String, Object>>[];
    for (final a in await db.query('shared_albums', where: 'friend_id = ?', whereArgs: [f.id], orderBy: 'album_id')) {
      final albumId = '${a['album_id']}';
      final mine = await db.query('shared_photos', where: 'album_id = ? AND mine = 1', whereArgs: [albumId], orderBy: 'k');
      albums.add({
        'id': albumId,
        'title': '${a['title'] ?? ''}',
        'photos': [
          for (final p in mine) {'k': '${p['k']}', 'name': '${p['name'] ?? ''}', 'kind': '${p['kind'] ?? 'photo'}', 'at': (p['at'] as int?) ?? 0},
        ],
      });
    }
    final me = await _myId();
    final box = jsonEncode({
      'v': 1,
      'from': {'id': me, 'name': myName},
      'to': f.id,
      'lists': lists,
      'albums': albums,
    });
    // (Only written when it says something it did not say the last time.)
    final said = md5.convert(utf8.encode(box)).toString();
    final key = 'friend_box_said_${f.id}';
    if (Prefs.text(key) == said) return;
    await CloudSync.boxWrite('box-${me.substring(0, 8)}.json', box, existingId: f.myBox);
    await Prefs.setText(key, said);
  }

  /// The friend's side of each shared album: their photos, exactly as their
  /// box lists them (an album that is new here appears; photos they took
  /// out disappear).
  static Future<void> _takeInAlbums(Friend f, Object? albums) async {
    if (albums is! List) return;
    final db = AppDb.instance.db;
    final left = _leftAlbums;
    var any = false;
    // An album of this friend that their box no longer names: they took it
    // off their phone, so their photos leave it here too.
    final named = <String>{
      for (final a in albums)
        if (a is Map) '${a['id'] ?? ''}',
    };
    for (final r in await db.query('shared_albums', columns: ['album_id'], where: 'friend_id = ?', whereArgs: [f.id])) {
      final albumId = '${r['album_id']}';
      if (named.contains(albumId)) continue;
      if (await db.delete('shared_photos', where: 'album_id = ? AND mine = 0', whereArgs: [albumId]) > 0) any = true;
    }
    for (final a in albums) {
      if (a is! Map) continue;
      final albumId = '${a['id'] ?? ''}';
      if (albumId.isEmpty || left.contains(albumId)) continue;
      final theirs = <Map<String, Object?>>[
        for (final p in a['photos'] is List ? a['photos'] as List : const <dynamic>[])
          if (p is Map && '${p['k'] ?? ''}'.isNotEmpty)
            {'album_id': albumId, 'k': '${p['k']}', 'name': '${p['name'] ?? ''}', 'kind': p['kind'] == 'video' ? 'video' : 'photo', 'at': p['at'] is int ? p['at'] : 0},
      ];
      final known = await db.query('shared_albums', where: 'album_id = ?', whereArgs: [albumId], limit: 1);
      if (known.isEmpty) {
        if (theirs.isEmpty) continue;
        await db.insert('shared_albums', {'album_id': albumId, 'friend_id': f.id, 'title': '${a['title'] ?? ''}'.trim().isEmpty ? 'Album' : '${a['title']}'.trim(), 'made_at': DateTime.now().millisecondsSinceEpoch});
        any = true;
      } else if ('${known.first['friend_id']}' != f.id) {
        continue;
      }
      final had = await db.query('shared_photos', columns: ['k'], where: 'album_id = ? AND mine = 0', whereArgs: [albumId]);
      final before = {for (final r in had) '${r['k']}'};
      final after = {for (final r in theirs) '${r['k']}'};
      if (before.length == after.length && before.containsAll(after)) continue;
      await db.transaction((txn) async {
        await txn.delete('shared_photos', where: 'album_id = ? AND mine = 0', whereArgs: [albumId]);
        for (final r in theirs) {
          // (A copy that is already listed as this phone's own stays that.)
          await txn.rawInsert(
            "INSERT OR IGNORE INTO shared_photos (album_id, k, name, kind, mine, share_id, at) VALUES (?, ?, ?, ?, 0, '', ?)",
            [r['album_id'], r['k'], r['name'], r['kind'], r['at']],
          );
        }
      });
      any = true;
    }
    if (any) changed.value++;
  }

  /// Lays the friend's box over this phone's copy of each shared list.
  static Future<void> _takeIn(Friend f, Object? box) async {
    if (box is! Map) return;
    // Only a box that is written for THIS phone: an invite pasted by two
    // people must not hand the second one the first one's lists.
    if ('${box['to'] ?? ''}' != await _myId()) return;
    final db = AppDb.instance.db;
    if (box['bye'] == true) {
      // The friend removed you: every list stays, on its own — and their
      // photos leave the albums (they are no longer shared).
      final n = await db.update('shared_lists', {'closed': 1}, where: 'friend_id = ? AND closed = 0', whereArgs: [f.id]);
      final gone = await db.rawDelete('DELETE FROM shared_photos WHERE mine = 0 AND album_id IN (SELECT album_id FROM shared_albums WHERE friend_id = ?)', [f.id]);
      if (n > 0 || gone > 0) changed.value++;
      return;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final from = box['from'];
    // The friend changed the name they go by.
    final name = from is Map ? '${from['name'] ?? ''}'.trim() : '';
    if (name.isNotEmpty && name != f.name) {
      await db.update('friends', {'name': name}, where: 'id = ?', whereArgs: [f.id]);
      changed.value++;
    }
    await _takeInAlbums(f, box['albums']);
    final lists = box['lists'];
    for (final r in lists is List ? lists : const <dynamic>[]) {
      if (r is! Map) continue;
      final listId = '${r['id'] ?? ''}';
      if (listId.isEmpty) continue;
      final closed = r['closed'] == true;
      final remote = <SharedItem>[
        for (final i in r['items'] is List ? r['items'] as List : const <dynamic>[]) ?SharedItem.fromJson(i),
      ].where((i) => remembered(i, now)).toList();
      final mine = await db.query('shared_lists', where: 'list_id = ?', whereArgs: [listId], limit: 1);

      if (mine.isEmpty) {
        // A list the friend just shared: it becomes a checklist on this phone.
        if (closed) continue;
        final (items, _) = mergeRemote(const {}, remote);
        final title = '${r['title'] ?? ''}'.trim();
        final note = await NotesRepo.instance.create(title: title.isEmpty ? 'Shared list' : title, body: applyTo('', items));
        await db.insert('shared_lists', {'list_id': listId, 'friend_id': f.id, 'note_id': note.id, 'title': title, 'closed': 0});
        await _save(listId, items);
        changed.value++;
        continue;
      }
      if (mine.first['closed'] == 1 || '${mine.first['friend_id']}' != f.id) continue;
      if (closed) {
        // The friend stopped sharing (or binned the list): this one stays, on its own.
        await db.update('shared_lists', {'closed': 1}, where: 'list_id = ?', whereArgs: [listId]);
        changed.value++;
        continue;
      }
      final (items, changedThere) = mergeRemote(await _known(listId), remote);
      if (!changedThere) continue;
      // The note first, then what is known: if it stops in between, the next
      // round simply does it again. (The other way round, an item that never
      // reached the note would look like one you removed.)
      final note = await NotesRepo.instance.get('${mine.first['note_id']}');
      if (note != null) {
        final body = applyTo(note.body, items);
        if (body != note.body) await NotesRepo.instance.update(note.copyWith(body: body));
      }
      await _save(listId, items);
    }
  }
}
