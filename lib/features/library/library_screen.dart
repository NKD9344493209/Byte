import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/capture_trigger.dart';
import '../../core/prefs.dart';
import '../../core/stars.dart';
import '../../core/thumbs.dart';
import '../../shared/motion.dart';
import '../../shared/selection.dart';
import '../../shared/sticky.dart';
import '../../shared/theme.dart';
import '../../shared/ui.dart';
import '../albums/albums.dart';
import '../albums/albums_strip.dart';
import '../capture/audio_repo.dart';
import '../home/drive_pill.dart';
import '../home/safe_card.dart';
import '../librarian/tidy_screen.dart';
import '../notes/note_editor_screen.dart';
import '../notes/notes_repo.dart';
import '../private/private_gate.dart';
import '../settings/gallery_screen.dart';
import '../settings/settings_screen.dart';
import '../share/share_flow.dart';
import 'collection_picker.dart';
import 'collections_repo.dart';
import 'indexer.dart';
import 'library_item.dart';
import 'library_repo.dart';
import 'library_viewer.dart';
import 'media_pager.dart';
import 'timeline.dart';

/// The first tab. On top the albums BYTE keeps by itself; under them the
/// Gallery — your camera photos and videos and the ones you added, day by
/// day, and nothing else. Voice notes, notes, documents and links are not
/// mixed in: each has its own chip, with a green dot (and one line under the
/// chips) when something new is in there, so nothing is missed.
class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  /// Goes up when you leave the Library tab: a selection there is dropped
  /// (it must not swallow a Back press on another tab).
  static final ValueNotifier<int> left = ValueNotifier<int>(0);

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  final _repo = LibraryRepo.instance;
  final _sel = Selection();
  final _scroll = ScrollController();
  List<LibraryItem> _items = const [];
  Map<LibraryKind, int> _counts = const {};
  LibraryKind? _kind;
  bool _starred = false;
  bool _loaded = false;
  bool _busy = false;
  bool _countsKnown = false;
  bool _loadingRest = false; // the first piece is shown; older things are still coming
  bool _switching = false; // a chip was just tapped; its first page is on the way
  int _loadSeq = 0;

  @override
  void initState() {
    super.initState();
    _repo.revision.addListener(_loadSoon);
    NotesRepo.instance.revision.addListener(_loadSoon);
    AudioRepo.instance.revision.addListener(_loadSoon);
    Stars.changed.addListener(_loadSoon);
    // Sorted into albums: what belongs in the main list may have changed.
    Albums.changed.addListener(_loadSoon);
    _sel.addListener(_onSelection);
    LibraryScreen.left.addListener(_sel.clear);
    _load();
  }

  Timer? _soon;

  /// Several changes in a row (the reader working through photos) make one
  /// reload, not one each.
  void _loadSoon() {
    _soon?.cancel();
    _soon = Timer(const Duration(milliseconds: 250), _load);
  }

  @override
  void dispose() {
    _soon?.cancel();
    _repo.revision.removeListener(_loadSoon);
    NotesRepo.instance.revision.removeListener(_loadSoon);
    AudioRepo.instance.revision.removeListener(_loadSoon);
    Stars.changed.removeListener(_loadSoon);
    Albums.changed.removeListener(_loadSoon);
    LibraryScreen.left.removeListener(_sel.clear);
    _scroll.dispose();
    _sel.dispose();
    super.dispose();
  }

  void _onSelection() {
    if (mounted) setState(() {});
  }

  /// (Re)loads the list: the newest things at once, the rest in pieces in
  /// the background, so the slider can reach every year. While a reload
  /// runs, what is on screen stays until the new list is at least as long.
  Future<void> _load() async {
    if (!mounted) return;
    final seq = ++_loadSeq;
    final kind = _kind;
    final starred = _starred;
    final main = !_filtered;
    unawaited(_repo.counts().then((counts) {
      if (!mounted || seq != _loadSeq) return;
      setState(() {
        _counts = counts;
        _countsKnown = true;
      });
    }));
    unawaited(_lookForNew());
    await loadInPieces(
      // The Gallery: pictures only, without screenshots and other apps' pictures.
      fetch: (limit, offset) => _repo.list(kind: kind, starred: starred, mainOnly: main, pictures: main, limit: limit, offset: offset, withText: false),
      stale: () => !mounted || seq != _loadSeq,
      onPiece: (items, done) {
        if (!done && _loaded && !_switching && _items.length > items.length) return; // keep the longer list until all is here
        setState(() {
          _items = items;
          _loaded = true;
          _switching = false;
          _loadingRest = !done;
        });
      },
    );
  }

  // ───────────── "something new" in the kinds that are not pictures ─────────────

  static const _apart = [LibraryKind.audio, LibraryKind.note, LibraryKind.doc, LibraryKind.link];

  /// How many new things each of those kinds has since you last opened its chip.
  Map<LibraryKind, int> _fresh = const {};

  static String _seenKey(LibraryKind k) => 'seen_kind_${k.name}';

  Future<void> _lookForNew() async {
    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      final seen = <LibraryKind, int>{};
      for (final k in _apart) {
        var at = Prefs.number(_seenKey(k));
        if (at == 0) {
          // The first time: what is there already is not "new".
          at = now;
          await Prefs.setNumber(_seenKey(k), now);
        }
        seen[k] = at;
      }
      final fresh = await _repo.newSince(seen);
      // The chip that is open right now is being looked at.
      final open = _kind;
      if (open != null && fresh.remove(open) != null) await Prefs.setNumber(_seenKey(open), now);
      if (mounted) setState(() => _fresh = fresh);
    } catch (e) {
      debugPrint('[library] new: $e');
    }
  }

  static String _countOf(LibraryKind k, int n) => switch (k) {
        LibraryKind.audio => n == 1 ? '1 voice note' : '$n voice notes',
        LibraryKind.note => n == 1 ? '1 note' : '$n notes',
        LibraryKind.doc => n == 1 ? '1 document' : '$n documents',
        LibraryKind.link => n == 1 ? '1 link' : '$n links',
        _ => '$n',
      };

  void _setFilter({LibraryKind? kind, bool starred = false}) {
    // Opening a chip = you have seen what is new in it.
    if (kind != null && _apart.contains(kind)) {
      unawaited(Prefs.setNumber(_seenKey(kind), DateTime.now().millisecondsSinceEpoch));
      _fresh = {
        for (final e in _fresh.entries)
          if (e.key != kind) e.key: e.value,
      };
    }
    setState(() {
      _kind = kind;
      _starred = starred;
      _items = const []; // a new filter starts from the top
      _switching = true;
    });
    _load();
  }

  // ───────────── adding ─────────────

  Future<void> _addSheet() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(Icons.photo_library_outlined, color: ByteColors.accentDim),
              title: const Text('Photos & videos'),
              subtitle: const Text('From your gallery, many at once'),
              onTap: () => Navigator.pop(ctx, 'media'),
            ),
            ListTile(
              leading: Icon(Icons.photo_camera_outlined, color: ByteColors.accentDim),
              title: const Text('Camera'),
              onTap: () => Navigator.pop(ctx, 'camera'),
            ),
            ListTile(
              leading: Icon(Icons.insert_drive_file_outlined, color: ByteColors.accentDim),
              title: const Text('Any file'),
              subtitle: const Text('PDF, Excel, PPT, Word, anything'),
              onTap: () => Navigator.pop(ctx, 'file'),
            ),
            ListTile(
              leading: Icon(Icons.mic_none_rounded, color: ByteColors.accentDim),
              title: const Text('Voice note'),
              subtitle: const Text('Starts recording at once'),
              onTap: () => Navigator.pop(ctx, 'voice'),
            ),
            ListTile(
              leading: Icon(Icons.edit_note_rounded, color: ByteColors.accentDim),
              title: const Text('Note'),
              onTap: () => Navigator.pop(ctx, 'note'),
            ),
            ListTile(
              leading: Icon(Icons.checklist_rounded, color: ByteColors.accentDim),
              title: const Text('Checklist'),
              subtitle: const Text('Things to do. Tick them from your notifications'),
              onTap: () => Navigator.pop(ctx, 'checklist'),
            ),
            ListTile(
              leading: Icon(Icons.link_rounded, color: ByteColors.accentDim),
              title: const Text('Paste a link'),
              subtitle: const Text('YouTube, articles, anything on the web'),
              onTap: () => Navigator.pop(ctx, 'link'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    if (choice == 'voice') {
      // The same quick recorder the neckband button opens.
      await CaptureTrigger.onTrigger(source: 'app');
      return;
    }
    if (choice == 'note') {
      await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const NoteEditorScreen()));
      return;
    }
    if (choice == 'checklist') {
      await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const NoteEditorScreen(checklist: true)));
      return;
    }
    try {
      setState(() => _busy = true);
      switch (choice) {
        case 'media':
          final files = await ImagePicker().pickMultipleMedia();
          await _importAll([for (final f in files) (f.path, f.name)]);
        case 'camera':
          final f = await ImagePicker().pickImage(source: ImageSource.camera, imageQuality: 92);
          if (f != null) await _importAll([(f.path, f.name)], move: true);
        case 'file':
          final files = await FilePicker.pickFiles();
          await _importAll([
            for (final f in files)
              if (f.path != null) (f.path!, f.name),
          ]);
        case 'link':
          await _pasteLink();
      }
    } catch (e) {
      if (mounted) _snack('Couldn\'t add: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _importAll(List<(String, String)> files, {bool move = false}) async {
    var n = 0;
    for (final (path, name) in files) {
      await _repo.importFile(path, displayName: name, move: move);
      n++;
    }
    if (n > 0 && mounted) _snack('Added $n ${n == 1 ? 'item' : 'items'}. BYTE is reading ${n == 1 ? 'it' : 'them'} so you can search inside.');
  }

  Future<void> _pasteLink() async {
    final ctl = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add a link'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(hintText: 'https://…'),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(style: inlineButton, onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(style: inlineButton, onPressed: () => Navigator.pop(ctx, ctl.text), child: const Text('Add')),
        ],
      ),
    );
    Future<void>.delayed(const Duration(seconds: 1), ctl.dispose);
    if (url == null || url.trim().isEmpty) return;
    await _repo.addLink(url);
  }

  // ───────────── selection actions ─────────────

  Future<void> _moveSelected() async {
    final ids = _sel.ids.toList();
    if (ids.isEmpty) return;
    final changed = await CollectionPicker.show(context, itemIds: ids);
    if (!mounted) return;
    _sel.clear();
    if (changed != null && changed.isNotEmpty) _snack(changed.join(', '));
  }

  /// Into the private space (asks first, then the private PIN).
  Future<void> _privateSelected() async {
    final ids = _sel.ids.toList();
    if (ids.isEmpty) return;
    final moved = await PrivateGate.makePrivate(context, ids);
    if (moved && mounted) _sel.clear();
  }

  /// A link to copies of the chosen things (Google Drive).
  Future<void> _shareSelected() async {
    final ids = _sel.ids.toList();
    if (ids.isEmpty) return;
    final made = await ShareFlow.start(context, ids);
    if (made && mounted) _sel.clear();
  }

  Future<void> _starSelected() async {
    final ids = _sel.ids.toList();
    final starred = await Stars.toggleMany(ids);
    if (!mounted) return;
    _sel.clear();
    _snack(starred ? 'Starred' : 'Star removed');
  }

  /// To the bin, with an Undo that brings every one of them straight back.
  Future<void> _deleteSelected() async {
    final n = _sel.count;
    final ok = await confirmBulk(
      context,
      title: 'Move $n item${n == 1 ? '' : 's'} to the bin?',
      body: 'They stay in the bin for 30 days. You can bring them back from Folders → Bin.',
      action: 'Move to bin',
    );
    if (!ok || !mounted) return;
    final ids = _sel.ids.toList();
    await _repo.deleteMany(ids);
    NotesRepo.instance.revision.value++;
    AudioRepo.instance.revision.value++;
    if (!mounted) return;
    // Gone from the screen at once (the full reload follows).
    final gone = ids.toSet();
    setState(() => _items = [
          for (final i in _items)
            if (!gone.contains(i.id)) i,
        ]);
    _sel.clear();
    Haptics.confirm();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('Moved ${ids.length} item${ids.length == 1 ? '' : 's'} to the bin'),
      duration: const Duration(seconds: 6),
      persist: false, // goes away by itself, Undo or not
      action: SnackBarAction(
        label: 'Undo',
        onPressed: () async {
          await _repo.restoreMany(ids);
          NotesRepo.instance.revision.value++;
          AudioRepo.instance.revision.value++;
        },
      ),
    ));
  }

  void _snack(String m) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  Future<void> _open(LibraryItem it) async {
    switch (it.kind) {
      case LibraryKind.note:
        final note = await NotesRepo.instance.get(it.id);
        if (note == null || !mounted) return;
        await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => NoteEditorScreen(note: note)));
      case LibraryKind.photo || LibraryKind.video:
        // Full screen; swipe left and right through the pictures of this list.
        await MediaPager.open(context, it, around: _items);
      default:
        await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => LibraryViewer(itemId: it.id)));
    }
  }

  // ───────────── UI ─────────────

  bool get _filtered => _kind != null || _starred;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final fabFg = Theme.of(context).floatingActionButtonTheme.foregroundColor;
    final total = _counts.values.fold<int>(0, (a, b) => a + b);
    // Truly empty: nothing saved at all (a filter with no hits keeps the chips on screen).
    final nothing = _loaded && _countsKnown && total == 0 && !_filtered;
    // (The width inside the safe area: a notch at the side when the phone lies down.)
    final layout = _layoutFor(MediaQuery.sizeOf(context).width - MediaQuery.paddingOf(context).horizontal, MediaQuery.textScalerOf(context).scale(1));

    return SelectionBack(
      sel: _sel,
      child: Scaffold(
        appBar: _sel.active
            ? selectionAppBar(
                sel: _sel,
                allIds: const [], // "Select all" is under ⋮, so "3 selected" has room
                actions: [
                  IconButton(
                    tooltip: 'Move to a folder',
                    icon: Icon(Icons.drive_file_move_outline, color: ByteColors.accentDim),
                    onPressed: _moveSelected,
                  ),
                  IconButton(
                    tooltip: 'Share with a link',
                    icon: Icon(Icons.ios_share_rounded, color: ByteColors.accentDim),
                    onPressed: _shareSelected,
                  ),
                  IconButton(
                    tooltip: 'Move to bin',
                    icon: Icon(Icons.delete_outline, color: ByteColors.danger),
                    onPressed: _deleteSelected,
                  ),
                  PopupMenuButton<String>(
                    tooltip: 'More',
                    onSelected: (v) {
                      switch (v) {
                        case 'all':
                          _sel.setAll([for (final i in _items) i.id]);
                        case 'star':
                          _starSelected();
                        default:
                          _privateSelected();
                      }
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'all', child: Text('Select all')),
                      PopupMenuItem(value: 'star', child: Text('Star')),
                      PopupMenuItem(value: 'private', child: Text('Make private')),
                    ],
                  ),
                ],
              )
            : null,
        floatingActionButton: _sel.active
            ? null
            : FloatingActionButton(
                heroTag: 'library-fab', // other tabs stay alive in the IndexedStack with their own FABs
                tooltip: 'Add to BYTE',
                onPressed: _busy ? null : _addSheet,
                child: _busy
                    ? SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2, color: fabFg))
                    : const Icon(Icons.add_rounded),
              ),
        body: SafeArea(
          bottom: false,
          child: !_loaded
              ? const SizedBox.shrink()
              : FastScroller(
                  controller: _scroll,
                  bottomInset: 88, // the + button
                  labelAt: (pixels) => _dateAt(pixels, layout),
                  child: CustomScrollView(
                  controller: _scroll,
                  slivers: [
                    if (!_sel.active)
                      SliverToBoxAdapter(
                        child: PageTitle(
                          'Library',
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const DrivePill(),
                              IconButton(
                                tooltip: 'Settings',
                                icon: const Icon(Icons.settings_outlined),
                                onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SettingsScreen())),
                              ),
                            ],
                          ),
                        ),
                      ),
                    // The offer to bring in the phone's gallery, or its progress.
                    const SliverToBoxAdapter(child: GalleryCard()),
                    // Kept for good, light on the phone: offers the Drive copy and freeing space.
                    const SliverToBoxAdapter(child: SafeCard()),
                    const SliverToBoxAdapter(child: TidyCard()),
                    // The albums BYTE keeps by itself.
                    if (!nothing) const SliverToBoxAdapter(child: AlbumsStrip()),
                    if (nothing)
                      SliverToBoxAdapter(
                        child: EmptyNote(
                          'Nothing here yet. Add photos, videos, PDFs, notes or a voice note with the + button, or share to BYTE from any app.',
                          action: 'Add something',
                          onAction: _addSheet,
                        ),
                      )
                    else ...[
                      // ── Gallery · Videos 9 · Voice 12 · Notes 4 · Docs · Links · Starred ──
                      // (Each kind in its own place; a green dot = something new in there.)
                      SliverToBoxAdapter(
                        child: ChipRow(
                          children: [
                            Pill('Gallery', selected: !_filtered, onTap: () => _setFilter()),
                            for (final k in const [LibraryKind.video, LibraryKind.audio, LibraryKind.note, LibraryKind.doc, LibraryKind.link])
                              if ((_counts[k] ?? 0) > 0 || _kind == k)
                                Pill(
                                  k == LibraryKind.audio ? 'Voice' : k.label,
                                  count: _counts[k] ?? 0,
                                  selected: _kind == k,
                                  dot: (_fresh[k] ?? 0) > 0 && _kind != k,
                                  onTap: () => _setFilter(kind: k),
                                ),
                            Pill('Starred', selected: _starred, onTap: () => _setFilter(starred: true)),
                          ],
                        ),
                      ),
                      // In the Gallery: one line that says what is new elsewhere, so nothing is missed.
                      if (!_filtered && _fresh.isNotEmpty)
                        SliverToBoxAdapter(
                          child: Pressable(
                            onTap: () => _setFilter(kind: _apart.firstWhere((k) => (_fresh[k] ?? 0) > 0, orElse: () => LibraryKind.audio)),
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(ByteSpace.page, 10, ByteSpace.page, 0),
                              child: Row(
                                children: [
                                  Container(width: 7, height: 7, decoration: BoxDecoration(color: ByteColors.accentBright, shape: BoxShape.circle)),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Text(
                                      'New: ${[
                                        for (final k in _apart)
                                          if ((_fresh[k] ?? 0) > 0) _countOf(k, _fresh[k]!),
                                      ].join(', ')}',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: tt.bodySmall?.copyWith(color: ByteColors.text, fontWeight: FontWeight.w600),
                                    ),
                                  ),
                                  Icon(Icons.chevron_right_rounded, size: 18, color: ByteColors.textFaint),
                                ],
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
                                  padding: const EdgeInsets.fromLTRB(ByteSpace.page, 8, ByteSpace.page, 0),
                                  child: Row(
                                    children: [
                                      const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2)),
                                      const SizedBox(width: 10),
                                      Expanded(child: Text(s, maxLines: 1, overflow: TextOverflow.ellipsis, style: tt.bodySmall)),
                                    ],
                                  ),
                                ),
                        ),
                      ),
                      if (_items.isEmpty && _switching)
                        // The chip's first page is still loading: stay quiet instead of saying "nothing".
                        const SliverToBoxAdapter(child: SizedBox(height: 120))
                      else if (_items.isEmpty)
                        SliverToBoxAdapter(
                          child: EmptyNote(
                            _starred
                                ? 'Nothing starred yet. Long-press anything and tap the star.'
                                : _kind == null
                                    ? 'No photos or videos here yet. Voice notes, notes and documents have their own chips above.'
                                    : 'No ${_kind == LibraryKind.audio ? 'voice notes' : _kind!.label.toLowerCase()} yet.',
                          ),
                        )
                      else
                        // One heading per day; every row's height is known, so the slider can jump anywhere.
                        TimelineSliver(
                          layout: layout,
                          tile: _tile,
                          line: (it) => LibraryRow(
                            item: it,
                            query: '',
                            compact: true,
                            selected: _sel.contains(it.id),
                            onLongPress: () => _sel.toggle(it.id),
                            onTap: () => _sel.active ? _sel.toggle(it.id) : _open(it),
                          ),
                        ),
                      if (_loadingRest)
                        const SliverToBoxAdapter(
                          child: Padding(
                            padding: EdgeInsets.symmetric(vertical: 20),
                            child: Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))),
                          ),
                        ),
                      const SliverToBoxAdapter(child: SizedBox(height: _bottomSpace)),
                    ],
                  ],
                ),
                ),
        ),
      ),
    );
  }

  /// Room under the list (the + button must not cover the last row).
  static const double _bottomSpace = 96;

  TimelineLayout? _layout;
  List<LibraryItem>? _layoutItems;
  int _layoutDay = 0;

  /// The rows of the list with their heights — worked out again only when
  /// the list, the screen width or the font size changed.
  TimelineLayout _layoutFor(double width, double textScale) {
    final m = TimelineMetrics(width: width, textScale: textScale);
    // ("Today" and "Yesterday" are worked out again when the day changes.)
    final now = DateTime.now();
    final day = now.year * 10000 + now.month * 100 + now.day;
    final have = _layout;
    if (have != null && identical(_layoutItems, _items) && have.metrics == m && _layoutDay == day) return have;
    _layoutItems = _items;
    _layoutDay = day;
    return _layout = TimelineLayout(timelineRows(_items), m);
  }

  /// What the slider's label says at a scroll position: the month there.
  String _dateAt(double pixels, TimelineLayout layout) {
    if (!_scroll.hasClients || layout.rows.isEmpty) return '';
    final pos = _scroll.position;
    // Everything above the list (title, cards, albums, chips) = the whole
    // page minus the list and the room under it.
    final above = pos.maxScrollExtent + pos.viewportDimension - layout.height - _bottomSpace - (_loadingRest ? 58 : 0);
    final row = layout.rowAt(pixels + pos.viewportDimension * 0.3 - above);
    return row == null ? '' : monthLabel(row.day);
  }

  Widget _tile(LibraryItem it) {
    return MediaTile(
      item: it,
      selected: _sel.contains(it.id),
      onLongPress: () => _sel.toggle(it.id),
      onTap: () => _sel.active ? _sel.toggle(it.id) : _open(it),
    );
  }
}

/// One square of a picture grid: the preview, a play mark on a video, the
/// sticky note along the bottom, the star, and the tick while selecting.
class MediaTile extends StatelessWidget {
  const MediaTile({super.key, required this.item, required this.onTap, this.onLongPress, this.selected = false});
  final LibraryItem item;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final it = item;
    return Pressable(
      onLongPress: onLongPress,
      onTap: onTap,
      pressedScale: 0.95,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // The picture grows from here into the viewer and back.
          Hero(
            tag: 'media-${it.id}',
            child: ClipRRect(borderRadius: BorderRadius.circular(8), child: LibraryThumb(item: it, fit: BoxFit.cover)),
          ),
          if (it.kind == LibraryKind.video)
            const Positioned(bottom: 6, left: 6, child: Icon(Icons.play_circle_fill_rounded, color: Colors.white, size: 22)),
          if (it.sticky.isNotEmpty)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                decoration: const BoxDecoration(
                  color: StickyNote.paper,
                  borderRadius: BorderRadius.vertical(bottom: Radius.circular(8)),
                ),
                child: Text(
                  it.sticky,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 10, color: StickyNote.ink, fontWeight: FontWeight.w600),
                ),
              ),
            ),
          if (it.pinned && !selected)
            Positioned(
              top: 4,
              right: 4,
              child: Container(
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(color: ByteColors.accent, shape: BoxShape.circle),
                child: Icon(Icons.star_rounded, size: 11, color: ByteColors.onAccent),
              ),
            ),
          if (selected)
            Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: ByteColors.accent, width: 2),
                color: ByteColors.accent.withValues(alpha: 0.18),
              ),
              child: const Align(alignment: Alignment.topRight, child: Padding(padding: EdgeInsets.all(6), child: SelectedBadge())),
            ),
        ],
      ),
    );
  }
}

/// A folder card: a cover made of its newest pictures with the count on a
/// dark strip, the name, and how many things are inside.
class FolderCard extends StatelessWidget {
  const FolderCard({super.key, required this.c, required this.covers, required this.onTap, required this.onLongPress});
  final Collection c;
  final List<LibraryItem> covers;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final sub = c.count == 0
        ? 'Empty'
        : '${c.count} ${c.count == 1 ? 'item' : 'items'}${c.updatedAt == null ? '' : ' · ${agoText(c.updatedAt!)}'}';
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      onLongPress: onLongPress,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          AspectRatio(
            aspectRatio: 16 / 10,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _cover(),
                  // The count on a dark strip at the right.
                  Positioned(
                    right: 0,
                    top: 0,
                    bottom: 0,
                    child: Container(
                      width: 44,
                      color: Colors.black.withValues(alpha: 0.55),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text('${c.count}', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 14)),
                          Icon(CollectionPicker.iconFor(c), color: Colors.white, size: 16),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(c.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: tt.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
          Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: tt.bodySmall?.copyWith(fontSize: 12)),
        ],
      ),
    );
  }

  Widget _cover() {
    if (covers.isEmpty) {
      return Container(
        color: ByteColors.surface2,
        alignment: Alignment.center,
        child: Icon(CollectionPicker.iconFor(c), color: ByteColors.textFaint, size: 32),
      );
    }
    if (covers.length < 4) return LibraryThumb(item: covers.first, fit: BoxFit.cover);
    // Four newest as a 2×2 mosaic.
    return Column(
      children: [
        Expanded(child: Row(children: [Expanded(child: LibraryThumb(item: covers[0])), Expanded(child: LibraryThumb(item: covers[1]))])),
        Expanded(child: Row(children: [Expanded(child: LibraryThumb(item: covers[2])), Expanded(child: LibraryThumb(item: covers[3]))])),
      ],
    );
  }
}

/// The last card in the grid: a quiet well with a plus, "New folder".
class NewFolderCard extends StatelessWidget {
  const NewFolderCard({super.key, required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          AspectRatio(
            aspectRatio: 16 / 10,
            child: Container(
              decoration: BoxDecoration(color: ByteColors.surface2, borderRadius: BorderRadius.circular(14)),
              alignment: Alignment.center,
              child: Icon(Icons.add_rounded, color: ByteColors.textFaint, size: 28),
            ),
          ),
          const SizedBox(height: 8),
          Text('New folder', style: tt.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
          Text('College, Bills, Trips…', maxLines: 1, overflow: TextOverflow.ellipsis, style: tt.bodySmall?.copyWith(fontSize: 12)),
        ],
      ),
    );
  }
}

/// "just now", "3 h ago", "2 d ago", "12/4/2026".
String agoText(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return 'just now';
  if (d.inHours < 1) return '${d.inMinutes} min ago';
  if (d.inDays < 1) return '${d.inHours} h ago';
  if (d.inDays < 7) return '${d.inDays} d ago';
  return '${t.day}/${t.month}/${t.year}';
}

/// Short form for the right edge of a row: "now", "3 h", "Wed", "12/4".
String agoShort(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return 'now';
  if (d.inHours < 1) return '${d.inMinutes} min';
  if (d.inDays < 1) return '${d.inHours} h';
  if (d.inDays < 7) return const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][t.weekday - 1];
  return '${t.day}/${t.month}';
}

/// One Library line: thumbnail, title, "kind · size · tags", the search
/// snippet or sticky underneath, and when it was added at the right.
class LibraryRow extends StatelessWidget {
  const LibraryRow({
    super.key,
    required this.item,
    required this.query,
    this.index,
    this.selected = false,
    this.compact = false,
    this.onTap,
    this.onLongPress,
  });
  final LibraryItem item;
  final String query;

  /// One line for the name and one for the details (the timeline: every row
  /// there has the same height).
  final bool compact;

  /// Shown on the left inside a folder (1, 2, 3…) — the order you added things.
  final int? index;

  final bool selected;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final it = item;
    final line = <String>[
      it.kind.label.replaceAll(RegExp(r's$'), ''),
      if (it.size > 0) humanSize(it.size),
      if (it.kind == LibraryKind.audio && it.durationMs > 0) '${(it.durationMs / 1000).round()} s',
      if (it.indexStatus == 'pending' || it.indexStatus == 'working') 'reading…',
      if (it.indexStatus == 'failed') 'couldn\'t read',
      ...it.tags.take(3),
    ].join(' · ');
    final snippet = _snippet(it, query);
    final second = snippet ?? (it.sticky.isNotEmpty ? '“${it.sticky}”' : null);
    return ByteRow(
      title: it.displayTitle,
      subtitle: second == null || compact ? line : '$line\n$second',
      titleLines: compact ? 1 : 2,
      subtitleLines: compact ? 1 : 2,
      selected: selected,
      onTap: onTap,
      onLongPress: onLongPress,
      leading: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (index != null)
            SizedBox(
              width: 22,
              child: Text('$index', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: ByteColors.textFaint, fontFeatures: const [FontFeature.tabularFigures()])),
            ),
          SizedBox(
            width: 48,
            height: 48,
            child: ClipRRect(borderRadius: BorderRadius.circular(ByteSpace.rs), child: LibraryThumb(item: it, fit: BoxFit.cover)),
          ),
        ],
      ),
      trailing: selected
          ? const SelectedBadge()
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (it.pinned) ...[
                  Icon(Icons.star_rounded, size: 14, color: ByteColors.textFaint),
                  const SizedBox(width: 4),
                ],
                Meta(agoShort(it.createdAt)),
              ],
            ),
    );
  }

  /// A few words around the first query hit in the extracted text/body.
  static String? _snippet(LibraryItem it, String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return null;
    final hay = '${it.text}\n${it.body}\n${it.labels.join(', ')}';
    if (hay.trim().isEmpty) return null;
    final words = q.split(RegExp(r'\s+')).expand(expandQueryWord).toList();
    final low = hay.toLowerCase();
    for (final w in words) {
      final i = low.indexOf(w);
      if (i < 0) continue;
      final start = (i - 40).clamp(0, hay.length);
      final end = (i + w.length + 60).clamp(0, hay.length);
      return '…${hay.substring(start, end).replaceAll('\n', ' ')}…';
    }
    return null;
  }
}

/// Thumbnail for any item: its preview picture if there is one, otherwise an
/// icon in a quiet well. A gallery photo BYTE has not read yet gets Android's
/// own small picture, asked for when the square comes on screen.
///
/// [bare]: nothing behind the picture (the full-screen viewer is black).
class LibraryThumb extends StatelessWidget {
  const LibraryThumb({super.key, required this.item, this.fit = BoxFit.cover, this.bare = false});
  final LibraryItem item;
  final BoxFit fit;
  final bool bare;

  @override
  Widget build(BuildContext context) {
    final it = item;
    final ready = it.thumb.isNotEmpty ? it.thumb : Thumbs.made(it.id);
    if (ready != null) return picture(it, ready, fit, bare: bare);
    final media = it.kind == LibraryKind.photo || it.kind == LibraryKind.video;
    if (it.fromGallery && media && !Thumbs.hopeless(it.id)) return _LazyThumb(key: ValueKey('lazy-${it.id}'), item: it, fit: fit, bare: bare);
    // One of BYTE's own photos that is still being read: the photo itself.
    if (it.kind == LibraryKind.photo && it.path.isNotEmpty) return picture(it, it.path, fit, bare: bare);
    return bare ? const SizedBox.shrink() : icon(it);
  }

  /// The picture at [path], small (480 px), with the icon when it cannot be shown.
  static Widget picture(LibraryItem it, String path, BoxFit fit, {bool bare = false}) {
    final image = Image.file(
      File(path),
      fit: fit,
      cacheWidth: 480,
      gaplessPlayback: true,
      errorBuilder: (_, _, _) => bare ? const SizedBox.shrink() : icon(it),
    );
    return bare ? image : ColoredBox(color: ByteColors.surface2, child: image);
  }

  static Widget icon(LibraryItem item) {
    final glyph = switch (item.kind) {
      LibraryKind.photo => Icons.image_outlined,
      LibraryKind.video => Icons.videocam_outlined,
      LibraryKind.doc => _docIcon(item.ext),
      LibraryKind.link => Icons.link_rounded,
      LibraryKind.audio => Icons.mic_rounded,
      LibraryKind.note => Icons.notes_rounded,
    };
    return Container(
      color: ByteColors.surface2,
      alignment: Alignment.center,
      child: Icon(glyph, color: ByteColors.textDim, size: 22),
    );
  }

  static IconData _docIcon(String ext) => switch (ext) {
        'pdf' => Icons.picture_as_pdf_outlined,
        'xlsx' || 'xls' || 'csv' => Icons.table_chart_outlined,
        'pptx' || 'ppt' => Icons.slideshow_outlined,
        'docx' || 'doc' || 'txt' || 'md' => Icons.description_outlined,
        _ => Icons.insert_drive_file_outlined,
      };
}

/// Waits for Android's small picture of a gallery photo; a quiet square
/// until it is there.
class _LazyThumb extends StatefulWidget {
  const _LazyThumb({super.key, required this.item, required this.fit, required this.bare});
  final LibraryItem item;
  final BoxFit fit;
  final bool bare;

  @override
  State<_LazyThumb> createState() => _LazyThumbState();
}

class _LazyThumbState extends State<_LazyThumb> {
  String? _path;
  bool _answered = false;

  @override
  void initState() {
    super.initState();
    final id = widget.item.id;
    Thumbs.want(id, widget.item.mediaKey).then((path) {
      if (!mounted) return;
      setState(() {
        _path = path;
        _answered = true;
      });
    });
  }

  @override
  void dispose() {
    if (!_answered) Thumbs.drop(widget.item.id);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final it = widget.item;
    final path = _path;
    if (path != null) return LibraryThumb.picture(it, path, widget.fit, bare: widget.bare);
    if (_answered) {
      // Android has none: the photo itself, or the icon for a video.
      if (it.kind == LibraryKind.photo && it.path.isNotEmpty) return LibraryThumb.picture(it, it.path, widget.fit, bare: widget.bare);
      return widget.bare ? const SizedBox.shrink() : LibraryThumb.icon(it);
    }
    return widget.bare ? const SizedBox.shrink() : ColoredBox(color: ByteColors.surface2, child: const SizedBox.expand());
  }
}
