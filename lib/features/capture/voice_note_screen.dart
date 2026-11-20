import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

import '../../core/prefs.dart';
import '../../shared/motion.dart';
import '../../shared/theme.dart';
import '../chat/ai_client.dart';
import '../chat/ai_settings.dart';
import '../chat/ai_settings_screen.dart';
import '../notes/checklist.dart';
import '../notes/note.dart';
import '../notes/note_editor_screen.dart';
import '../notes/notes_repo.dart';
import '../voice/heard_fixes.dart';
import 'audio_item.dart';
import 'audio_repo.dart';

/// One voice note with its words: listen, read, fix a wrong word (BYTE
/// remembers the fix for next time), tidy the text, or turn it into a note
/// or a checklist. Saves by itself when you go back.
class VoiceNoteScreen extends StatefulWidget {
  const VoiceNoteScreen({super.key, required this.itemId});

  final String itemId;

  @override
  State<VoiceNoteScreen> createState() => _VoiceNoteScreenState();
}

class _VoiceNoteScreenState extends State<VoiceNoteScreen> {
  final _words = TextEditingController();
  final _player = AudioPlayer();
  final _subs = <StreamSubscription<dynamic>>[];

  AudioItem? _item;
  bool _loading = true;

  /// The words as BYTE last wrote them (heard, or tidied by AI). What you
  /// change from here on is what BYTE learns from.
  String _baseline = '';

  /// The words before "Tidy with AI", for Undo.
  String? _beforeTidy;
  bool _tidying = false;
  bool _saving = false;

  bool _playing = false;
  bool _started = false;
  Duration _pos = Duration.zero;
  Duration _total = Duration.zero;

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
    _load();
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    // Closed without the Back button (BYTE locked itself, or a bubble item
    // was tapped): the words as they are now are still kept.
    _save();
    _player.dispose();
    _words.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    AudioItem? item;
    try {
      item = await AudioRepo.instance.get(widget.itemId);
    } catch (e) {
      debugPrint('[voice note] load: $e');
    }
    if (!mounted) return;
    final text = item == null ? '' : (item.cleanText.trim().isNotEmpty ? item.cleanText.trim() : item.rawTranscript.trim());
    setState(() {
      _item = item;
      _loading = false;
      _baseline = text;
      _words.text = text;
      _total = item?.duration ?? Duration.zero;
    });
  }

  // ───────────── listening ─────────────

  Future<void> _togglePlay() async {
    final item = _item;
    if (item == null) return;
    try {
      if (_playing) {
        await _player.pause();
        if (mounted) setState(() => _playing = false);
        return;
      }
      if (_started && _pos > Duration.zero) {
        await _player.resume();
      } else {
        if (!await File(item.path).exists()) {
          _snack('The sound of this note is not on the phone right now.');
          return;
        }
        await _player.play(DeviceFileSource(item.path), position: _pos > Duration.zero ? _pos : null);
        _started = true;
      }
      if (mounted) setState(() => _playing = true);
    } catch (e) {
      _snack('Could not play: $e');
      if (mounted) setState(() => _playing = false);
    }
  }

  Future<void> _seek(Duration to) async {
    // The head moves at once; the player follows when it has a recording loaded.
    setState(() => _pos = to);
    if (!_started) return;
    try {
      await _player.seek(to);
    } catch (_) {}
  }

  // ───────────── saving ─────────────

  /// Keeps the words, and learns from what you changed by hand. Returns what
  /// was learned (heard → meant), for the little message.
  Future<Map<String, String>> _save() async {
    final item = _item;
    final now = _words.text.trim();
    if (item == null || _saving) return const {};
    final stored = item.cleanText.trim().isNotEmpty ? item.cleanText.trim() : item.rawTranscript.trim();
    if (now == stored) return const {};
    _saving = true;
    var learned = const <String, String>{};
    try {
      // Cleared on purpose: nothing comes back the next time the note is opened.
      await AudioRepo.instance.updateTranscript(item.id, raw: now.isEmpty ? '' : item.rawTranscript, clean: now);
      if (_baseline.isNotEmpty && now.isNotEmpty) learned = await HeardFixes.learn(_baseline, now);
      final fresh = await AudioRepo.instance.get(item.id);
      if (fresh != null) _item = fresh;
      _baseline = now;
    } catch (e) {
      debugPrint('[voice note] save: $e');
    } finally {
      _saving = false;
    }
    return learned;
  }

  static String _learnedLine(Map<String, String> learned) {
    final e = learned.entries.first;
    final more = learned.length > 1 ? ' (and ${learned.length - 1} more)' : '';
    return 'BYTE will remember: "${e.key}" means "${e.value}"$more';
  }

  // ───────────── tidy with AI ─────────────

  Future<void> _tidy() async {
    final text = _words.text.trim();
    if (text.isEmpty || _tidying) return;
    final settings = await AiSettings.load();
    if (!mounted) return;
    if (!settings.isConfigured) {
      final go = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('This needs an AI key'),
          content: const Text('Tidying is done by an AI service with your own key (Claude, ChatGPT or Gemini). Everything else in BYTE works without one.'),
          actions: [
            TextButton(style: inlineButton, onPressed: () => Navigator.pop(ctx, false), child: const Text('Not now')),
            FilledButton(style: inlineButton, onPressed: () => Navigator.pop(ctx, true), child: const Text('Add a key')),
          ],
        ),
      );
      if (go == true && mounted) {
        await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const AiSettingsScreen()));
      }
      return;
    }
    // The first time: say plainly that the words leave the phone for this.
    // (Asked once for each AI service: the words go to a different company.)
    final okKey = 'ai_tidy_ok_${settings.provider.name}';
    if (!Prefs.flag(okKey)) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Send these words to the AI?'),
          content: Text('To tidy them, the words of this note are sent to ${settings.provider.label} with your key. The sound stays on your phone. BYTE asks this only once for ${settings.provider.label}.'),
          actions: [
            TextButton(style: inlineButton, onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(style: inlineButton, onPressed: () => Navigator.pop(ctx, true), child: const Text('Send and tidy')),
          ],
        ),
      );
      if (ok != true) return;
      await Prefs.setFlag(okKey, true);
      if (!mounted) return;
    }
    setState(() => _tidying = true);
    try {
      final out = await AiClient(settings).chat(
        system: 'You tidy a spoken note that was turned into text. Fix punctuation, capital letters and obvious '
            'mis-heard words. Remove fillers like "um" and repeated words. Keep every fact, name, number and the '
            'speaker\'s own wording and language. Do not add anything, do not summarise, do not answer questions '
            'in the note. Reply with the tidied text only.',
        turns: [AiTurn('user', text)],
        maxTokens: 2000,
      );
      if (!mounted) return;
      // What was typed while the AI was working is not thrown away.
      if (_words.text.trim() != text) {
        _snack('You changed the words meanwhile, so nothing was replaced.');
        return;
      }
      setState(() {
        _beforeTidy = text;
        _words.text = out;
        _baseline = out; // the AI's rewrite is not a lesson about your words
      });
      Haptics.confirm();
    } catch (e) {
      if (mounted) _snack('Could not tidy: $e');
    } finally {
      if (mounted) setState(() => _tidying = false);
    }
  }

  void _undoTidy() {
    final before = _beforeTidy;
    if (before == null) return;
    setState(() {
      _words.text = before;
      _baseline = before;
      _beforeTidy = null;
    });
  }

  // ───────────── into a note / a checklist ─────────────

  Future<void> _makeChecklist() async {
    final tasks = tasksFromSpeech(_words.text);
    if (tasks.isEmpty) {
      _snack('There are no words to make a list from.');
      return;
    }
    await _save();
    final item = _item;
    final title = item == null || item.isUnnamed ? 'Checklist' : item.title;
    var body = '';
    for (final t in tasks) {
      body = addTask(body, t);
    }
    final note = await NotesRepo.instance.create(title: title, body: body);
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => NoteEditorScreen(note: note, madeNow: true)));
  }

  Future<void> _addToNote() async {
    final text = _words.text.trim();
    if (text.isEmpty) {
      _snack('There are no words to add.');
      return;
    }
    await _save();
    final notes = await NotesRepo.instance.list();
    if (!mounted) return;
    final choice = await showModalBottomSheet<Object>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.7),
          child: ListView(
            shrinkWrap: true,
            children: [
              ListTile(
                leading: Icon(Icons.add_rounded, color: ByteColors.accentDim),
                title: const Text('A new note'),
                onTap: () => Navigator.pop(ctx, 'new'),
              ),
              for (final n in notes.take(40))
                ListTile(
                  leading: Icon(Icons.sticky_note_2_outlined, color: ByteColors.textDim),
                  title: Text(n.displayTitle, maxLines: 1, overflow: TextOverflow.ellipsis),
                  onTap: () => Navigator.pop(ctx, n),
                ),
            ],
          ),
        ),
      ),
    );
    if (choice == null || !mounted) return;
    Note note;
    if (choice is Note) {
      // Read it again: it may have changed since the list was drawn.
      final fresh = await NotesRepo.instance.get(choice.id) ?? choice;
      final body = fresh.body.trimRight();
      note = fresh.copyWith(body: body.isEmpty ? text : '$body\n\n$text');
      await NotesRepo.instance.update(note);
    } else {
      final item = _item;
      note = await NotesRepo.instance.create(title: item == null || item.isUnnamed ? '' : item.title, body: text);
    }
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => NoteEditorScreen(note: note)));
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  static String _fmt(Duration d) => AudioItem.formatDuration(d);

  // ───────────── UI ─────────────

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final item = _item;
    final totalMs = _total.inMilliseconds;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final navigator = Navigator.of(context);
        final messenger = ScaffoldMessenger.of(context);
        final learned = await _save();
        if (learned.isNotEmpty) messenger.showSnackBar(SnackBar(content: Text(_learnedLine(learned))));
        if (mounted) navigator.pop();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(item == null ? 'Voice note' : (item.isUnnamed ? 'Voice note' : item.title), maxLines: 1, overflow: TextOverflow.ellipsis),
          actions: [
            if (_beforeTidy != null) TextButton(style: inlineButton, onPressed: _undoTidy, child: const Text('Undo tidy')),
          ],
        ),
        body: _loading
            ? const SizedBox.shrink()
            : item == null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text('This voice note is not here any more.', textAlign: TextAlign.center, style: tt.bodyLarge),
                    ),
                  )
                : Padding(
                    padding: const EdgeInsets.fromLTRB(ByteSpace.page, 8, ByteSpace.page, 0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // Listen while you read.
                        Row(
                          children: [
                            Material(
                              color: ByteColors.accentBright,
                              shape: const CircleBorder(),
                              child: InkWell(
                                customBorder: const CircleBorder(),
                                onTap: _togglePlay,
                                child: SizedBox(
                                  width: 48,
                                  height: 48,
                                  child: Icon(
                                    _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                                    size: 26,
                                    color: ByteColors.onAccent,
                                    semanticLabel: _playing ? 'Pause' : 'Play',
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 14),
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
                                  Text(
                                    '${_fmt(_pos)} / ${_fmt(_total)}',
                                    style: tt.bodySmall?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        Container(height: 1, color: ByteColors.border),
                        Expanded(
                          child: TextField(
                            controller: _words,
                            textCapitalization: TextCapitalization.sentences,
                            maxLines: null,
                            expands: true,
                            textAlignVertical: TextAlignVertical.top,
                            style: tt.bodyLarge?.copyWith(height: 1.5),
                            decoration: InputDecoration(
                              hintText: 'No words were heard for this one. You can type them here.',
                              hintMaxLines: 3,
                              filled: false,
                              border: InputBorder.none,
                              enabledBorder: InputBorder.none,
                              focusedBorder: InputBorder.none,
                              contentPadding: const EdgeInsets.symmetric(vertical: 14),
                              hintStyle: tt.bodyLarge?.copyWith(color: ByteColors.textFaint),
                            ),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Text(
                            'Fix a wrong word and BYTE remembers it for your next voice notes.',
                            style: tt.bodySmall?.copyWith(color: ByteColors.textFaint),
                          ),
                        ),
                      ],
                    ),
                  ),
        bottomNavigationBar: item == null
            ? null
            : Container(
                decoration: BoxDecoration(color: ByteColors.bg, border: Border(top: BorderSide(color: ByteColors.border))),
                child: SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextButton.icon(
                            onPressed: _tidying ? null : _tidy,
                            icon: _tidying
                                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                                : const Icon(Icons.auto_fix_high_rounded, size: 18),
                            label: Text(_tidying ? 'Tidying' : 'Tidy', maxLines: 1, overflow: TextOverflow.ellipsis),
                          ),
                        ),
                        Expanded(
                          child: TextButton.icon(
                            onPressed: _makeChecklist,
                            icon: const Icon(Icons.checklist_rounded, size: 18),
                            label: const Text('Checklist', maxLines: 1, overflow: TextOverflow.ellipsis),
                          ),
                        ),
                        Expanded(
                          child: TextButton.icon(
                            onPressed: _addToNote,
                            icon: const Icon(Icons.note_add_outlined, size: 18),
                            label: const Text('To a note', maxLines: 1, overflow: TextOverflow.ellipsis),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
      ),
    );
  }
}
