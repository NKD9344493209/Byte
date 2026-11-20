import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:record/record.dart';

import '../../core/capture_trigger.dart';
import 'audio_item.dart';
import 'audio_repo.dart';
import 'audio_compress.dart';

/// One recorder for the whole app.
///
/// Streams raw 16 kHz mono PCM from the mic straight into a WAV file. If the
/// mic stream stalls (audio re-route, Bluetooth link coming/going), it is
/// reopened and keeps appending to the same file — the user never notices.
class RecorderService extends ChangeNotifier {
  RecorderService._();
  static final RecorderService instance = RecorderService._();

  static const sampleRate = 16000;
  static const channels = 1;
  static const bytesPerSample = 2;
  static const _bytesPerSecond = sampleRate * channels * bytesPerSample;
  static const _headerSize = 44;

  final AudioRecorder _rec = AudioRecorder();

  bool _recording = false;
  bool get isRecording => _recording;

  String? _currentId;
  String? _currentPath;
  RandomAccessFile? _file;
  int _dataBytes = 0;

  StreamSubscription<Uint8List>? _sub;
  Timer? _tick;
  DateTime _lastData = DateTime.now();
  DateTime _streamOpened = DateTime.now();
  bool _reopening = false;
  int _reopens = 0;
  int get reopens => _reopens;

  final Stopwatch _clock = Stopwatch();
  Duration get elapsed => _clock.elapsed;

  /// Seconds of audio actually captured (not wall-clock).
  Duration get captured =>
      Duration(milliseconds: (_dataBytes * 1000) ~/ _bytesPerSecond);

  /// 0.0 (silence) .. 1.0 (loud), smoothed for the level meter.
  double _level = 0;
  double get level => _level;
  double _peak = 0;
  double get peak => _peak;

  /// Loudest reading in dBFS since start. Live mic > -90; dead input = -160.
  double _peakDb = -160;
  double get peakDb => _peakDb;
  int _samples = 0;
  int get samples => _samples;

  String? _error;
  String? get error => _error;

  Future<bool> hasPermission() => _rec.hasPermission();

  RecordConfig get _config => const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: sampleRate,
        numChannels: channels,
        androidConfig: AndroidRecordConfig(
          // Phone mic, no Bluetooth voice link: the only stable route.
          manageBluetooth: false,
          audioSource: AndroidAudioSource.mic,
        ),
      );

  /// When continuing an older recording: its id (the UI shows "adding to…").
  String? _appendTo;
  String? get appendingTo => _appendTo;
  Duration _appendBase = Duration.zero;

  /// Seconds already in the file before this session (when continuing).
  Duration get appendBase => _appendBase;

  /// Starts a new recording, or — with [continueItem] — keeps recording at the
  /// end of an existing one (same WAV format, so the bytes just append).
  Future<bool> start({AudioItem? continueItem}) async {
    if (_recording) return true;
    _error = null;

    if (!await _rec.hasPermission()) {
      _error = 'Microphone permission was denied.';
      notifyListeners();
      return false;
    }

    String id;
    String path;
    var existing = 0;
    if (continueItem != null) {
      id = continueItem.id;
      path = continueItem.path;
      try {
        // A shrunk (.m4a) note is expanded back to WAV so we can append to it.
        if (path.toLowerCase().endsWith('.m4a')) {
          final wav = await AudioCompressor.expand(id, path);
          if (wav == null) throw 'could not expand the compressed recording';
          path = wav;
        }
        final f = File(path);
        if (!await f.exists()) throw 'file missing';
        final len = await f.length();
        if (len < _headerSize || !await isPcm16Mono16k(f)) {
          _error = 'That recording isn\'t in BYTE\'s own format, so I can\'t add to it. Record a new one instead.';
          notifyListeners();
          return false;
        }
        existing = len - _headerSize;
        _file = await f.open(mode: FileMode.append); // positioned at the end
      } catch (e) {
        _error = 'Could not open the recording: $e';
        notifyListeners();
        return false;
      }
    } else {
      final fresh = await AudioRepo.instance.newRecordingPath();
      id = fresh.$1;
      path = fresh.$2;
      try {
        _file = await File(path).open(mode: FileMode.write);
        await _file!.writeFrom(Uint8List(_headerSize)); // placeholder header
      } catch (e) {
        _error = 'Could not create file: $e';
        notifyListeners();
        return false;
      }
    }

    _appendTo = continueItem?.id;
    _appendBase = Duration(milliseconds: (existing * 1000) ~/ _bytesPerSecond);
    _currentId = id;
    _currentPath = path;
    _dataBytes = existing;
    _level = 0;
    _peak = 0;
    _peakDb = -160;
    _samples = 0;
    _reopens = 0;
    _reopening = false;
    _recording = true;
    _clock
      ..reset()
      ..start();

    final ok = await _openStream();
    if (!ok) {
      await _abort();
      return false;
    }

    _tick = Timer.periodic(const Duration(milliseconds: 200), (_) {
      _watchStall();
      notifyListeners();
    });
    notifyListeners();
    return true;
  }

  Future<bool> _openStream() async {
    try {
      await CaptureTrigger.micBusy();
      final stream = await _rec.startStream(_config);
      _streamOpened = DateTime.now();
      _lastData = _streamOpened;
      _sub = stream.listen(_onChunk, onError: (Object e) {
        debugPrint('[rec] stream error: $e');
      });
      return true;
    } catch (e) {
      _error = 'Could not start recording: $e';
      return false;
    }
  }

  /// A second listener for the sound as it is recorded (16 kHz, mono, 16-bit):
  /// live words use it. The file is always written first; whatever this does
  /// can never cost a recording.
  void Function(Uint8List chunk)? onPcm;

  void _onChunk(Uint8List chunk) {
    final f = _file;
    if (f == null || !_recording) return;
    try {
      f.writeFromSync(chunk);
    } catch (e) {
      debugPrint('[rec] write error: $e');
      return;
    }
    try {
      onPcm?.call(chunk);
    } catch (_) {}
    _dataBytes += chunk.length;
    _lastData = DateTime.now();
    _samples++;

    // Level from the PCM itself (every 4th sample is plenty).
    final bd = ByteData.sublistView(chunk);
    var maxAbs = 0;
    for (var i = 0; i + 1 < chunk.length; i += 8) {
      final v = bd.getInt16(i, Endian.little).abs();
      if (v > maxAbs) maxAbs = v;
    }
    final db = maxAbs == 0 ? -160.0 : 20 * math.log(maxAbs / 32768) / math.ln10;
    if (db > _peakDb) _peakDb = db;
    final normalized = ((db + 50) / 50).clamp(0.0, 1.0);
    _level = _level * 0.6 + normalized * 0.4;
    if (normalized > _peak) _peak = normalized;
  }

  /// If no audio has arrived for a while, the input was re-routed under us.
  /// Reopen the mic stream; the file keeps growing from where it was.
  Future<void> _watchStall() async {
    if (!_recording || _reopening) return;
    final now = DateTime.now();
    final sinceData = now.difference(_lastData);
    final sinceOpen = now.difference(_streamOpened);
    if (sinceData > const Duration(milliseconds: 1200) &&
        sinceOpen > const Duration(milliseconds: 1500)) {
      _reopening = true;
      _reopens++;
      debugPrint('[rec] mic stalled ${sinceData.inMilliseconds}ms → reopen #$_reopens');
      try {
        await _sub?.cancel();
        _sub = null;
        try {
          await _rec.stop();
        } catch (_) {}
        await Future<void>.delayed(const Duration(milliseconds: 250));
        if (_recording) await _openStream();
      } finally {
        _reopening = false;
      }
    }
  }

  /// Stops and saves. Returns the saved item, or null if nothing usable.
  Future<AudioItem?> stop({String source = 'manual'}) async {
    if (!_recording) return null;
    _recording = false;
    _tick?.cancel();
    _tick = null;
    _clock.stop();

    await _sub?.cancel();
    _sub = null;
    try {
      await _rec.stop();
    } catch (e) {
      debugPrint('[rec] stop error: $e');
    }
    await CaptureTrigger.micFree();

    final id = _currentId;
    final path = _currentPath;
    final duration = captured;
    await _finalizeFile();
    _level = 0;
    notifyListeners();

    if (id == null || path == null) return null;

    if (_appendTo != null) {
      // Continued an old recording: just update its length.
      final appended = _appendTo!;
      _appendTo = null;
      _appendBase = Duration.zero;
      await AudioRepo.instance.updateDuration(appended, duration);
      return AudioRepo.instance.get(appended);
    }

    if (duration < const Duration(milliseconds: 500)) {
      _error = _dataBytes == 0
          ? 'The microphone produced no audio. Nothing was saved.'
          : 'Too short — nothing saved.';
      try {
        await File(path).delete();
      } catch (_) {}
      notifyListeners();
      return null;
    }

    final saved = await AudioRepo.instance.save(
      id: id,
      path: path,
      duration: duration,
      source: source,
    );
    // A little later, shrink it (and anything else still in WAV). "Continue
    // recording" keeps working: a shrunk note is expanded back first.
    Future<void>.delayed(const Duration(seconds: 90), AudioCompressor.compressDue);
    return saved;
  }

  Future<void> cancel() async {
    if (!_recording) return;
    await _abort();
  }

  Future<void> _abort() async {
    _recording = false;
    _tick?.cancel();
    _tick = null;
    _clock.stop();
    await _sub?.cancel();
    _sub = null;
    try {
      await _rec.stop();
    } catch (_) {}
    // Covers cancel() and a failed start(): the ear took a micBusy() in
    // _openStream and must get its micFree() back.
    await CaptureTrigger.micFree();
    final path = _currentPath;
    if (_appendTo != null) {
      // Cancelled while adding to an old recording: cut it back to what it was.
      final keep = (_appendBase.inMilliseconds * _bytesPerSecond) ~/ 1000;
      _appendTo = null;
      _appendBase = Duration.zero;
      try {
        final f = _file;
        if (f != null) {
          await f.truncate(_headerSize + keep);
          _dataBytes = keep;
          await f.close();
        }
      } catch (_) {}
      _file = null;
      _level = 0;
      notifyListeners();
      return;
    }
    try {
      await _file?.close();
    } catch (_) {}
    _file = null;
    if (path != null) {
      try {
        await File(path).delete();
      } catch (_) {}
    }
    _level = 0;
    notifyListeners();
  }

  /// True when the WAV header says 16-bit mono 16 kHz PCM (BYTE's own format).
  static Future<bool> isPcm16Mono16k(File f) async {
    try {
      final raf = await f.open();
      final head = await raf.read(_headerSize);
      await raf.close();
      if (head.length < _headerSize) return false;
      final bd = ByteData.sublistView(head);
      final riff = String.fromCharCodes(head.sublist(0, 4));
      final wave = String.fromCharCodes(head.sublist(8, 12));
      if (riff != 'RIFF' || wave != 'WAVE') return false;
      return bd.getUint16(20, Endian.little) == 1 &&
          bd.getUint16(22, Endian.little) == channels &&
          bd.getUint32(24, Endian.little) == sampleRate &&
          bd.getUint16(34, Endian.little) == bytesPerSample * 8;
    } catch (_) {
      return false;
    }
  }

  /// Writes the real WAV header now that the data length is known.
  Future<void> _finalizeFile() async {
    final f = _file;
    if (f == null) return;
    try {
      final header = ByteData(_headerSize);
      void str(int off, String s) {
        for (var i = 0; i < s.length; i++) {
          header.setUint8(off + i, s.codeUnitAt(i));
        }
      }

      str(0, 'RIFF');
      header.setUint32(4, 36 + _dataBytes, Endian.little);
      str(8, 'WAVE');
      str(12, 'fmt ');
      header.setUint32(16, 16, Endian.little); // PCM chunk size
      header.setUint16(20, 1, Endian.little); // PCM format
      header.setUint16(22, channels, Endian.little);
      header.setUint32(24, sampleRate, Endian.little);
      header.setUint32(28, _bytesPerSecond, Endian.little);
      header.setUint16(32, channels * bytesPerSample, Endian.little);
      header.setUint16(34, bytesPerSample * 8, Endian.little);
      str(36, 'data');
      header.setUint32(40, _dataBytes, Endian.little);

      await f.setPosition(0);
      await f.writeFrom(header.buffer.asUint8List());
      await f.flush();
    } catch (e) {
      debugPrint('[rec] header error: $e');
    } finally {
      try {
        await f.close();
      } catch (_) {}
      _file = null;
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    _sub?.cancel();
    _rec.dispose();
    super.dispose();
  }
}
