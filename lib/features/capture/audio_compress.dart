import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/cloud_sync.dart';
import '../../core/db.dart';
import 'audio_repo.dart';
import 'recorder_service.dart';

/// Shrinks finished recordings: WAV (1.9 MB/min) → AAC .m4a (0.24 MB/min),
/// same speech clarity. Runs by itself (launch, resume, after a recording
/// stops) on EVERY WAV that is not being recorded or transcribed right now —
/// one file at a time, until none are left — and on demand from
/// Settings → Storage. A compressed note can still be continued: it is
/// expanded back first ([expand]).
class AudioCompressor {
  AudioCompressor._();

  static const _ch = MethodChannel('byte/audio');
  static const kAuto = 'audio_auto_compress';
  static const kProgress = 'audio_shrink_progress'; // JSON {done,total,saved,at}
  static final ValueNotifier<String> status = ValueNotifier<String>('');

  /// "Shrunk 48 of 120 recordings" for the Storage screen.
  static final ValueNotifier<({int done, int total, int saved})> progress = ValueNotifier((done: 0, total: 0, saved: 0));

  static bool _busy = false;
  static bool get busy => _busy;

  /// Recording being converted right now (the transcriber waits for it).
  static String? workingOn;

  static bool get supported => Platform.isAndroid;

  static Future<bool> autoEnabled() async => (await SharedPreferences.getInstance()).getBool(kAuto) ?? true;
  static Future<void> setAuto(bool v) async => (await SharedPreferences.getInstance()).setBool(kAuto, v);

  /// Last run's numbers, from prefs (survives restarts).
  static Future<({int done, int total, int saved, DateTime? at})> savedProgress() async {
    try {
      final s = (await SharedPreferences.getInstance()).getString(kProgress);
      if (s == null) return (done: 0, total: 0, saved: 0, at: null);
      final j = jsonDecode(s) as Map;
      final at = (j['at'] as num?)?.toInt();
      return (done: (j['done'] as num?)?.toInt() ?? 0, total: (j['total'] as num?)?.toInt() ?? 0, saved: (j['saved'] as num?)?.toInt() ?? 0, at: at == null ? null : DateTime.fromMillisecondsSinceEpoch(at));
    } catch (_) {
      return (done: 0, total: 0, saved: 0, at: null);
    }
  }

  /// How many WAV recordings are left and roughly how much they would shrink by.
  static Future<({int count, int bytes})> pending() async {
    var count = 0;
    var bytes = 0;
    for (final r in await _wavRows()) {
      final f = File(r.path);
      if (!await f.exists()) continue;
      count++;
      bytes += await f.length();
    }
    return (count: count, bytes: (bytes * 7 / 8).round());
  }

  /// Every recording still stored as WAV — deleted ones too (they sit in the
  /// 30-day bin at full size otherwise). Oldest first. Recordings in the
  /// private space are left alone: those are locked as they are.
  static Future<List<({String id, String path})>> _wavRows() async {
    final rows = await AppDb.instance.db.rawQuery('''
      SELECT a.item_id AS id, a.path AS path
      FROM audio a JOIN items i ON i.id = a.item_id
      WHERE lower(a.path) LIKE '%.wav' AND i.private = 0
      ORDER BY i.created_at ASC
    ''');
    return [for (final r in rows) (id: r['id'] as String, path: r['path'] as String)];
  }

  /// Launch / resume / after a recording: shrink everything that is left.
  static Future<void> compressDue() async {
    try {
      if (!supported || !await autoEnabled()) return;
      await compressAll();
    } catch (e) {
      debugPrint('[aac] auto: $e');
    }
  }

  /// Returns (count, bytes saved). Loops until no WAV is left, skipping the
  /// one being transcribed; stops (and is retried later) if the mic is on.
  static Future<({int count, int saved})> compressAll({void Function(String)? onStatus}) async {
    if (_busy || !supported) return (count: 0, saved: 0);
    _busy = true;
    var count = 0;
    var saved = 0;
    var total = 0;
    final failed = <String>{};
    try {
      while (true) {
        if (RecorderService.instance.isRecording) break; // never touch files while recording
        final rows = (await _wavRows()).where((r) => !failed.contains(r.id)).toList();
        if (rows.isEmpty) break;
        if (count + rows.length > total) total = count + rows.length;
        progress.value = (done: count, total: total, saved: saved);
        final r = rows.first;
        final src = File(r.path);
        if (!await src.exists()) {
          failed.add(r.id);
          continue;
        }
        final before = await src.length();
        if (before < 44 + 16000) {
          failed.add(r.id); // < 0.5 s — not worth it
          continue;
        }
        final msg = 'Shrinking recording ${count + 1} of $total…';
        status.value = msg;
        onStatus?.call(msg);
        final out = p.setExtension(r.path, '.m4a');
        workingOn = r.id;
        int size;
        try {
          size = await _call('compress', r.path, out);
        } finally {
          workingOn = null;
        }
        if (size == _noPlugin) break; // background isolate: the native codec is not there
        if (size <= 0) {
          debugPrint('[aac] failed ${p.basename(r.path)}');
          failed.add(r.id);
          continue;
        }
        // Swap: DB first (so a crash never leaves a row pointing at a deleted file), then delete the WAV.
        await AppDb.instance.db.update('audio', {'path': out}, where: 'item_id = ?', whereArgs: [r.id]);
        try {
          await src.delete();
        } catch (_) {}
        // Cloud bookkeeping: the old name is gone locally; the new one uploads next sync.
        try {
          await CloudSync.forgetFile('audio/${p.basename(r.path)}');
        } catch (_) {}
        count++;
        saved += before - size;
        progress.value = (done: count, total: total, saved: saved);
        await _remember(count, total, saved);
      }
      if (count > 0) AudioRepo.instance.revision.value++;
      status.value = count == 0 ? '' : 'Shrunk $count recording${count == 1 ? '' : 's'}, saved ${(saved / (1024 * 1024)).toStringAsFixed(0)} MB';
      return (count: count, saved: saved);
    } finally {
      _busy = false;
    }
  }

  static Future<void> _remember(int done, int total, int saved) async {
    try {
      await (await SharedPreferences.getInstance()).setString(kProgress, jsonEncode({'done': done, 'total': total, 'saved': saved, 'at': DateTime.now().millisecondsSinceEpoch}));
    } catch (_) {}
  }

  /// Bring a compressed recording back to WAV (for "Continue recording").
  /// Returns the new WAV path, or null.
  static Future<String?> expand(String itemId, String m4aPath) async {
    if (!supported) return null;
    final out = p.setExtension(m4aPath, '.wav');
    final size = await _call('decompress', m4aPath, out);
    if (size <= 44) return null;
    await AppDb.instance.db.update('audio', {'path': out}, where: 'item_id = ?', whereArgs: [itemId]);
    try {
      await File(m4aPath).delete();
    } catch (_) {}
    AudioRepo.instance.revision.value++;
    return out;
  }

  /// A throw-away WAV copy of a compressed recording (for the transcriber,
  /// which reads WAV only). The caller deletes it. Null if it can't be made.
  static Future<String?> expandToTemp(String m4aPath) async {
    if (!supported) return null;
    final dir = await getTemporaryDirectory();
    final out = p.join(dir.path, '${p.basenameWithoutExtension(m4aPath)}-${DateTime.now().millisecondsSinceEpoch}.wav');
    final size = await _call('decompress', m4aPath, out);
    if (size <= 44) {
      try {
        await File(out).delete();
      } catch (_) {}
      return null;
    }
    return out;
  }

  static const _noPlugin = -2;

  static Future<int> _call(String method, String input, String output) async {
    try {
      final v = await _ch.invokeMethod<num>(method, {'input': input, 'output': output, 'bitrate': 32000});
      return v?.toInt() ?? -1;
    } on MissingPluginException {
      return _noPlugin; // no MainActivity (background job / assist sheet): skip quietly
    } catch (e) {
      debugPrint('[aac] $method: $e');
      return -1;
    }
  }
}
