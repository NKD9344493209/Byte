import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// One reminder Android shows at a time of day ("Your licence runs out in a week").
class DocAlarm {
  const DocAlarm({required this.id, required this.at, required this.title, required this.text, this.noteId = '', this.index = -1});
  final int id;
  final DateTime at;
  final String title;
  final String text;

  /// Set for the reminder of a checklist item: the note, and the item's
  /// number in it. The reminder then has a "Done" button and opens that list.
  final String noteId;
  final int index;

  Map<String, Object> toJson() => {'id': id, 'at': at.millisecondsSinceEpoch, 'title': title, 'text': text, 'noteId': noteId, 'index': index};
}

/// The Dart side of DocAlerts.kt: hands Android the whole list of reminders.
/// Android keeps it (also across a restart of the phone) and shows each one
/// at its time, even when BYTE is closed.
class DocAlerts {
  DocAlerts._();

  static const _ch = MethodChannel('byte/alerts');

  /// Replaces every reminder of [group] that was set before with [alarms].
  /// 'docs': the document wallet. 'tasks': checklist items. The ids of the
  /// two groups must not overlap.
  static Future<void> setAll(List<DocAlarm> alarms, {String group = 'docs'}) async {
    if (!Platform.isAndroid) return;
    try {
      await _ch.invokeMethod<bool>('setAll', {'json': jsonEncode([for (final a in alarms) a.toJson()]), 'group': group});
    } catch (e) {
      debugPrint('[alerts] $e');
    }
  }
}
