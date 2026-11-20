import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../features/library/library_repo.dart';
import 'db.dart';
import 'gallery.dart';

/// Small previews for gallery photos BYTE has not read yet.
///
/// Right after the gallery is brought in, thousands of photos have no preview
/// of their own. Opening each 12-megapixel original just to draw a small
/// square made the lists stutter; Android already keeps a small picture of
/// every photo, so that one is asked for instead — a few at a time, the ones
/// on screen first.
class Thumbs {
  Thumbs._();

  static const _atOnce = 4;

  static final Map<String, String> _made = <String, String>{};
  static final Set<String> _none = <String>{};
  static final List<_Want> _queue = <_Want>[];
  static final Map<String, _Want> _flying = <String, _Want>{};
  static int _running = 0;
  static String? _dir;

  /// The preview made earlier in this run, if any.
  static String? made(String itemId) => _made[itemId];

  /// Android has no small picture for this one.
  static bool hopeless(String itemId) => _none.contains(itemId);

  /// The preview of a gallery item, made now if needed. null = there is none.
  static Future<String?> want(String itemId, String mediaKey) {
    final have = _made[itemId];
    if (have != null) return Future<String?>.value(have);
    if (mediaKey.isEmpty || _none.contains(itemId)) return Future<String?>.value(null);
    final flying = _flying[itemId];
    if (flying != null) return flying.done.future;
    for (final w in _queue) {
      if (w.id == itemId) {
        w.waiting++;
        return w.done.future;
      }
    }
    final w = _Want(itemId, mediaKey);
    _queue.add(w);
    _pump();
    return w.done.future;
  }

  /// The square scrolled away before its turn came: no need to make it now.
  static void drop(String itemId) {
    for (var i = _queue.length - 1; i >= 0; i--) {
      final w = _queue[i];
      if (w.id != itemId) continue;
      if (--w.waiting <= 0) {
        _queue.removeAt(i);
        w.done.complete(null);
      }
      return;
    }
  }

  static void _pump() {
    while (_running < _atOnce && _queue.isNotEmpty) {
      final w = _queue.removeLast(); // asked for last = on screen now
      _running++;
      _flying[w.id] = w;
      _make(w).whenComplete(() {
        _running--;
        _flying.remove(w.id);
        _pump();
      });
    }
  }

  static Future<void> _make(_Want w) async {
    String? path;
    try {
      final dir = _dir ??= (await LibraryRepo.instance.thumbsDir()).path;
      final out = p.join(dir, '${w.id}.jpg');
      if (await File(out).exists() || await Gallery.thumb(w.key, out)) {
        path = out;
        _made[w.id] = out;
        // Remembered, so the next run has it at once.
        await AppDb.instance.db.rawUpdate("UPDATE files SET thumb = ? WHERE item_id = ? AND thumb = ''", [out, w.id]);
      } else {
        _none.add(w.id);
      }
    } catch (e) {
      debugPrint('[thumbs] $e');
    }
    if (!w.done.isCompleted) w.done.complete(path);
  }
}

class _Want {
  _Want(this.id, this.key);
  final String id;
  final String key;
  int waiting = 1;
  final Completer<String?> done = Completer<String?>();
}
