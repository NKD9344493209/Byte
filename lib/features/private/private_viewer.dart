import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

import '../../core/private_space.dart';
import '../../shared/selection.dart';
import '../../shared/theme.dart';
import '../library/library_item.dart';
import '../library/library_repo.dart';

/// One private item, opened. Its locked file is unlocked into BYTE's cache
/// for as long as the private space is open, and wiped when it locks.
class PrivateViewer extends StatefulWidget {
  const PrivateViewer({super.key, required this.item});

  final LibraryItem item;

  @override
  State<PrivateViewer> createState() => _PrivateViewerState();
}

class _PrivateViewerState extends State<PrivateViewer> {
  /// The readable copy; null while it is being opened or when it cannot be.
  String? _path;
  bool _opening = true;
  bool _busy = false;

  LibraryItem get _it => widget.item;

  @override
  void initState() {
    super.initState();
    _open();
  }

  Future<void> _open() async {
    if (_it.kind == LibraryKind.link || !_it.hasFile) {
      setState(() => _opening = false);
      return;
    }
    setState(() => _opening = true);
    final path = await PrivateSpace.openPlain(_it);
    if (!mounted) return;
    setState(() {
      _path = path;
      _opening = false;
    });
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  Future<void> _share() async {
    final it = _it;
    // The share sheet covers BYTE: the space stays open for that.
    PrivateSpace.hold();
    try {
      if (it.kind == LibraryKind.link) {
        await SharePlus.instance.share(ShareParams(text: it.url));
        return;
      }
      final path = _path;
      if (path == null) {
        _snack('It is not open yet.');
        return;
      }
      await SharePlus.instance.share(ShareParams(files: [XFile(path)], text: it.displayTitle));
    } catch (e) {
      _snack('Could not share: $e');
    } finally {
      PrivateSpace.release();
    }
  }

  /// Hands the readable copy to another app (a PDF reader, Excel…).
  Future<void> _openWith() async {
    final it = _it;
    final path = _path;
    if (it.kind != LibraryKind.link && path == null) return;
    // The other app covers BYTE: the space stays open until you are back
    // (five minutes at most), so the copy it reads is not wiped under it.
    PrivateSpace.holdUntilBack();
    try {
      if (it.kind == LibraryKind.link) {
        await launchUrl(Uri.parse(it.url), mode: LaunchMode.externalApplication);
        return;
      }
      final r = await OpenFilex.open(path!);
      if (r.type != ResultType.done) {
        PrivateSpace.holdUntilBack(false);
        _snack('No app on this phone opens this kind of file.');
      }
    } catch (e) {
      PrivateSpace.holdUntilBack(false);
      _snack('Could not open: $e');
    }
  }

  Future<void> _moveOut() async {
    if (_busy) return;
    final ok = await confirmBulk(
      context,
      title: 'Take this out of the private space?',
      body: 'It goes back to your Library: shown there, found by Search, and stored in Google Drive like everything else.',
      action: 'Take out',
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    final nav = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final r = await PrivateSpace.moveOut([_it.id]);
    if (r.moved == 1) {
      messenger.showSnackBar(const SnackBar(content: Text('It is back in your Library.')));
      if (mounted) nav.pop();
      return;
    }
    if (mounted) setState(() => _busy = false);
    messenger.showSnackBar(const SnackBar(content: Text('It could not be unlocked right now. If it lives in Google Drive, it needs the internet. Try again in a moment.')));
  }

  Future<void> _delete() async {
    final ok = await confirmBulk(
      context,
      title: 'Move this to the private bin?',
      body: 'It stays there for 30 days. The private bin is in the menu of the private space.',
      action: 'Move to bin',
    );
    if (!ok || !mounted) return;
    final nav = Navigator.of(context);
    await LibraryRepo.instance.delete(_it.id);
    if (mounted) nav.pop();
  }

  // ───────────── UI ─────────────

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final it = _it;
    final about = [
      it.kind.label.replaceAll(RegExp(r's$'), ''),
      if (it.ext.isNotEmpty) it.ext,
      if (it.size > 0) humanSize(it.size),
      '${it.createdAt.day}/${it.createdAt.month}/${it.createdAt.year}',
    ].join(', ');
    final isDoc = it.kind == LibraryKind.doc;
    return Scaffold(
      appBar: AppBar(
        title: Text(it.displayTitle, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(tooltip: 'Share', icon: const Icon(Icons.ios_share_rounded), onPressed: _share),
          PopupMenuButton<String>(
            tooltip: 'More',
            onSelected: (v) {
              switch (v) {
                case 'open':
                  _openWith();
                case 'out':
                  _moveOut();
                case 'delete':
                  _delete();
              }
            },
            itemBuilder: (_) => [
              if (it.kind != LibraryKind.link) const PopupMenuItem(value: 'open', child: Text('Open in another app')),
              const PopupMenuItem(value: 'out', child: Text('Take out of the private space')),
              PopupMenuItem(value: 'delete', child: Text('Move to the private bin', style: TextStyle(color: ByteColors.danger))),
            ],
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 40),
        children: [
          if (_busy) const LinearProgressIndicator(minHeight: 2),
          _media(context),
          Padding(
            padding: const EdgeInsets.fromLTRB(ByteSpace.page, 16, ByteSpace.page, 0),
            child: Text(about, style: tt.bodySmall),
          ),
          if (isDoc && _path != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(ByteSpace.page, 14, ByteSpace.page, 0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.tonal(style: inlineButton, onPressed: _openWith, child: const Text('Open it')),
              ),
            ),
          if (isDoc)
            Padding(
              padding: const EdgeInsets.fromLTRB(ByteSpace.page, 8, ByteSpace.page, 0),
              child: Text(
                'Opening a document hands a readable copy to the app that shows it. That copy is wiped when the private space closes.',
                style: tt.bodySmall?.copyWith(color: ByteColors.textFaint),
              ),
            ),
          if (it.kind == LibraryKind.link)
            Padding(
              padding: const EdgeInsets.fromLTRB(ByteSpace.page, 14, ByteSpace.page, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SelectableText(it.url, style: tt.bodyMedium),
                  const SizedBox(height: 10),
                  FilledButton.tonal(style: inlineButton, onPressed: _openWith, child: const Text('Open the link')),
                ],
              ),
            ),
          if (it.sticky.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(ByteSpace.page, 16, ByteSpace.page, 0),
              child: Text(it.sticky, style: tt.bodyMedium),
            ),
        ],
      ),
    );
  }

  Widget _media(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final it = _it;
    if (it.kind == LibraryKind.link) return const SizedBox(height: 8);
    if (_opening) {
      return Container(
        height: 260,
        color: ByteColors.surface2,
        alignment: Alignment.center,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4)),
            const SizedBox(height: 12),
            Text('Unlocking…', style: tt.bodySmall),
          ],
        ),
      );
    }
    final path = _path;
    if (path == null) {
      return Container(
        height: 220,
        color: ByteColors.surface2,
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'This could not be opened right now. If it lives in Google Drive, it needs the internet.',
              textAlign: TextAlign.center,
              style: tt.bodyMedium?.copyWith(color: ByteColors.textDim),
            ),
            const SizedBox(height: 10),
            TextButton(style: inlineButton, onPressed: _open, child: const Text('Try again')),
          ],
        ),
      );
    }
    switch (it.kind) {
      case LibraryKind.photo:
        return GestureDetector(
          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => _FullPhoto(path: path))),
          child: Container(
            color: Colors.black,
            constraints: const BoxConstraints(maxHeight: 460, minHeight: 220),
            child: Image.file(File(path), fit: BoxFit.contain, gaplessPlayback: true, errorBuilder: (_, _, _) => const SizedBox(height: 220)),
          ),
        );
      case LibraryKind.video:
        return _VideoBox(path: path);
      case LibraryKind.audio:
        return _AudioBox(path: path, durationMs: it.durationMs);
      case LibraryKind.doc:
      case LibraryKind.link:
      case LibraryKind.note:
        return Container(
          height: 160,
          color: ByteColors.surface2,
          alignment: Alignment.center,
          child: Icon(it.ext == 'pdf' ? Icons.picture_as_pdf_outlined : Icons.insert_drive_file_outlined, size: 44, color: ByteColors.textDim),
        );
    }
  }
}

class _FullPhoto extends StatelessWidget {
  const _FullPhoto({required this.path});
  final String path;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black, foregroundColor: Colors.white),
      body: InteractiveViewer(
        maxScale: 6,
        child: Center(child: Image.file(File(path), fit: BoxFit.contain, errorBuilder: (_, _, _) => const SizedBox.shrink())),
      ),
    );
  }
}

class _VideoBox extends StatefulWidget {
  const _VideoBox({required this.path});
  final String path;

  @override
  State<_VideoBox> createState() => _VideoBoxState();
}

class _VideoBoxState extends State<_VideoBox> {
  VideoPlayerController? _c;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    final c = VideoPlayerController.file(File(widget.path));
    try {
      await c.initialize();
      if (!mounted) {
        await c.dispose();
        return;
      }
      c.addListener(_tick);
      setState(() => _c = c);
    } catch (e) {
      debugPrint('[private] video: $e');
      await c.dispose();
      if (mounted) setState(() => _failed = true);
    }
  }

  void _tick() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _c?.removeListener(_tick);
    _c?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    if (_failed) {
      return Container(
        height: 220,
        color: Colors.black,
        alignment: Alignment.center,
        child: const Text('This video cannot be played here. Use "Open in another app" from the menu.', textAlign: TextAlign.center, style: TextStyle(color: Colors.white70)),
      );
    }
    if (c == null) {
      return Container(height: 220, color: Colors.black, alignment: Alignment.center, child: const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4)));
    }
    final playing = c.value.isPlaying;
    return Container(
      color: Colors.black,
      constraints: const BoxConstraints(maxHeight: 460),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: GestureDetector(
              onTap: () => playing ? c.pause() : c.play(),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  AspectRatio(aspectRatio: c.value.aspectRatio == 0 ? 16 / 9 : c.value.aspectRatio, child: VideoPlayer(c)),
                  if (!playing)
                    Container(
                      width: 56,
                      height: 56,
                      decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.45), shape: BoxShape.circle),
                      child: const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 34, semanticLabel: 'Play'),
                    ),
                ],
              ),
            ),
          ),
          VideoProgressIndicator(c, allowScrubbing: true, padding: const EdgeInsets.symmetric(vertical: 8)),
        ],
      ),
    );
  }
}

class _AudioBox extends StatefulWidget {
  const _AudioBox({required this.path, required this.durationMs});
  final String path;
  final int durationMs;

  @override
  State<_AudioBox> createState() => _AudioBoxState();
}

class _AudioBoxState extends State<_AudioBox> {
  final _player = AudioPlayer();
  final _subs = <StreamSubscription<dynamic>>[];
  bool _playing = false;
  bool _started = false;
  Duration _pos = Duration.zero;
  late Duration _total = Duration(milliseconds: widget.durationMs);

  @override
  void initState() {
    super.initState();
    _player.setAudioContext(AudioContext(
      android: const AudioContextAndroid(
        contentType: AndroidContentType.speech,
        usageType: AndroidUsageType.media,
        audioFocus: AndroidAudioFocus.none,
      ),
    ));
    _subs.add(_player.onPositionChanged.listen((d) {
      if (mounted) setState(() => _pos = d);
    }));
    _subs.add(_player.onDurationChanged.listen((d) {
      if (mounted && d > Duration.zero) setState(() => _total = d);
    }));
    _subs.add(_player.onPlayerComplete.listen((_) {
      if (!mounted) return;
      _started = false;
      setState(() {
        _playing = false;
        _pos = Duration.zero;
      });
    }));
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _player.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    try {
      if (_playing) {
        await _player.pause();
        if (mounted) setState(() => _playing = false);
        return;
      }
      if (_started && _pos > Duration.zero) {
        await _player.resume();
      } else {
        await _player.play(DeviceFileSource(widget.path), position: _pos > Duration.zero ? _pos : null);
        _started = true;
      }
      if (mounted) setState(() => _playing = true);
    } catch (e) {
      debugPrint('[private] audio: $e');
      if (mounted) setState(() => _playing = false);
    }
  }

  Future<void> _seek(Duration to) async {
    setState(() => _pos = to);
    if (!_started) return;
    try {
      await _player.seek(to);
    } catch (_) {}
  }

  static String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return d.inHours > 0 ? '${d.inHours}:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final totalMs = _total.inMilliseconds;
    return Padding(
      padding: const EdgeInsets.fromLTRB(ByteSpace.page, 28, ByteSpace.page, 8),
      child: Row(
        children: [
          Material(
            color: ByteColors.accentBright,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: _toggle,
              child: SizedBox(
                width: 56,
                height: 56,
                child: Icon(_playing ? Icons.pause_rounded : Icons.play_arrow_rounded, size: 28, color: ByteColors.onAccent, semanticLabel: _playing ? 'Pause' : 'Play'),
              ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 3,
                    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                    overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                    activeTrackColor: ByteColors.accent,
                    inactiveTrackColor: ByteColors.border,
                    thumbColor: ByteColors.accent,
                  ),
                  child: Slider(
                    padding: EdgeInsets.zero,
                    value: totalMs == 0 ? 0 : _pos.inMilliseconds.clamp(0, totalMs).toDouble(),
                    max: totalMs == 0 ? 1 : totalMs.toDouble(),
                    onChanged: totalMs == 0 ? null : (v) => _seek(Duration(milliseconds: v.round())),
                  ),
                ),
                const SizedBox(height: 4),
                Text('${_fmt(_pos)} / ${_fmt(_total)}', style: tt.bodySmall?.copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
