import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/stars.dart';
import '../../shared/motion.dart';
import '../../shared/selection.dart';
import '../../shared/theme.dart';
import '../../shared/ui.dart';
import '../library/collection_picker.dart';
import '../library/library_item.dart';
import '../library/library_repo.dart';
import '../library/library_screen.dart' show LibraryRow, MediaTile;
import '../library/library_viewer.dart';
import '../library/media_pager.dart';
import '../library/timeline.dart';
import '../private/private_gate.dart';
import '../share/share_flow.dart';
import 'albums.dart';

/// One album, opened: day by day (newest first), pictures as a grid and any
/// documents as rows, with the slider at the right edge. Tap a picture to
/// see it full screen and swipe through the album; long-press to pick several.
class AlbumScreen extends StatefulWidget {
  const AlbumScreen({super.key, required this.album});
  final Album album;

  @override
  State<AlbumScreen> createState() => _AlbumScreenState();
}

class _AlbumScreenState extends State<AlbumScreen> {
  final _repo = LibraryRepo.instance;
  final _sel = Selection();
  final _scroll = ScrollController();
  List<LibraryItem> _items = const [];
  bool _loaded = false;
  bool _loadingRest = false;
  int _seq = 0;
  Timer? _soon;

  /// Going back to the Library: its grid shows some of the same pictures,
  /// and they must not fly across the screen.
  bool _leaving = false;

  @override
  void initState() {
    super.initState();
    _repo.revision.addListener(_later);
    Albums.changed.addListener(_later);
    _sel.addListener(_onSelection);
    _load();
  }

  @override
  void dispose() {
    _soon?.cancel();
    _repo.revision.removeListener(_later);
    Albums.changed.removeListener(_later);
    _scroll.dispose();
    _sel.dispose();
    super.dispose();
  }

  void _onSelection() {
    if (mounted) setState(() {});
  }

  void _later() {
    _soon?.cancel();
    _soon = Timer(const Duration(milliseconds: 300), _load);
  }

  Future<List<LibraryItem>> _fetch(int limit, int offset) {
    final a = widget.album;
    // "On this day": your own photos and videos of this date in earlier years.
    if (a.onDay != null) return _repo.list(onDay: a.onDay, mainOnly: true, pictures: true, limit: limit, offset: offset, withText: false);
    return _repo.list(
      // A run of busy days: the camera photos of those days.
      place: a.isDays ? 'Camera' : a.place,
      since: a.from,
      until: a.until,
      limit: limit,
      offset: offset,
      withText: false,
    );
  }

  /// The newest at once, the rest in pieces in the background (so the
  /// slider reaches the whole album).
  Future<void> _load() async {
    if (!mounted) return;
    final seq = ++_seq;
    await loadInPieces(
      fetch: _fetch,
      stale: () => !mounted || seq != _seq,
      onPiece: (items, done) {
        if (!done && _loaded && _items.length > items.length) return; // keep the longer list until all is here
        setState(() {
          _items = items;
          _loaded = true;
          _loadingRest = !done;
        });
      },
    );
  }

  TimelineLayout? _layout;
  List<LibraryItem>? _layoutItems;
  int _layoutDay = 0;

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
    final above = pos.maxScrollExtent + pos.viewportDimension - layout.height - 48 - (_loadingRest ? 58 : 0);
    final row = layout.rowAt(pixels + pos.viewportDimension * 0.3 - above);
    return row == null ? '' : monthLabel(row.day);
  }

  Future<void> _open(LibraryItem it) async {
    if (MediaPager.isMedia(it)) {
      await MediaPager.open(context, it, around: _items);
    } else {
      await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => LibraryViewer(itemId: it.id)));
    }
  }

  // ───────────── selection ─────────────

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _moveSelected() async {
    final ids = _sel.ids.toList();
    if (ids.isEmpty) return;
    final changed = await CollectionPicker.show(context, itemIds: ids);
    if (!mounted) return;
    _sel.clear();
    if (changed != null && changed.isNotEmpty) _snack(changed.join(', '));
  }

  Future<void> _shareSelected() async {
    final ids = _sel.ids.toList();
    if (ids.isEmpty) return;
    final made = await ShareFlow.start(context, ids);
    if (made && mounted) _sel.clear();
  }

  Future<void> _starSelected() async {
    final starred = await Stars.toggleMany(_sel.ids.toList());
    if (!mounted) return;
    _sel.clear();
    _snack(starred ? 'Starred' : 'Star removed');
  }

  Future<void> _privateSelected() async {
    final ids = _sel.ids.toList();
    if (ids.isEmpty) return;
    final moved = await PrivateGate.makePrivate(context, ids);
    if (moved && mounted) _sel.clear();
  }

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
      persist: false,
      action: SnackBarAction(label: 'Undo', onPressed: () => _repo.restoreMany(ids)),
    ));
  }

  // ───────────── UI ─────────────

  @override
  Widget build(BuildContext context) {
    final a = widget.album;
    // (The width inside the safe area: a notch at the side when the phone lies down.)
    final layout = _layoutFor(MediaQuery.sizeOf(context).width - MediaQuery.paddingOf(context).horizontal, MediaQuery.textScalerOf(context).scale(1));
    return PopScope(
      // Back, while things are selected, only takes the selection away.
      canPop: !_sel.active,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          _sel.clear();
          return;
        }
        if (mounted && !_leaving) setState(() => _leaving = true);
      },
      child: HeroMode(
        enabled: !_leaving,
        child: Scaffold(
          appBar: _sel.active
              ? selectionAppBar(
                  sel: _sel,
                  allIds: const [], // "Select all" is under ⋮, so "3 selected" has room
                  actions: [
                    IconButton(tooltip: 'Move to a folder', icon: Icon(Icons.drive_file_move_outline, color: ByteColors.accentDim), onPressed: _moveSelected),
                    IconButton(tooltip: 'Share with a link', icon: Icon(Icons.ios_share_rounded, color: ByteColors.accentDim), onPressed: _shareSelected),
                    IconButton(tooltip: 'Move to bin', icon: Icon(Icons.delete_outline, color: ByteColors.danger), onPressed: _deleteSelected),
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
              : AppBar(title: Text(a.title, maxLines: 1, overflow: TextOverflow.ellipsis)),
          body: !_loaded
              ? const SizedBox.shrink()
              : _items.isEmpty
                  ? const EmptyNote('Nothing in this album now.')
                  : FastScroller(
                      controller: _scroll,
                      labelAt: (pixels) => _dateAt(pixels, layout),
                      child: CustomScrollView(
                        controller: _scroll,
                        slivers: [
                          SliverToBoxAdapter(
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(ByteSpace.page, 4, ByteSpace.page, 0),
                              child: Meta(
                                a.onDay != null
                                    ? '${a.count} ${a.count == 1 ? 'photo or video' : 'photos and videos'} you took on this day in earlier years'
                                    : a.isDays
                                        ? '${a.count} photos and videos from these days'
                                        : '${a.count} ${a.count == 1 ? 'thing' : 'things'} · BYTE keeps this album by itself',
                              ),
                            ),
                          ),
                          TimelineSliver(
                            layout: layout,
                            tile: (it) => MediaTile(
                              item: it,
                              selected: _sel.contains(it.id),
                              onLongPress: () => _sel.toggle(it.id),
                              onTap: () => _sel.active ? _sel.toggle(it.id) : _open(it),
                            ),
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
                          const SliverToBoxAdapter(child: SizedBox(height: 48)),
                        ],
                      ),
                    ),
        ),
      ),
    );
  }
}
