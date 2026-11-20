import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/db.dart';
import '../../core/doc_alerts.dart';
import '../library/library_item.dart';
import '../library/library_repo.dart';

/// One paper in the document wallet.
class WalletDoc {
  const WalletDoc({required this.item, required this.label, required this.addedAt, this.expiresAt});
  final LibraryItem item;

  /// The name you gave it in the wallet ("Driving licence"); '' = its own name.
  final String label;
  final DateTime addedAt;

  /// The last day it is valid (null = it does not run out).
  final DateTime? expiresAt;

  String get name => label.trim().isNotEmpty ? label.trim() : item.displayTitle;
}

/// Calendar days from today until [expires] (0 = today, negative = past),
/// or null when there is no end date. Pure.
int? daysLeft(DateTime? expires, {DateTime? now}) {
  if (expires == null) return null;
  final n = now ?? DateTime.now();
  return DateTime.utc(expires.year, expires.month, expires.day).difference(DateTime.utc(n.year, n.month, n.day)).inDays;
}

/// "Valid until 12/3/2027 · 113 days left", "Runs out today", "Ran out on
/// 2/1/2026", or "No end date". Pure.
String validityText(DateTime? expires, {DateTime? now}) {
  final left = daysLeft(expires, now: now);
  if (expires == null || left == null) return 'No end date';
  final date = '${expires.day}/${expires.month}/${expires.year}';
  if (left < 0) return 'Ran out on $date';
  if (left == 0) return 'Runs out today ($date)';
  if (left == 1) return 'Valid until $date · 1 day left';
  return 'Valid until $date · $left days left';
}

/// When BYTE reminds you about a paper that runs out on [expires]: a month
/// before, a week before, the day before and on the day — each at 9 in the
/// morning, and only the ones still ahead of [now]. Pure.
List<({DateTime at, String text})> reminderTimes(String name, DateTime expires, {DateTime? now}) {
  final n = now ?? DateTime.now();
  final out = <({DateTime at, String text})>[];
  for (final (days, words) in const [(30, 'runs out in a month'), (7, 'runs out in a week'), (1, 'runs out tomorrow'), (0, 'runs out today')]) {
    final at = DateTime(expires.year, expires.month, expires.day - days, 9);
    if (at.isAfter(n)) out.add((at: at, text: '$name $words (${expires.day}/${expires.month}/${expires.year}).'));
  }
  return out;
}

/// The document wallet: the papers that matter (ID cards, licence, passport,
/// insurance, certificates), each with the day it stops being valid. BYTE
/// reminds you before that day, also when it is closed.
class Wallet {
  Wallet._();

  static final ValueNotifier<int> changed = ValueNotifier<int>(0);

  /// Everything in the wallet that is still in the Library, soonest end date first.
  static Future<List<WalletDoc>> list() async {
    final rows = await AppDb.instance.db.query('wallet');
    if (rows.isEmpty) return const [];
    final ids = [for (final r in rows) '${r['item_id']}'];
    final there = await LibraryRepo.instance.inLibrary(ids);
    final out = <WalletDoc>[];
    for (final r in rows) {
      final id = '${r['item_id']}';
      if (!there.contains(id)) continue; // in the bin or private now
      final it = await LibraryRepo.instance.get(id);
      if (it == null) continue;
      out.add(WalletDoc(
        item: it,
        label: '${r['label'] ?? ''}',
        addedAt: DateTime.fromMillisecondsSinceEpoch((r['added_at'] as int?) ?? 0),
        expiresAt: r['expires_at'] == null ? null : DateTime.fromMillisecondsSinceEpoch(r['expires_at'] as int),
      ));
    }
    out.sort((a, b) {
      final ea = a.expiresAt;
      final eb = b.expiresAt;
      if (ea == null && eb == null) return b.addedAt.compareTo(a.addedAt);
      if (ea == null) return 1;
      if (eb == null) return -1;
      return ea.compareTo(eb);
    });
    return out;
  }

  static Future<bool> has(String itemId) async {
    final rows = await AppDb.instance.db.query('wallet', columns: ['item_id'], where: 'item_id = ?', whereArgs: [itemId], limit: 1);
    return rows.isNotEmpty;
  }

  static Future<void> add(String itemId, {String label = '', DateTime? expires}) async {
    await AppDb.instance.db.rawInsert(
      'INSERT OR IGNORE INTO wallet (item_id, label, expires_at, added_at) VALUES (?, ?, ?, ?)',
      [itemId, label.trim(), expires?.millisecondsSinceEpoch, DateTime.now().millisecondsSinceEpoch],
    );
    changed.value++;
    await reschedule();
  }

  static Future<void> remove(String itemId) async {
    await AppDb.instance.db.delete('wallet', where: 'item_id = ?', whereArgs: [itemId]);
    changed.value++;
    await reschedule();
  }

  static Future<void> setExpiry(String itemId, DateTime? day) async {
    await AppDb.instance.db.update('wallet', {'expires_at': day?.millisecondsSinceEpoch}, where: 'item_id = ?', whereArgs: [itemId]);
    changed.value++;
    await reschedule();
  }

  static Future<void> setLabel(String itemId, String label) async {
    await AppDb.instance.db.update('wallet', {'label': label.trim()}, where: 'item_id = ?', whereArgs: [itemId]);
    changed.value++;
    await reschedule();
  }

  /// Photos and files BYTE sorted into "ID cards" that are not in the wallet yet.
  static Future<List<LibraryItem>> suggestions() async {
    try {
      final rows = await AppDb.instance.db.rawQuery('''
        SELECT pl.item_id AS id FROM item_places pl JOIN items i ON i.id = pl.item_id
        WHERE pl.place = 'ID cards' AND i.deleted_at IS NULL AND i.private = 0
          AND pl.item_id NOT IN (SELECT item_id FROM wallet)
        ORDER BY i.created_at DESC LIMIT 12
      ''');
      final out = <LibraryItem>[];
      for (final r in rows) {
        final it = await LibraryRepo.instance.get('${r['id']}');
        if (it != null) out.add(it);
      }
      return out;
    } catch (e) {
      debugPrint('[wallet] suggestions: $e');
      return const [];
    }
  }

  static Timer? _soon;
  static bool _watching = false;

  /// The Library changed (the bin, the private space, a new name): the
  /// reminders follow. Call once at start.
  static void watch() {
    if (_watching) return;
    _watching = true;
    LibraryRepo.instance.revision.addListener(() {
      _soon?.cancel();
      _soon = Timer(const Duration(seconds: 4), reschedule);
    });
  }

  /// Hands Android the reminders for everything that has an end date.
  /// Call at start and after every change.
  static Future<void> reschedule() async {
    try {
      final alarms = <DocAlarm>[];
      var id = 1;
      for (final d in await list()) {
        final e = d.expiresAt;
        if (e == null) continue;
        for (final r in reminderTimes(d.name, e)) {
          alarms.add(DocAlarm(id: id++, at: r.at, title: 'Document wallet', text: r.text));
        }
      }
      await DocAlerts.setAll(alarms);
    } catch (e) {
      debugPrint('[wallet] reschedule: $e');
    }
  }
}
