import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/stars.dart';
import '../../shared/selection.dart';
import '../../shared/sticky.dart';
import '../../shared/theme.dart';
import '../../shared/ui.dart';
import '../../shared/wave.dart';
import '../library/collection_picker.dart';
import '../library/collections_repo.dart';
import '../library/library_item.dart';
import 'audio_item.dart';
import 'audio_repo.dart';
import 'recorder_service.dart';
import 'voice_note_screen.dart';

/// Recordings — everything you recorded, as a list by day. The mic lives in
/// a bar at the bottom; while recording the bar shows the state in words,
/// the timer and the wave.
class CaptureScreen extends StatefulWidget {
  const CaptureScreen({super.key});

  @override
  State<CaptureScreen> createState() => _CaptureScreenState();
}

class _CaptureScreenState extends State<CaptureScreen> {
  final _recorder = RecorderService.instance;
  final _player = AudioPlayer();
  final _search = TextEditingController();

  List<AudioItem> _items = const [];
  final _sel = Selection();
  bool _loading = true;
  bool _unnamedOnly = false;
  String? _playlist; // collection id; null = all
  List<Collection> _playlists = const [];
  Map<String, List<String>> _itemLists = const {}; // item id → collection names (for the caption)
  double _rate = 1.0;
  static const _rates = [1.0, 1.5, 2.0, 3.0, 0.5];

  String? _playingId; // loaded in the player (playing or paused)
  bool _paused = false;
  Duration _playPos = Duration.zero;
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<void>? _doneSub;
  StreamSubscription<String>? _logSub;

  @override
  void initState() {
    super.initState();
    _recorder.addListener(_onRecorder);
    _search.addListener(_reload);
    _sel.addListener(() {
      if (mounted) setState(() {});
    });
    AudioRepo.instance.revision.addListener(_reload);
    CollectionsRepo.instance.revision.addListener(_reload);
    _posSub = _player.onPositionChanged.listen((d) {
      if (mounted) setState(() => _playPos = d);
    });
    _doneSub = _player.onPlayerComplete.listen((_) {
      if (mounted) {
        setState(() {
          _playingId = null;
          _paused = false;
          _playPos = Duration.zero;
        });
      }
    });
    _logSub = _player.onLog.listen((msg) {
      debugPrint('[player] $msg');
      if (mounted && msg.toLowerCase().contains('error')) _snack('Player: $msg');
    });
    _player.onPlayerStateChanged.listen((s) => debugPrint('[player] state $s'));
    // Don't make playback depend on audio focus — after a capture the system
    // can refuse it and the player then silently never starts.
    _player.setAudioContext(
      AudioContext(
        android: const AudioContextAndroid(
          contentType: AndroidContentType.speech,
          usageType: AndroidUsageType.media,
          audioFocus: AndroidAudioFocus.none,
        ),
      ),
    );
    _reload();
  }

  @override
  void dispose() {
    _sel.dispose();
    _recorder.removeListener(_onRecorder);
    AudioRepo.instance.revision.removeListener(_reload);
    CollectionsRepo.instance.revision.removeListener(_reload);
    _search.dispose();
    _posSub?.cancel();
    _doneSub?.cancel();
    _logSub?.cancel();
    _player.dispose();
    super.dispose();
  }

  void _onRecorder() {
    if (mounted) setState(() {});
  }

  Future<void> _reload() async {
    var items = await AudioRepo.instance.list(query: _search.text);
    if (_unnamedOnly) items = items.where((i) => i.isUnnamed).toList();
    final repo = CollectionsRepo.instance;
    await repo.migrateAudioTags(); // old tag-playlists → real collections (no-op after the first run)
    final pls = await repo.list(kind: LibraryKind.audio);
    var inList = <String>{};
    if (_playlist != null) {
      inList = (await repo.itemIds(_playlist!)).toSet();
      items = items.where((i) => inList.contains(i.id)).toList();
    }
    // Which lists each visible recording is in (for the caption).
    final names = <String, List<String>>{};
    for (final c in pls) {
      if (c.count == 0) continue;
      for (final id in await repo.itemIds(c.id)) {
        (names[id] ??= []).add(c.name);
      }
    }
    if (!mounted) return;
    setState(() {
      _items = items;
      _playlists = pls;
      _itemLists = names;
      if (_playlist != null && !pls.any((p) => p.id == _playlist)) _playlist = null;
      _loading = false;
    });
  }

  Future<void> _cycleRate() async {
    final i = _rates.indexOf(_rate);
    final next = _rates[(i + 1) % _rates.length];
    setState(() => _rate = next);
    try {
      await _player.setPlaybackRate(next);
    } catch (e) {
      _snack('Speed: $e');
    }
  }

  /// Add this recording to a playlist (a collection — shared with photos,
  /// videos and notes in the Library), or make a new one.
  Future<void> _addToPlaylist(AudioItem item) async {
    final changed = await CollectionPicker.show(context, itemIds: [item.id], title: 'Add to a folder');
    if (!mounted) return;
    if (changed != null && changed.isNotEmpty) _snack(changed.join(', '));
    await _reload();
  }

  /// Keep recording at the end of an older note.
  Future<void> _continue(AudioItem item) async {
    if (_recorder.isRecording) {
      _snack('Stop the current recording first.');
      return;
    }
    await _player.stop();
    setState(() {
      _playingId = null;
      _paused = false;
    });
    final ok = await _recorder.start(continueItem: item);
    if (!ok && mounted) _snack(_recorder.error ?? 'Could not continue.');
  }

  /// Slider / ±10 s. Starts playback at [pos] if this item isn't playing.
  Future<void> _seek(AudioItem item, Duration pos) async {
    final clamped = pos < Duration.zero
        ? Duration.zero
        : (pos > item.duration ? item.duration : pos);
    if (_playingId != item.id) {
      await _player.stop();
      setState(() {
        _playingId = item.id;
        _paused = false;
        _playPos = clamped;
      });
      try {
        await _player.play(DeviceFileSource(item.path), position: clamped);
        if (_rate != 1.0) await _player.setPlaybackRate(_rate);
      } catch (e) {
        _snack('Play failed: $e');
        setState(() => _playingId = null);
      }
      return;
    }
    // Same item (playing or paused): just move the head; a paused item stays paused.
    setState(() => _playPos = clamped);
    await _player.seek(clamped);
  }

  Future<void> _share(AudioItem item) async {
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(item.path, mimeType: item.path.toLowerCase().endsWith('.m4a') ? 'audio/mp4' : 'audio/wav')],
        text: item.note.isNotEmpty ? '${item.title}\n${item.note}' : item.title,
      ),
    );
  }

  Future<void> _sticky(AudioItem item) async {
    final v = await editStickyNote(context, item.note);
    if (v == null) return;
    await AudioRepo.instance.setNote(item.id, v);
  }

  Future<void> _pin(AudioItem item) async {
    final now = await Stars.isStarred(item.id);
    await Stars.set(item.id, !now);
    if (!mounted) return;
    _snack(now ? 'Star removed' : 'Starred');
  }

  Future<void> _pinSelected() async {
    final ids = _sel.ids.toList();
    final pinned = await Stars.toggleMany(ids);
    _sel.clear();
    if (!mounted) return;
    _snack(pinned ? 'Starred' : 'Star removed');
  }

  Future<void> _stickySelected() async {
    final ids = _sel.ids.toList();
    final current = ids.length == 1
        ? _items.where((i) => i.id == ids.first).map((i) => i.note).firstOrNull ?? ''
        : '';
    final v = await editStickyNote(context, current);
    if (v == null) return;
    for (final id in ids) {
      await AudioRepo.instance.setNote(id, v);
    }
    _sel.clear();
    if (mounted) _snack(v.trim().isEmpty ? 'Sticky removed' : 'Sticky added');
  }

  Future<void> _toggleRecord() async {
    if (_recorder.isRecording) {
      final saved = await _recorder.stop();
      if (saved == null && _recorder.error != null && mounted) {
        _snack(_recorder.error!);
      }
      await _reload();
    } else {
      await _player.stop();
      setState(() => _playingId = null);
      final ok = await _recorder.start();
      if (!ok && mounted) _snack(_recorder.error ?? 'Could not record.');
    }
  }

  /// The words of a voice note: read, fix, tidy, make a checklist.
  Future<void> _words(AudioItem item) async {
    if (_playingId != null) {
      await _player.stop();
      if (!mounted) return;
      setState(() => _playingId = null);
    }
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => VoiceNoteScreen(itemId: item.id)));
  }

  Future<void> _togglePlay(AudioItem item) async {
    if (_playingId == item.id) {
      // Pause keeps the head where it is; play again continues from there.
      if (_paused) {
        setState(() => _paused = false);
        try {
          await _player.resume();
        } catch (e) {
          _snack('Play failed: $e');
        }
      } else {
        await _player.pause();
        setState(() => _paused = true);
      }
      return;
    }
    await _player.stop();
    setState(() {
      _playingId = item.id;
      _paused = false;
      _playPos = Duration.zero;
    });
    try {
      final f = File(item.path);
      final exists = await f.exists();
      final size = exists ? await f.length() : -1;
      debugPrint('[player] playing ${item.path} exists=$exists size=$size');
      if (!exists || size < 1024) {
        _snack('File problem: exists=$exists size=$size bytes');
        setState(() => _playingId = null);
        return;
      }
      await _player.play(DeviceFileSource(item.path));
      if (_rate != 1.0) await _player.setPlaybackRate(_rate);
    } catch (e) {
      _snack('Play failed: $e');
      setState(() => _playingId = null);
    }
  }

  Future<void> _deleteSelected() async {
    final n = _sel.count;
    final ok = await confirmBulk(
      context,
      title: 'Move $n voice note${n == 1 ? '' : 's'} to the bin?',
      body: '${n == 1 ? 'It stays' : 'They stay'} in the bin for 30 days. Bring ${n == 1 ? 'it' : 'them'} back from Folders, then Bin.',
      action: 'Move to bin',
    );
    if (!ok) return;
    for (final id in _sel.ids.toList()) {
      if (_playingId == id) {
        await _player.stop();
        _playingId = null;
      }
      await AudioRepo.instance.delete(id);
    }
    _sel.clear();
    _reload();
  }

  Future<void> _delete(AudioItem item) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Move this voice note to the bin?'),
        content: const Text('It stays in the bin for 30 days. Bring it back from Folders, then Bin.'),
        actions: [
          TextButton(style: inlineButton, onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
            style: inlineButton,
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Move to bin', style: TextStyle(color: ByteColors.danger)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    if (_playingId == item.id) {
      await _player.stop();
      _playingId = null;
    }
    await AudioRepo.instance.delete(item.id);
    await _reload();
  }

  Future<void> _rename(AudioItem item) async {
    final ctl = TextEditingController(text: item.title);
    final title = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Name this voice note'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(hintText: 'e.g. Movie idea — bike chase'),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(style: inlineButton, onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(style: inlineButton, onPressed: () => Navigator.pop(ctx, ctl.text), child: const Text('Save')),
        ],
      ),
    );
    // Dispose after the dialog's close animation; disposing immediately
    // trips a framework assertion while the TextField is still mounted.
    Future<void>.delayed(const Duration(seconds: 1), ctl.dispose);
    if (title == null || title.trim().isEmpty) return;
    await AudioRepo.instance.rename(item.id, title);
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // ───────────── UI ─────────────

  @override
  Widget build(BuildContext context) {
    final rec = _recorder.isRecording;
    final selecting = _sel.active;
    final searching = _search.text.trim().isNotEmpty || _unnamedOnly || _playlist != null;
    final unnamed = _items.where((i) => i.isUnnamed).length;
    final showLists = _playlists.any((c) => c.count > 0);

    final body = <Widget>[
      QuietSearch(controller: _search, hint: 'Search voice notes'),
      const SizedBox(height: 6),
      ChipRow(
        children: [
          if (showLists)
            Pill('All', selected: _playlist == null, onTap: () {
              setState(() => _playlist = null);
              _reload();
            }),
          Pill('Unnamed', count: unnamed, selected: _unnamedOnly, onTap: () {
            setState(() => _unnamedOnly = !_unnamedOnly);
            _reload();
          }),
          if (showLists)
            for (final c in _playlists.where((c) => c.count > 0 || c.id == _playlist))
              Pill(c.name, count: c.count, selected: _playlist == c.id, onTap: () {
                setState(() => _playlist = c.id);
                _reload();
              }),
        ],
      ),
    ];

    if (_loading) {
      body.add(const Padding(padding: EdgeInsets.only(top: 48), child: Center(child: CircularProgressIndicator())));
    } else if (_items.isEmpty) {
      body.add(EmptyNote(searching ? 'Nothing matches that. Try another word.' : 'No voice notes yet. Tap the mic and just talk.'));
    } else {
      String? day;
      for (final item in _items) {
        final label = _dayLabel(item.createdAt);
        if (label != day) {
          body.add(SectionLabel(
            label,
            top: day == null ? 20 : 28,
            trailing: day == null ? Meta('${_items.length} voice note${_items.length == 1 ? '' : 's'}') : null,
          ));
          body.add(Container(height: 1, color: ByteColors.border));
          day = label;
        }
        final loaded = _playingId == item.id;
        body.add(_RecordingRow(
          item: item,
          loaded: loaded,
          playing: loaded && !_paused,
          position: loaded ? _playPos : Duration.zero,
          rate: _rate,
          lists: _itemLists[item.id],
          selected: _sel.contains(item.id),
          selecting: selecting,
          onTap: selecting ? () => _sel.toggle(item.id) : () => _togglePlay(item),
          onLongPress: () => _sel.toggle(item.id),
          onPlay: () => _togglePlay(item),
          onSeek: (d) => _seek(item, d),
          onRate: _cycleRate,
          onDelete: () => _delete(item),
          onRename: () => _rename(item),
          onShare: () => _share(item),
          onSticky: () => _sticky(item),
          onPin: () => _pin(item),
          onContinue: () => _continue(item),
          onPlaylist: () => _addToPlaylist(item),
          onWords: () => _words(item),
        ));
      }
    }

    return SelectionBack(
      sel: _sel,
      child: Scaffold(
        appBar: selecting
            ? selectionAppBar(
                sel: _sel,
                allIds: [for (final i in _items) i.id],
                actions: [
                  IconButton(
                    tooltip: 'Sticky note',
                    icon: const Icon(Icons.sticky_note_2_outlined),
                    onPressed: _stickySelected,
                  ),
                  IconButton(
                    tooltip: 'Star',
                    icon: Icon(Icons.star_outline_rounded, color: ByteColors.accentDim),
                    onPressed: _pinSelected,
                  ),
                  IconButton(
                    tooltip: 'Delete',
                    icon: Icon(Icons.delete_outline, color: ByteColors.danger),
                    onPressed: _deleteSelected,
                  ),
                ],
              )
            : AppBar(title: const Text('Voice notes')),
        body: Column(
          children: [
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.only(bottom: 24),
                itemCount: body.length,
                itemBuilder: (_, i) => body[i],
              ),
            ),
            _RecordPanel(
              recording: rec,
              elapsed: _recorder.appendBase + _recorder.elapsed,
              level: _recorder.level,
              onTap: _toggleRecord,
              appendingTo: _recorder.appendingTo == null ? null : (_items.where((i) => i.id == _recorder.appendingTo).map((i) => i.title).firstOrNull ?? 'recording'),
            ),
          ],
        ),
      ),
    );
  }

  static String _dayLabel(DateTime t) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final d = DateTime(t.year, t.month, t.day);
    final diff = today.difference(d).inDays;
    if (diff == 0) return 'Today';
    if (diff == 1) return 'Yesterday';
    const wd = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const mo = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    if (diff < 7) return '${wd[d.weekday - 1]} ${d.day} ${mo[d.month - 1]}';
    return '${d.day} ${mo[d.month - 1]}${d.year == now.year ? '' : ' ${d.year}'}';
  }
}

/// The bar at the bottom: the mic when idle; while recording, the state in
/// words, the timer, the wave and the stop button.
class _RecordPanel extends StatelessWidget {
  const _RecordPanel({
    required this.recording,
    required this.elapsed,
    required this.level,
    required this.onTap,
    this.appendingTo,
  });

  final bool recording;
  final Duration elapsed;
  final double level;
  final VoidCallback onTap;

  /// Title of the older note being continued, if any.
  final String? appendingTo;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Container(
      decoration: BoxDecoration(color: ByteColors.bg, border: Border(top: BorderSide(color: ByteColors.border))),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(ByteSpace.page, 12, ByteSpace.page, 12),
          child: recording
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Recording', style: tt.labelMedium?.copyWith(color: ByteColors.heyInk)),
                    if (appendingTo != null) Text('Adding to "$appendingTo"', style: tt.bodySmall),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                AudioItem.formatDuration(elapsed),
                                style: tt.headlineMedium?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
                              ),
                              const SizedBox(height: 8),
                              ListeningWave(level: level, bars: 20, height: 32),
                            ],
                          ),
                        ),
                        const SizedBox(width: 16),
                        _Round(icon: Icons.stop_rounded, label: 'Stop recording', size: 64, onTap: onTap),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text('Tap stop when you\'re done. It\'s saved on this phone.', style: tt.bodySmall),
                  ],
                )
              : Row(
                  children: [
                    Expanded(child: Text('Tap the mic to record an idea.', style: tt.bodySmall)),
                    const SizedBox(width: 12),
                    _Round(icon: Icons.mic_rounded, label: 'Record', onTap: onTap),
                  ],
                ),
        ),
      ),
    );
  }
}

/// The bright-green round button: mic to start, stop to finish.
class _Round extends StatelessWidget {
  const _Round({required this.icon, required this.label, required this.onTap, this.size = 56});
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: ByteColors.accentBright,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(width: size, height: size, child: Icon(icon, color: ByteColors.onAccent, size: size * 0.46, semanticLabel: label)),
      ),
    );
  }
}

/// One recording: a small play control, the title, "duration, time, in
/// playlist" underneath, the menu on the right. The sticky note sits under
/// the row; the scrubber and ±10 s appear while this one is in the player.
class _RecordingRow extends StatelessWidget {
  const _RecordingRow({
    required this.item,
    required this.loaded,
    required this.playing,
    required this.position,
    required this.rate,
    required this.selected,
    required this.selecting,
    required this.onTap,
    required this.onLongPress,
    required this.onPlay,
    required this.onSeek,
    required this.onRate,
    required this.onDelete,
    required this.onRename,
    required this.onShare,
    required this.onSticky,
    required this.onPin,
    required this.onContinue,
    required this.onPlaylist,
    required this.onWords,
    this.lists,
  });

  final AudioItem item;

  /// In the player (playing or paused).
  final bool loaded;
  final bool playing;
  final Duration position;
  final double rate;

  /// Names of the playlists this recording is in.
  final List<String>? lists;
  final bool selected;
  final bool selecting;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onPlay;
  final ValueChanged<Duration> onSeek;
  final VoidCallback onRate;
  final VoidCallback onDelete;
  final VoidCallback onRename;
  final VoidCallback onShare;
  final VoidCallback onSticky;
  final VoidCallback onPin;
  final VoidCallback onContinue;
  final VoidCallback onPlaylist;
  final VoidCallback onWords;

  /// Where the title starts: the play control plus its gap.
  static const double _indent = ByteSpace.page + 36 + 14;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final total = item.duration;
    final totalMs = total.inMilliseconds;
    final posMs = position.inMilliseconds.clamp(0, totalMs == 0 ? 1 : totalMs);
    final inLists = (lists ?? const <String>[]).take(2).join(', ');
    final caption = [
      AudioItem.formatDuration(total),
      TimeOfDay.fromDateTime(item.createdAt).format(context),
      if (inLists.isNotEmpty) 'in $inLists',
    ].join(', ');
    final rateLabel = '${rate == rate.roundToDouble() ? rate.toInt() : rate}×';

    final play = Material(
      color: loaded ? ByteColors.accent : ByteColors.accentSoft,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: selecting ? null : onPlay,
        child: SizedBox(
          width: 36,
          height: 36,
          child: Icon(
            playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
            size: 22,
            color: loaded ? ByteColors.onAccent : ByteColors.accentDim,
            semanticLabel: playing ? 'Pause' : 'Play',
          ),
        ),
      ),
    );

    final menu = PopupMenuButton<String>(
      tooltip: 'More',
      icon: Icon(Icons.more_vert_rounded, color: ByteColors.textFaint),
      onSelected: (v) {
        switch (v) {
          case 'rename':
            onRename();
          case 'sticky':
            onSticky();
          case 'pin':
            onPin();
          case 'share':
            onShare();
          case 'continue':
            onContinue();
          case 'playlist':
            onPlaylist();
          case 'words':
            onWords();
          case 'delete':
            onDelete();
        }
      },
      itemBuilder: (_) => [
        const PopupMenuItem(value: 'words', child: Text('Read and fix the words')),
        const PopupMenuItem(value: 'continue', child: Text('Continue recording at the end')),
        const PopupMenuItem(value: 'playlist', child: Text('Add to a folder')),
        const PopupMenuItem(value: 'rename', child: Text('Rename')),
        const PopupMenuItem(value: 'sticky', child: Text('Sticky note')),
        const PopupMenuItem(value: 'pin', child: Text('Star or remove star')),
        const PopupMenuItem(value: 'share', child: Text('Share')),
        PopupMenuItem(value: 'delete', child: Text('Move to bin', style: TextStyle(color: ByteColors.danger))),
      ],
    );

    return Container(
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: ByteColors.border))),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ByteRow(
            hairline: false,
            selected: selected,
            leading: play,
            title: item.displayText,
            subtitle: caption,
            titleWeight: item.isUnnamed ? FontWeight.w600 : FontWeight.w700,
            trailing: selected
                ? const SelectedBadge()
                : IgnorePointer(
                    ignoring: selecting,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (item.isUnnamed) TextButton(style: inlineButton, onPressed: onRename, child: const Text('Name it')),
                        menu,
                      ],
                    ),
                  ),
            onTap: onTap,
            onLongPress: onLongPress,
          ),
          if (item.note.trim().isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(_indent, 0, ByteSpace.page, 12),
              child: StickyNote(text: item.note, compact: true, onTap: selecting ? onTap : onSticky),
            ),
          if (loaded && !selecting)
            Padding(
              padding: const EdgeInsets.fromLTRB(_indent, 0, ByteSpace.page - 8, 4),
              child: Column(
                children: [
                  // Scrubber: drag anywhere in the recording.
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
                      value: posMs.toDouble(),
                      max: (totalMs == 0 ? 1 : totalMs).toDouble(),
                      onChanged: (v) => onSeek(Duration(milliseconds: v.round())),
                    ),
                  ),
                  Row(
                    children: [
                      Text(
                        '${AudioItem.formatDuration(Duration(milliseconds: posMs))} / ${AudioItem.formatDuration(total)}',
                        style: tt.bodySmall?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
                      ),
                      const Spacer(),
                      TextButton(style: inlineButton, onPressed: onRate, child: Text(rateLabel)),
                      IconButton(
                        tooltip: 'Back 10 seconds',
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.replay_10_rounded),
                        onPressed: () => onSeek(position - const Duration(seconds: 10)),
                      ),
                      IconButton(
                        tooltip: 'Forward 10 seconds',
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.forward_10_rounded),
                        onPressed: () => onSeek(position + const Duration(seconds: 10)),
                      ),
                      IconButton(
                        tooltip: 'Send',
                        visualDensity: VisualDensity.compact,
                        icon: Icon(Icons.share_outlined, color: ByteColors.textDim),
                        onPressed: onShare,
                      ),
                    ],
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
