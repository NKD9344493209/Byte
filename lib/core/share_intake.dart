import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../features/library/library_repo.dart';
import '../features/library/library_viewer.dart';
import '../features/notes/notes_repo.dart';
import 'capture_trigger.dart';

/// Things shared to BYTE from other apps (gallery, files, YouTube, plain
/// text). Files and links go to the Library; plain text becomes a note.
/// One thing shared → it opens; several → a short "Saved N items".
class ShareIntake {
  ShareIntake._();

  static const _channel = MethodChannel('byte/share');
  static bool _inited = false;

  static Future<void> init() async {
    if (!Platform.isAndroid || _inited) return;
    _inited = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'shared') {
        await _handle(_asList(call.arguments));
      }
    });
    try {
      final pending = await _channel.invokeMethod<List<dynamic>>('consumePendingShares');
      if (pending != null && pending.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _handle(_asList(pending)));
      }
    } catch (e) {
      debugPrint('[share] init: $e');
    }
  }

  static List<Map<String, String>> _asList(dynamic raw) {
    final out = <Map<String, String>>[];
    if (raw is List) {
      for (final e in raw) {
        if (e is Map) {
          out.add({for (final kv in e.entries) kv.key.toString(): kv.value?.toString() ?? ''});
        }
      }
    }
    return out;
  }

  static final _urlRe = RegExp(r'https?://[^\s]+', caseSensitive: false);

  static Future<void> _handle(List<Map<String, String>> items) async {
    String? lastId; // a Library item to open when exactly one thing came in
    var count = 0;
    var notes = 0;
    for (final it in items) {
      try {
        if (it['type'] == 'file') {
          final added = await LibraryRepo.instance.importFile(
            it['path']!,
            displayName: it['name'],
            source: 'share',
            move: true,
          );
          lastId = added.id;
          count++;
        } else if (it['type'] == 'text') {
          final text = it['text'] ?? '';
          final m = _urlRe.firstMatch(text);
          if (m != null) {
            final url = m.group(0)!;
            final rest = text.replaceFirst(url, '').trim();
            final added = await LibraryRepo.instance.addLink(
              url,
              title: rest.isNotEmpty && rest.length < 120 ? rest : (it['subject'] ?? ''),
              source: 'share',
            );
            lastId = added.id;
          } else {
            await NotesRepo.instance.create(title: it['subject'] ?? '', body: text);
            lastId = null;
            notes++;
          }
          count++;
        }
      } catch (e) {
        debugPrint('[share] item failed: $e');
      }
    }
    if (count == 0) return;
    final nav = CaptureTrigger.navigatorKey.currentState;
    if (nav == null) return;
    final openId = lastId;
    if (count == 1 && openId != null) {
      nav.push(MaterialPageRoute<void>(builder: (_) => LibraryViewer(itemId: openId)));
      return;
    }
    // Not tied to a widget that could have gone away: the navigator is global.
    final messenger = ScaffoldMessenger.maybeOf(nav.context); // ignore: use_build_context_synchronously
    messenger?.showSnackBar(
      SnackBar(
        content: Text(count == 1 && notes == 1 ? 'Saved as a note in BYTE' : 'Saved $count item${count == 1 ? '' : 's'} to BYTE'),
      ),
    );
  }
}
