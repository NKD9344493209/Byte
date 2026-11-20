import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../../core/db.dart';
import 'library_item.dart';
import 'library_repo.dart';

/// A playlist / album / "watch later" — any mix of recordings, photos,
/// videos, notes and files. The built-in "Watch later" always exists.
class Collection {
  const Collection({required this.id, required this.name, required this.kind, required this.createdAt, this.icon = '', this.count = 0, this.sortOrder = 0, this.updatedAt});
  final String id;
  final String name;
  final String kind; // custom | later
  final String icon;
  final DateTime createdAt;
  final int count;
  final int sortOrder;

  /// When something was last added (null = empty playlist).
  final DateTime? updatedAt;

  bool get isLater => kind == 'later';

  static const laterId = 'later';

  static Collection fromRow(Map<String, Object?> r) {
    final upd = (r['updated_at'] as num?)?.toInt() ?? 0;
    return Collection(
      id: r['id'] as String,
      name: r['name'] as String? ?? '',
      kind: r['kind'] as String? ?? 'custom',
      icon: r['icon'] as String? ?? '',
      createdAt: DateTime.fromMillisecondsSinceEpoch((r['created_at'] as num?)?.toInt() ?? 0),
      count: (r['n'] as num?)?.toInt() ?? 0,
      sortOrder: (r['sort_order'] as num?)?.toInt() ?? 0,
      updatedAt: upd == 0 ? null : DateTime.fromMillisecondsSinceEpoch(upd),
    );
  }
}

class CollectionsRepo {
  CollectionsRepo._();
  static final CollectionsRepo instance = CollectionsRepo._();

  final ValueNotifier<int> revision = ValueNotifier<int>(0);
  Database get _db => AppDb.instance.db;
  void _bump() => revision.value++;

  /// Makes sure "Watch later" exists. Safe to call often.
  Future<void> ensureDefaults() async {
    final rows = await _db.query('collections', where: 'id = ?', whereArgs: [Collection.laterId], limit: 1);
    if (rows.isEmpty) {
      // "ignore": two screens asking at the same moment on a fresh install must not collide.
      await _db.insert(
        'collections',
        {
          'id': Collection.laterId,
          'name': 'Watch later',
          'kind': 'later',
          'icon': 'later',
          'created_at': DateTime.now().millisecondsSinceEpoch,
          'sort_order': -1,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }
  }

  /// All collections with live item counts (deleted items don't count).
  /// [kind] limits the count to one item kind (the Capture screen shows
  /// how many recordings each playlist has).
  /// [private] false (the default) lists your ordinary folders; true the
  /// folders inside the private space.
  Future<List<Collection>> list({LibraryKind? kind, bool private = false}) async {
    await ensureDefaults();
    final rows = await _db.rawQuery('''
      SELECT c.*, (
        SELECT COUNT(*) FROM collection_items ci
        JOIN items i ON i.id = ci.item_id
        WHERE ci.collection_id = c.id AND i.deleted_at IS NULL AND i.private = c.private ${kind == null ? '' : "AND i.type = '${kind.name}'"}
      ) AS n, (
        SELECT MAX(ci.added_at) FROM collection_items ci
        JOIN items i ON i.id = ci.item_id
        WHERE ci.collection_id = c.id AND i.deleted_at IS NULL AND i.private = c.private
      ) AS updated_at
      FROM collections c
      WHERE c.private = ${private ? 1 : 0}
      ORDER BY c.sort_order ASC, c.created_at ASC
    ''');
    return rows.map(Collection.fromRow).toList();
  }

  /// Up to [limit] of the newest items in a playlist — the cover picture(s)
  /// on its card. Items with a real thumbnail come first.
  Future<List<LibraryItem>> covers(String collectionId, {int limit = 4}) async {
    final rows = await _db.rawQuery('''
      SELECT ci.item_id FROM collection_items ci
      JOIN items i ON i.id = ci.item_id
      JOIN collections c ON c.id = ci.collection_id
      WHERE ci.collection_id = ? AND i.deleted_at IS NULL AND i.private = c.private
      ORDER BY ci.added_at DESC LIMIT 12
    ''', [collectionId]);
    final out = <LibraryItem>[];
    for (final r in rows) {
      final it = await LibraryRepo.instance.get(r['item_id'] as String);
      if (it != null) out.add(it);
    }
    // Pictures first so the card looks like a cover, not a grey icon.
    out.sort((a, b) {
      final pa = a.thumb.isNotEmpty || a.kind == LibraryKind.photo ? 0 : 1;
      final pb = b.thumb.isNotEmpty || b.kind == LibraryKind.photo ? 0 : 1;
      return pa.compareTo(pb);
    });
    return out.take(limit).toList();
  }

  Future<Collection?> get(String id) async {
    final rows = await _db.query('collections', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : Collection.fromRow(rows.first);
  }

  /// Finds by name (case-insensitive) — voice: "add this to my recipes playlist".
  Future<Collection?> byName(String name, {bool private = false}) async {
    final n = name.trim().toLowerCase();
    if (n.isEmpty) return null;
    final all = await list(private: private);
    for (final c in all) {
      if (c.name.toLowerCase() == n) return c;
    }
    for (final c in all) {
      if (c.name.toLowerCase().contains(n) || n.contains(c.name.toLowerCase())) return c;
    }
    return null;
  }

  Future<Collection> create(String name, {String icon = '', bool private = false}) async {
    final existing = await byName(name, private: private);
    if (existing != null && existing.name.toLowerCase() == name.trim().toLowerCase()) return existing;
    final c = Collection(id: const Uuid().v4(), name: name.trim(), kind: 'custom', icon: icon, createdAt: DateTime.now());
    await _db.insert('collections', {'id': c.id, 'name': c.name, 'kind': c.kind, 'icon': c.icon, 'created_at': c.createdAt.millisecondsSinceEpoch, 'sort_order': 0, 'private': private ? 1 : 0});
    _bump();
    return c;
  }

  Future<void> rename(String id, String name) async {
    if (id == Collection.laterId) return;
    await _db.update('collections', {'name': name.trim()}, where: 'id = ?', whereArgs: [id]);
    _bump();
  }

  /// Deletes the list only — the items stay in the vault.
  Future<void> delete(String id) async {
    if (id == Collection.laterId) return;
    await _db.delete('collection_items', where: 'collection_id = ?', whereArgs: [id]);
    await _db.delete('collections', where: 'id = ?', whereArgs: [id]);
    _bump();
  }

  // ───────────── membership ─────────────

  Future<void> add(String collectionId, String itemId) async {
    final pos = Sqflite.firstIntValue(await _db.rawQuery('SELECT COALESCE(MAX(position), 0) + 1 FROM collection_items WHERE collection_id = ?', [collectionId])) ?? 1;
    await _db.insert(
      'collection_items',
      {'collection_id': collectionId, 'item_id': itemId, 'added_at': DateTime.now().millisecondsSinceEpoch, 'position': pos},
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    _bump();
  }

  Future<void> addAll(String collectionId, Iterable<String> itemIds) async {
    for (final id in itemIds) {
      await add(collectionId, id);
    }
  }

  Future<void> remove(String collectionId, String itemId) async {
    await _db.delete('collection_items', where: 'collection_id = ? AND item_id = ?', whereArgs: [collectionId, itemId]);
    _bump();
  }

  Future<void> toggle(String collectionId, String itemId) async {
    if (await contains(collectionId, itemId)) {
      await remove(collectionId, itemId);
    } else {
      await add(collectionId, itemId);
    }
  }

  Future<bool> contains(String collectionId, String itemId) async {
    final n = Sqflite.firstIntValue(await _db.rawQuery('SELECT COUNT(*) FROM collection_items WHERE collection_id = ? AND item_id = ?', [collectionId, itemId])) ?? 0;
    return n > 0;
  }

  /// Which collections hold this item.
  Future<Set<String>> collectionsOf(String itemId) async {
    final rows = await _db.query('collection_items', columns: ['collection_id'], where: 'item_id = ?', whereArgs: [itemId]);
    return rows.map((r) => r['collection_id'] as String).toSet();
  }

  /// Item ids in a collection, in the order they were added. Things in the
  /// bin are left out (they come back to the folder when restored).
  Future<List<String>> itemIds(String collectionId) async {
    final rows = await _db.rawQuery(
      // (A private thing shows only in private folders, an ordinary one only in ordinary ones.)
      'SELECT ci.item_id FROM collection_items ci JOIN items i ON i.id = ci.item_id '
      'JOIN collections c ON c.id = ci.collection_id '
      'WHERE ci.collection_id = ? AND i.deleted_at IS NULL AND i.private = c.private '
      'ORDER BY ci.position ASC, ci.added_at ASC',
      [collectionId],
    );
    return rows.map((r) => r['item_id'] as String).toList();
  }

  /// Every item that sits in at least one of your own lists (not "Watch
  /// later"): the Library's main view hides these — a list is a folder.
  Future<Set<String>> filedItemIds() async {
    final rows = await _db.rawQuery("SELECT DISTINCT item_id FROM collection_items WHERE collection_id != 'later'");
    return rows.map((r) => r['item_id'] as String).toSet();
  }

  /// The items themselves (via the Library join), optionally one kind only.
  Future<List<LibraryItem>> items(String collectionId, {LibraryKind? kind}) async {
    final ids = await itemIds(collectionId);
    if (ids.isEmpty) return const [];
    final out = <LibraryItem>[];
    for (final id in ids) {
      final it = await LibraryRepo.instance.get(id);
      if (it == null) continue;
      if (kind != null && it.kind != kind) continue;
      out.add(it);
    }
    return out;
  }

  bool _tagsMigrated = false;

  /// One-time: the old audio "playlists" were tags on recordings. Turn each
  /// tag into a real collection so nothing the user made is lost.
  ///
  /// Runs once per launch and only bumps [revision] when something actually
  /// changed — callers listen to [revision] and reload, so bumping on every
  /// call would loop forever.
  Future<void> migrateAudioTags() async {
    if (_tagsMigrated) return;
    _tagsMigrated = true;
    final rows = await _db.rawQuery("SELECT id, tags FROM items WHERE type = 'audio' AND deleted_at IS NULL AND private = 0 AND tags != ''");
    if (rows.isEmpty) return;
    final byName = <String, Collection>{};
    for (final c in await list()) {
      byName[c.name.toLowerCase()] = c;
    }
    var changed = false;
    for (final r in rows) {
      final tags = (r['tags'] as String? ?? '').split(',').map((t) => t.trim()).where((t) => t.isNotEmpty);
      for (final t in tags) {
        var c = byName[t.toLowerCase()];
        if (c == null) {
          c = Collection(id: const Uuid().v4(), name: t, kind: 'custom', createdAt: DateTime.now());
          await _db.insert('collections', {'id': c.id, 'name': c.name, 'kind': c.kind, 'icon': '', 'created_at': c.createdAt.millisecondsSinceEpoch, 'sort_order': 0});
          byName[t.toLowerCase()] = c;
          changed = true;
        }
        final itemId = r['id'] as String;
        if (await contains(c.id, itemId)) continue;
        final pos = Sqflite.firstIntValue(await _db.rawQuery('SELECT COALESCE(MAX(position), 0) + 1 FROM collection_items WHERE collection_id = ?', [c.id])) ?? 1;
        await _db.insert(
          'collection_items',
          {'collection_id': c.id, 'item_id': itemId, 'added_at': DateTime.now().millisecondsSinceEpoch, 'position': pos},
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
        changed = true;
      }
    }
    if (changed) _bump();
  }
}
