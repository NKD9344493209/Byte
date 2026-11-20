import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

import '../../core/app_lock.dart';
import '../../core/capture_trigger.dart';
import '../../core/prefs.dart';
import '../../shared/theme.dart';
import '../../shared/ui.dart';
import '../../shared/wave.dart';
import '../voice/heard_fixes.dart';
import '../voice/live_words.dart';
import 'audio_item.dart';
import 'audio_repo.dart';
import 'recorder_service.dart';
import 'voice_note_screen.dart';

/// Full-screen hands-free recorder, opened by the neckband/assistant trigger.
///
/// Beep → record → stop on: second trigger, tap, or [silenceLimit] of quiet
/// after at least [minSpeech] of audio → beep → close.
class QuickCaptureScreen extends StatefulWidget {
  const QuickCaptureScreen({super.key, this.source = 'headset'});

  /// Who started it: headset | button | bubble | app. From the app itself the
  /// saved note opens right away so the words can be read and fixed; from the
  /// headset or the bubble BYTE just saves and gets out of the way.
  final String source;

  static const silenceLimit = Duration(seconds: 5);
  static const minSpeech = Duration(seconds: 2);
  static const maxLength = Duration(minutes: 10);
  static const silenceLevel = 0.12;

  static _QuickCaptureScreenState? _active;

  /// Called by the trigger bridge when the button is pressed again.
  static void requestStop() => _active?._finish();

  @override
  State<QuickCaptureScreen> createState() => _QuickCaptureScreenState();
}

class _QuickCaptureScreenState extends State<QuickCaptureScreen> {
  final _rec = RecorderService.instance;
  final _beep = AudioPlayer();

  Timer? _watchdog;
  DateTime _lastLoud = DateTime.now();
  bool _finishing = false;
  bool _live = false; // mic confirmed working; timer + stop button visible
  DateTime _liveSince = DateTime.now();
  String _status = 'Opening the mic…';
  bool _saved = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    QuickCaptureScreen._active = this;
    _rec.addListener(_onRecorder);
    _begin();
  }

  @override
  void dispose() {
    if (QuickCaptureScreen._active == this) QuickCaptureScreen._active = null;
    _rec.removeListener(_onRecorder);
    _watchdog?.cancel();
    if (_rec.isRecording && !_finishing) {
      _rec.cancel();
      unawaited(LiveWords.cancel());
      CaptureTrigger.captureStopped(); // else MainActivity.capturing stays true → every press lands in the app
    }
    _beep.dispose();
    super.dispose();
  }

  Future<void> _begin() async {
    // The headset press leaves the system holding the mic for a moment
    // (Bluetooth voice link for the old assistant). Open the mic quietly,
    // confirm real audio is flowing, and only then beep + show the timer.
    // 1. Beep FIRST — playing any sound while recording re-routes audio and
    //    stalls the mic on this phone.
    final nativeDone = await CaptureTrigger.consumeNativeBeep();
    if (!nativeDone) {
      try {
        await _beep.play(AssetSource('sounds/start.wav'));
      } catch (_) {}
    }
    // 2. End the headset's voice session so it drops its Bluetooth voice link
    //    and the phone mic is the stable input. Give the route time to settle
    //    (less if the native fast path already did this a moment ago).
    await CaptureTrigger.prepareMic();
    await Future<void>.delayed(Duration(milliseconds: nativeDone ? 250 : 500));
    if (!mounted) return; // closed before the mic was opened: record nothing

    bool live = false;
    String? failure;
    for (var attempt = 0; attempt < 3 && !live; attempt++) {
      if (!mounted) break; // closed meanwhile: stop trying
      if (attempt > 0) {
        await CaptureTrigger.prepareMic();
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      final ok = await _rec.start();
      if (!ok) {
        failure = _rec.error ?? 'Could not record.';
        break;
      }
      var waited = 0;
      while (waited < 2000 && !(_rec.samples > 2 && _rec.peakDb > -100)) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        waited += 200;
      }
      if (_rec.samples > 2 && _rec.peakDb > -100) {
        live = true;
      } else {
        await _rec.cancel();
      }
    }

    // Closed while the mic was opening (Back): nothing may keep recording unseen.
    if (!mounted) {
      if (_rec.isRecording) await _rec.cancel();
      return;
    }

    if (!live) {
      setState(() {
        _failed = true;
        _status = failure ?? 'Mic is blocked by another app.';
      });
      await Future<void>.delayed(const Duration(seconds: 2));
      if (mounted) Navigator.of(context).pop();
      return;
    }

    _liveSince = DateTime.now();
    // The words, live. If this phone cannot do it, the recording is all the
    // same. (Started before the screen shows "Recording", so the words of the
    // note before never flash up.)
    unawaited(LiveWords.start(locale: Prefs.voiceLocale));
    if (mounted) setState(() => _live = true);
    await CaptureTrigger.captureStarted(); // media session for button taps
    _armWatchdog();
  }

  void _armWatchdog() {
    _watchdog?.cancel();
    _lastLoud = DateTime.now();
    _watchdog = Timer.periodic(const Duration(milliseconds: 300), (_) async {
      if (!_rec.isRecording || _finishing) return;
      final now = DateTime.now();
      if (_rec.level > QuickCaptureScreen.silenceLevel) _lastLoud = now;

      // A headset tap reaches the music app, which resumes → stop & save.
      // (Skip the first 1.5 s so our own start beep doesn't count.)
      if (now.difference(_liveSince) > const Duration(milliseconds: 1500) &&
          await CaptureTrigger.isMusicActive()) {
        debugPrint('[quick] music resumed → stop');
        _finish();
        return;
      }

      final quiet = now.difference(_lastLoud);
      final spokeEnough = _rec.elapsed >= QuickCaptureScreen.minSpeech;
      if ((spokeEnough && quiet >= QuickCaptureScreen.silenceLimit) ||
          _rec.elapsed >= QuickCaptureScreen.maxLength) {
        _finish();
      }
    });
  }

  void _onRecorder() {
    if (mounted) setState(() {});
  }

  Future<void> _finish() async {
    debugPrint('[quick] finish requested (finishing=$_finishing)');
    if (_finishing) return;
    _finishing = true;
    _watchdog?.cancel();

    // Whatever happens while saving, Android must hear that the capture is over
    // (otherwise BYTE would stay over the lock screen and every press would mean "stop").
    AudioItem? saved;
    try {
      saved = await _rec.stop(source: 'neckband');
    } catch (e) {
      debugPrint('[quick] stop failed: $e');
    }
    final item = saved;
    await CaptureTrigger.captureStopped();
    if (mounted) {
      setState(() {
        _saved = item != null;
        _failed = item == null;
        _status = item != null
            ? 'Saved, ${AudioItem.formatDuration(item.duration)}'
            : (_rec.error ?? 'Too short, nothing saved');
      });
    }
    try {
      await _beep.play(AssetSource('sounds/stop.wav'));
    } catch (_) {}
    final shownAt = DateTime.now();
    // The last words arrive a moment after the sound stops. They are saved with
    // the note: as heard, and with the corrections you taught BYTE applied.
    // (This runs to the end even if the screen is closed meanwhile.)
    var heard = '';
    try {
      if (item == null) {
        await LiveWords.cancel();
      } else {
        heard = await LiveWords.stop();
        if (heard.isNotEmpty) {
          final (fixed, _) = await HeardFixes.apply(heard);
          await AudioRepo.instance.updateTranscript(item.id, raw: heard, clean: fixed);
        }
      }
    } catch (e) {
      debugPrint('[quick] words: $e');
    }
    final left = Duration(milliseconds: item != null ? 900 : 2500) - DateTime.now().difference(shownAt);
    if (left > Duration.zero) await Future<void>.delayed(left);
    if (!mounted) return;
    // (Not while BYTE is locked: the words stay behind the lock.)
    if (item != null && heard.isNotEmpty && widget.source == 'app' && (!AppLock.enabled || AppLock.unlocked.value)) {
      // Started inside BYTE: show what was heard, ready to fix.
      Navigator.of(context).pushReplacement(MaterialPageRoute<void>(builder: (_) => VoiceNoteScreen(itemId: item.id)));
    } else {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final recording = _rec.isRecording && _live;
    return PopScope(
      canPop: !recording,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _finish();
      },
      child: Scaffold(
        backgroundColor: ByteColors.bg,
        body: SafeArea(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: recording ? _finish : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: ByteSpace.page),
              child: Column(
                children: [
                  const Spacer(),
                  if (recording) ...[
                    // The state in words, the timer, the wave.
                    Text('Recording', style: tt.labelMedium?.copyWith(color: ByteColors.heyInk)),
                    const SizedBox(height: 10),
                    Text(
                      AudioItem.formatDuration(_rec.elapsed),
                      style: tt.displaySmall?.copyWith(fontSize: 56, fontFeatures: const [FontFeature.tabularFigures()]),
                    ),
                    const SizedBox(height: 18),
                    ListeningWave(level: _rec.level, height: 44, alignment: MainAxisAlignment.center),
                    const SizedBox(height: 18),
                    // What BYTE hears, as you say it (the last lines of it).
                    ValueListenableBuilder<String>(
                      valueListenable: LiveWords.text,
                      builder: (_, heard, _) {
                        if (heard.isEmpty) return const SizedBox.shrink();
                        final tail = heard.length > 220 ? '…${heard.substring(heard.length - 220)}' : heard;
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 18),
                          child: Text(tail, textAlign: TextAlign.center, maxLines: 5, overflow: TextOverflow.ellipsis, style: tt.bodyLarge),
                        );
                      },
                    ),
                    // Why no words appear, when it is the language pack that is missing.
                    ValueListenableBuilder<String>(
                      valueListenable: LiveWords.problem,
                      builder: (_, why, _) => why != 'language'
                          ? const SizedBox.shrink()
                          : Padding(
                              padding: const EdgeInsets.only(bottom: 18),
                              child: Text(
                                'No words this time: the offline speech pack for your language is not on the phone. The recording is fine.',
                                textAlign: TextAlign.center,
                                style: tt.bodySmall,
                              ),
                            ),
                    ),
                    Text(
                      '${widget.source == 'headset' ? 'Talk. Tap the neckband button to save' : 'Talk. Tap anywhere to save'}, or BYTE stops after ${QuickCaptureScreen.silenceLimit.inSeconds} seconds of quiet.',
                      textAlign: TextAlign.center,
                      style: tt.bodySmall,
                    ),
                  ] else ...[
                    if (_saved) const IconWell(Icons.check_rounded, tone: 'act', size: 56),
                    if (_failed) const IconWell(Icons.mic_off_rounded, tone: 'danger', size: 56),
                    if (_saved || _failed) const SizedBox(height: 16),
                    Text(
                      _status,
                      textAlign: TextAlign.center,
                      style: tt.headlineMedium?.copyWith(color: _saved ? ByteColors.accentDim : ByteColors.text),
                    ),
                  ],
                  const Spacer(),
                  if (recording) ...[
                    Material(
                      color: ByteColors.accentBright,
                      shape: const CircleBorder(),
                      child: InkWell(
                        customBorder: const CircleBorder(),
                        onTap: _finish,
                        child: SizedBox(
                          width: 72,
                          height: 72,
                          child: Icon(Icons.stop_rounded, size: 34, color: ByteColors.onAccent, semanticLabel: 'Stop and save'),
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text('Stop and save', style: tt.bodySmall),
                    const SizedBox(height: 32),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
