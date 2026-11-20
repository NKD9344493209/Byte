import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/stars.dart';
import '../../shared/motion.dart';
import '../../shared/theme.dart';
import '../../shared/ui.dart';
import '../capture/audio_repo.dart';
import '../library/collections_repo.dart';
import '../library/indexer.dart';
import '../library/library_item.dart';
import '../library/library_repo.dart';
import '../library/library_screen.dart' show LibraryThumb, agoShort;
import '../library/library_viewer.dart';
import '../library/media_pager.dart';
import '../../core/prefs.dart';
import '../capture/recorder_service.dart';
import '../voice/voice_bridge.dart';
import '../voice/voice_command.dart';
import '../notes/note_editor_screen.dart';
import '../notes/notes_repo.dart';
import 'search_text.dart';
import 'words.dart';

/// The second tab: one box that looks inside everything — the words in a
/// photo, a page of a PDF, a slide, a note, a voice note's name. Type one
/// word; the place it was found is shown with the word marked.
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  /// Bumped by the shell when the Search tab is tapped while already open:
  /// the box takes the keyboard.
  static final ValueNotifier<int> focusRequest = ValueNotifier<int>(0);

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  static const _kRecent = 'recent_searches';
  static const _maxRecent = 8;
  static const _tries = ['aadhar', 'marks', 'bill', 'screenshot', 'pdf'];

  final _repo = LibraryRepo.instance;
  final _ctl = TextEditingController();
  final _focus = FocusNode();
  Timer? _debounce;
  Timer? _refreshLater;
  bool _counted = false;
  String _lastText = ''; // what the box said the last time it changed
  LibraryKind? _kind;
  String _when = 'any'; // any | week | month | year
  Collection? _folder; // only inside this folder
  String _respelled = ''; // the closest spelling BYTE knows, when it also searched for that
  List<LibraryItem> _results = const [];
  List<String> _recent = const [];
  String _ranFor = ''; // the query the results on screen belong to
  int _total = 0;
  int _seq = 0;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _ctl.addListener(_onText);
    _repo.revision.addListener(_refresh);
    NotesRepo.instance.revision.addListener(_refresh);
    AudioRepo.instance.revision.addListener(_refresh);
    Stars.changed.addListener(_refresh);
    SearchScreen.focusRequest.addListener(_takeFocus);
    _loadRecent();
    _refresh();
  }

  @override
  void dispose() {
    if (_listening) VoiceBridge.cancelListen(); // the microphone does not stay on
    _debounce?.cancel();
    _refreshLater?.cancel();
    _repo.revision.removeListener(_refresh);
    NotesRepo.instance.revision.removeListener(_refresh);
    AudioRepo.instance.revision.removeListener(_refresh);
    Stars.changed.removeListener(_refresh);
    SearchScreen.focusRequest.removeListener(_takeFocus);
    _ctl.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _takeFocus() {
    if (mounted) _focus.requestFocus();
  }

  Future<void> _loadRecent() async {
    final p = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() => _recent = p.getStringList(_kRecent) ?? const []);
  }

  /// Remember a search that led somewhere (newest first, no repeats).
  Future<void> _remember(String q) async {
    final t = q.trim();
    if (t.isEmpty) return;
    final next = [t, ..._recent.where((r) => r.toLowerCase() != t.toLowerCase())].take(_maxRecent).toList();
    final p = await SharedPreferences.getInstance();
    await p.setStringList(_kRecent, next);
    if (mounted) setState(() => _recent = next);
  }

  Future<void> _forget(String q) async {
    final next = _recent.where((r) => r != q).toList();
    final p = await SharedPreferences.getInstance();
    await p.setStringList(_kRecent, next);
    if (mounted) setState(() => _recent = next);
  }

  /// Typing: wait a moment so every keystroke is not a query on its own.
  void _onText() {
    // The controller also speaks up when only the cursor moves: same words, nothing to do.
    final t = _ctl.text.trim();
    if (t == _lastText) return;
    _lastText = t;
    _debounce?.cancel();
    if (t.isEmpty) {
      _run();
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 220), _run);
  }

  /// Something changed in the vault: keep the count and the results fresh.
  /// Something in the Library changed. While BYTE reads a big gallery that
  /// happens every few seconds for hours — so the search on screen is redone
  /// at most once in two seconds, not each time.
  void _refresh() {
    if (!_counted) {
      _counted = true;
      _recount();
      return;
    }
    // At most once in two seconds — and never put off again and again while
    // changes keep coming (a whole gallery being read).
    if (_refreshLater?.isActive ?? false) return;
    _refreshLater = Timer(const Duration(seconds: 2), () {
      if (!mounted) return;
      _recount();
      if (_ctl.text.trim().isNotEmpty) _run();
    });
  }

  void _recount() {
    _repo.total().then((n) {
      if (mounted) setState(() => _total = n);
    });
  }

  Future<void> _run() async {
    final q = _ctl.text.trim();
    final seq = ++_seq;
    if (q.isEmpty) {
      if (mounted) {
        setState(() {
          _results = const [];
          _ranFor = '';
          _respelled = '';
          _busy = false;
        });
      }
      return;
    }
    if (mounted) setState(() => _busy = true);
    final List<LibraryItem> items;
    var respelled = '';
    try {
      final since = sinceFor(_when);
      final found = await _repo.list(kind: _kind, query: q, limit: 200, since: since, folderId: _folder?.id);
      // Few or no hits: maybe a spelling slip. Look for the closest word BYTE
      // has read anywhere, and add what that finds below the exact hits.
      if (found.length < 3) {
        final alt = await Words.respell(q);
        if (alt.isNotEmpty) {
          final have = {for (final it in found) it.id};
          final more = await _repo.list(kind: _kind, query: alt, limit: 200, since: since, folderId: _folder?.id);
          final extra = [
            for (final it in more)
              if (!have.contains(it.id)) it,
          ];
          if (extra.isNotEmpty) {
            respelled = alt;
            items = [...found, ...extra];
          } else {
            items = found;
          }
        } else {
          items = found;
        }
      } else {
        items = found;
      }
    } catch (e) {
      // The vault was busy (a restore, say): stop the spinner, the next keystroke tries again.
      debugPrint('[search] $e');
      if (mounted && seq == _seq) setState(() => _busy = false);
      return;
    }
    if (!mounted || seq != _seq) return;
    setState(() {
      _results = items;
      _ranFor = q;
      _respelled = respelled;
      _busy = false;
    });
  }

  void _setKind(LibraryKind? k) {
    setState(() => _kind = k);
    _run();
  }

  void _setWhen(String w) {
    setState(() => _when = w);
    _run();
  }

  /// "Any folder" or one of yours.
  Future<void> _pickFolder() async {
    final all = await CollectionsRepo.instance.list();
    if (!mounted) return;
    final folders = all.where((c) => c.count > 0).toList();
    final picked = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              leading: const Icon(Icons.all_inclusive_rounded),
              title: const Text('Any folder'),
              onTap: () => Navigator.pop(ctx, ''),
            ),
            for (final c in folders)
              ListTile(
                leading: const Icon(Icons.folder_outlined),
                title: Text(c.name),
                subtitle: Text('${c.count} item${c.count == 1 ? '' : 's'}'),
                onTap: () => Navigator.pop(ctx, c.id),
              ),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    Collection? chosen;
    for (final c in folders) {
      if (c.id == picked) chosen = c;
    }
    setState(() => _folder = chosen);
    _run();
  }

  bool _listening = false;

  /// The mic in the search box: "find my Aadhaar" searches, "note buy milk"
  /// saves a note, plain words are searched as they are.
  Future<void> _voice() async {
    if (_listening) {
      await VoiceBridge.cancelListen();
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    if (!VoiceBridge.supported) {
      messenger.showSnackBar(const SnackBar(content: Text('Voice works on the phone.')));
      return;
    }
    setState(() => _listening = true); // at once, so a second tap cancels instead of starting again
    // Android asks "Allow BYTE to record audio?" here the first time.
    final allowed = await RecorderService.instance.hasPermission();
    if (!mounted) return;
    if (!allowed) {
      setState(() => _listening = false);
      messenger.showSnackBar(const SnackBar(content: Text('Allow the microphone so BYTE can hear what to find.')));
      return;
    }
    _focus.unfocus();
    final h = await VoiceBridge.listen(offline: false, locale: Prefs.voiceLocale, pauseMs: 1500, minMs: 2500);
    if (!mounted) return;
    setState(() => _listening = false);
    if (!h.ok) {
      final err = h.error ?? '';
      if (err == 'cancelled') return;
      messenger.showSnackBar(SnackBar(
        content: Text(err == 'network' || err == 'unavailable' ? 'The phone could not listen now (it needs the internet, or Google\'s offline speech pack).' : 'Did not catch that. Tap the mic and say it again.'),
      ));
      return;
    }
    final cmd = parseVoice(h.text);
    switch (cmd.kind) {
      case VoiceKind.find:
        _use(cmd.text);
      case VoiceKind.note:
        final note = await NotesRepo.instance.create(body: cmd.text);
        messenger.showSnackBar(SnackBar(
          content: Text('Saved a note: "${cmd.text}"'),
          duration: const Duration(seconds: 6),
          persist: false,
          action: SnackBarAction(label: 'Undo', onPressed: () => NotesRepo.instance.delete(note.id)),
        ));
      case VoiceKind.none:
        break;
    }
  }

  void _use(String q) {
    _ctl.text = q;
    _ctl.selection = TextSelection.collapsed(offset: q.length);
  }

  Future<void> _open(LibraryItem it) async {
    final q = _ctl.text.trim();
    _focus.unfocus();
    unawaited(_remember(q));
    if (it.kind == LibraryKind.note) {
      final note = await NotesRepo.instance.get(it.id);
      if (note == null || !mounted) return;
      await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => NoteEditorScreen(note: note)));
      return;
    }
    // Found only by the closest spelling: the viewer marks that word.
    final find = _respelled.isNotEmpty && hitIn(it, q) == null ? _respelled : q;
    if (MediaPager.isMedia(it)) {
      // Full screen; swipe through the pictures that were found.
      await MediaPager.open(context, it, around: _results, find: find);
      return;
    }
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => LibraryViewer(itemId: it.id, find: find)));
  }

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final typing = _ctl.text.trim().isNotEmpty;
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: CustomScrollView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          slivers: [
            const SliverToBoxAdapter(child: PageTitle('Search')),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(ByteSpace.page, 8, ByteSpace.page, 0),
                child: ListenableBuilder(
                  listenable: _ctl,
                  builder: (_, _) => TextField(
                    controller: _ctl,
                    focusNode: _focus,
                    textInputAction: TextInputAction.search,
                    onSubmitted: (v) {
                      if (_results.isNotEmpty) _remember(v);
                    },
                    decoration: InputDecoration(
                      hintText: _listening ? 'Listening… say "find my Aadhaar"' : 'A word inside a photo, PDF or note',
                      prefixIcon: Icon(Icons.search_rounded, color: ByteColors.textFaint),
                      // Empty box: the mic ("find my Aadhaar", "note buy milk"). With words: clear.
                      suffixIcon: _ctl.text.isEmpty
                          ? IconButton(
                              tooltip: _listening ? 'Stop listening' : 'Say what to find, or "note …" to save a note',
                              icon: Icon(_listening ? Icons.mic_rounded : Icons.mic_none_rounded, color: _listening ? ByteColors.accentBright : ByteColors.textDim),
                              onPressed: _voice,
                            )
                          : IconButton(tooltip: 'Clear', icon: const Icon(Icons.close_rounded), onPressed: _ctl.clear),
                    ),
                  ),
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: ValueListenableBuilder<String>(
                valueListenable: LibraryIndexer.instance.status,
                builder: (_, s, _) => s.isEmpty
                    ? const SizedBox.shrink()
                    : Padding(
                        padding: const EdgeInsets.fromLTRB(ByteSpace.page, 10, ByteSpace.page, 0),
                        child: Row(
                          children: [
                            const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2)),
                            const SizedBox(width: 10),
                            Expanded(child: Text('Still reading new files — $s', maxLines: 1, overflow: TextOverflow.ellipsis, style: tt.bodySmall)),
                          ],
                        ),
                      ),
              ),
            ),
            if (!typing) ..._idle(tt) else ..._found(tt),
            const SliverToBoxAdapter(child: SizedBox(height: 96)),
          ],
        ),
      ),
    );
  }

  /// Nothing typed yet: what you searched before, and a few words to try.
  List<Widget> _idle(TextTheme tt) {
    return [
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(ByteSpace.page, 14, ByteSpace.page, 0),
          child: Text(
            _total == 0
                ? 'Add something to the Library first; then one word finds it here.'
                : 'Looks inside ${_total == 1 ? 'the 1 thing' : 'all $_total things'} you saved: the words in photos, every page of a PDF, Word, PowerPoint and Excel files, links and notes.',
            style: tt.bodyMedium?.copyWith(color: ByteColors.textDim),
          ),
        ),
      ),
      if (_recent.isNotEmpty) ...[
        const SliverToBoxAdapter(child: SectionLabel('Recent', top: 22)),
        SliverToBoxAdapter(
          child: ByteList(
            children: [
              for (final r in _recent)
                ByteRow(
                  key: ValueKey('recent-$r'),
                  icon: Icons.history_rounded,
                  title: r,
                  titleWeight: FontWeight.w600,
                  trailing: IconButton(
                    tooltip: 'Remove',
                    icon: Icon(Icons.close_rounded, size: 18, color: ByteColors.textFaint),
                    onPressed: () => _forget(r),
                  ),
                  onTap: () => _use(r),
                ),
            ],
          ),
        ),
      ],
      if (_total > 0) ...[
        const SliverToBoxAdapter(child: SectionLabel('Try', top: 22)),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: ByteSpace.page),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [for (final t in _tries) Pill(t, selected: false, onTap: () => _use(t))],
            ),
          ),
        ),
      ],
    ];
  }

  /// A query is typed: type chips, the count, and one row per hit.
  List<Widget> _found(TextTheme tt) {
    final q = _ranFor;
    final alt = _respelled;
    final words = [...queryWords(q), ...queryWords(alt)];
    return [
      const SliverToBoxAdapter(child: SizedBox(height: 8)),
      SliverToBoxAdapter(
        child: ChipRow(
          children: [
            Pill('All', selected: _kind == null, onTap: () => _setKind(null)),
            for (final k in LibraryKind.values) Pill(k == LibraryKind.audio ? 'Voice' : k.label, selected: _kind == k, onTap: () => _setKind(k)),
          ],
        ),
      ),
      // When, and where.
      SliverToBoxAdapter(
        child: ChipRow(
          children: [
            Pill('Any time', selected: _when == 'any', onTap: () => _setWhen('any')),
            Pill('This week', selected: _when == 'week', onTap: () => _setWhen('week')),
            Pill('This month', selected: _when == 'month', onTap: () => _setWhen('month')),
            Pill('This year', selected: _when == 'year', onTap: () => _setWhen('year')),
            Pill(_folder == null ? 'Any folder' : 'In ${_folder!.name}', selected: _folder != null, onTap: _pickFolder),
          ],
        ),
      ),
      if (alt.isNotEmpty)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(ByteSpace.page, 12, ByteSpace.page, 0),
            child: Text('Also showing “$alt” — the closest spelling BYTE has read.', style: tt.bodySmall),
          ),
        ),
      SliverToBoxAdapter(
        child: SectionLabel(
          _busy && _results.isEmpty
              ? 'Searching…'
              : _results.isEmpty
                  ? 'No results'
                  : '${_results.length}${_results.length >= 200 ? '+' : ''} result${_results.length == 1 ? '' : 's'}',
          top: 18,
        ),
      ),
      if (_results.isEmpty && !_busy)
        const SliverToBoxAdapter(
          child: EmptyNote(
            'Nothing has that word. Check the spelling, try a shorter word, or wait a moment if you just added the file — BYTE may still be reading it.',
          ),
        )
      else ...[
        SliverToBoxAdapter(child: Container(height: 1, color: ByteColors.border)),
        SliverList.builder(
          itemCount: _results.length,
          itemBuilder: (_, i) {
            final it = _results[i];
            // The line it was found on: by your spelling first, then by the closest one.
            final hit = hitIn(it, q) ?? (alt.isEmpty ? null : hitIn(it, alt));
            return _ResultRow(key: ValueKey(it.id), item: it, hit: hit, words: words, onTap: () => _open(it));
          },
        ),
      ],
    ];
  }
}

/// One search result: the preview, the name with the match marked, what kind
/// of thing it is (and the page), and the line where the word was found.
class _ResultRow extends StatelessWidget {
  const _ResultRow({super.key, required this.item, required this.hit, required this.words, required this.onTap});
  final LibraryItem item;
  final SearchHit? hit;
  final List<String> words;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final it = item;
    final h = hit;
    final mark = TextStyle(fontWeight: FontWeight.w800, color: ByteColors.text, backgroundColor: ByteColors.accentSoft);
    final meta = <String>[
      if (it.kind == LibraryKind.audio) 'Voice note' else it.kind.label.replaceAll(RegExp(r's$'), ''),
      if (it.ext.isNotEmpty && it.kind == LibraryKind.doc) it.ext.toUpperCase(),
      if (h?.page != null) 'Page ${h!.page}',
      if (it.indexStatus == 'pending' || it.indexStatus == 'working') 'still reading…',
    ].join(' · ');
    return Pressable(
      onTap: onTap,
      pressedScale: 0.985,
      child: Container(
        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: ByteColors.border))),
        padding: const EdgeInsets.symmetric(horizontal: ByteSpace.page, vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 52,
              height: 52,
              child: ClipRRect(borderRadius: BorderRadius.circular(ByteSpace.rs), child: LibraryThumb(item: it, fit: BoxFit.cover)),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text.rich(
                    TextSpan(children: [
                      for (final (piece, isHit) in splitMatches(it.displayTitle, words)) TextSpan(text: piece, style: isHit ? mark : null),
                    ]),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 2),
                  Text(meta, maxLines: 1, overflow: TextOverflow.ellipsis, style: tt.bodySmall),
                  if (h != null) ...[
                    const SizedBox(height: 4),
                    Text.rich(
                      TextSpan(children: [
                        TextSpan(text: '…${h.before}'),
                        TextSpan(text: h.match, style: mark),
                        TextSpan(text: '${h.after}…'),
                      ]),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: tt.bodySmall?.copyWith(color: ByteColors.textDim, height: 1.4),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 10),
            Meta(agoShort(it.createdAt)),
          ],
        ),
      ),
    );
  }
}
