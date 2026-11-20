import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/private_space.dart';
import '../../shared/motion.dart';
import '../../shared/selection.dart';
import '../../shared/theme.dart';
import '../../shared/ui.dart';
import '../library/bin_screen.dart';
import '../library/collection_picker.dart';
import '../library/collections_repo.dart';
import '../library/library_item.dart';
import '../library/library_repo.dart';
import '../notes/checklist_view.dart';
import '../notes/note_editor_screen.dart';
import '../notes/notes_repo.dart';
import 'private_gate.dart';
import 'private_viewer.dart';

/// The private space: what you put here shows nowhere else in BYTE. It is
/// opened with its own PIN ([PrivateGate]) and closes when you leave it or
/// leave BYTE.
class PrivateScreen extends StatefulWidget {
  const PrivateScreen({super.key});

  /// Opens the private space (asking for the PIN first).
  static Future<void> open(BuildContext context) async {
    final nav = Navigator.of(context);
    if (!await PrivateGate.ensure(context)) return;
    await nav.push(MaterialPageRoute<void>(settings: const RouteSettings(name: routeName), builder: (_) => const PrivateScreen()));
  }

  static const routeName = 'private-space';

  @override
  State<PrivateScreen> createState() => _PrivateScreenState();
}

class _PrivateScreenState extends State<PrivateScreen> {
  final _repo = LibraryRepo.instance;
  final _search = TextEditingController();
  final _sel = Selection();
  Timer? _debounce;

  List<LibraryItem> _items = const [];
  List<Collection> _folders = const [];
  String? _folder; // a private folder's id; null = everything
  bool _loaded = false;
  bool _busy = false;
  String _busyText = '';
  int _seq = 0;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    PrivateSpace.setSecure(true);
    PrivateSpace.unlocked.addListener(_onLock);
    // Locked in the moment this screen was opening: it closes again.
    if (!PrivateSpace.unlocked.value) WidgetsBinding.instance.addPostFrameCallback((_) => _onLock());
    PrivateSpace.changed.addListener(_load);
    _repo.revision.addListener(_load);
    NotesRepo.instance.revision.addListener(_load);
    CollectionsRepo.instance.revision.addListener(_load);
    _sel.addListener(_onSelection);
    _search.addListener(_onSearch);
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    PrivateSpace.unlocked.removeListener(_onLock);
    PrivateSpace.changed.removeListener(_load);
    _repo.revision.removeListener(_load);
    NotesRepo.instance.revision.removeListener(_load);
    CollectionsRepo.instance.revision.removeListener(_load);
    _sel.dispose();
    _search.dispose();
    // Leaving the private space closes it. (Screenshots stay blocked until
    // the closing animation is over.)
    PrivateSpace.lock();
    Future<void>.delayed(const Duration(milliseconds: 500), () {
      if (!PrivateSpace.unlocked.value) PrivateSpace.setSecure(false);
    });
    super.dispose();
  }

  void _onSelection() {
    if (mounted) setState(() {});
  }

  void _onSearch() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), _load);
  }

  /// The space was locked (BYTE went to the background): this screen and
  /// everything opened from it go away.
  void _onLock() {
    if (PrivateSpace.unlocked.value || _closing || !mounted) return;
    _closing = true;
    final nav = Navigator.of(context);
    // Everything above this screen, then this screen itself.
    nav.popUntil((r) => r.settings.name == PrivateScreen.routeName || r.isFirst);
    if (ModalRoute.of(context)?.isCurrent ?? false) nav.pop();
  }

  Future<void> _load() async {
    if (!PrivateSpace.unlocked.value) return;
    final seq = ++_seq;
    try {
      final folders = await CollectionsRepo.instance.list(private: true);
      final folder = folders.any((c) => c.id == _folder) ? _folder : null;
      final items = await _repo.list(private: true, query: _search.text, folderId: folder, withText: false, limit: 3000);
      if (!mounted || seq != _seq) return;
      setState(() {
        _folders = folders;
        _folder = folder;
        _items = items;
        _loaded = true;
      });
    } catch (e) {
      debugPrint('[private] load: $e');
      if (mounted && seq == _seq) setState(() => _loaded = true);
    }
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
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
              subtitle: const Text('BYTE takes a private copy; delete the original from your gallery afterwards'),
              onTap: () => Navigator.pop(ctx, 'media'),
            ),
            ListTile(
              leading: Icon(Icons.insert_drive_file_outlined, color: ByteColors.accentDim),
              title: const Text('Any file'),
              subtitle: const Text('PDF, Word, Excel, anything'),
              onTap: () => Navigator.pop(ctx, 'file'),
            ),
            ListTile(
              leading: Icon(Icons.edit_note_rounded, color: ByteColors.accentDim),
              title: const Text('Private note'),
              onTap: () => Navigator.pop(ctx, 'note'),
            ),
            ListTile(
              leading: Icon(Icons.checklist_rounded, color: ByteColors.accentDim),
              title: const Text('Private checklist'),
              onTap: () => Navigator.pop(ctx, 'checklist'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    if (choice == 'note' || choice == 'checklist') {
      await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => NoteEditorScreen(private: true, checklist: choice == 'checklist')));
      return;
    }
    // The picker covers BYTE for a moment: the space stays open for that.
    PrivateSpace.hold();
    var picked = <(String, String)>[];
    try {
      if (choice == 'media') {
        final files = await ImagePicker().pickMultipleMedia();
        picked = [for (final f in files) (f.path, f.name)];
      } else {
        final files = await FilePicker.pickFiles();
        picked = [
          for (final f in files)
            if (f.path != null) (f.path!, f.name),
        ];
      }
    } catch (e) {
      _snack('Could not open the picker: $e');
    } finally {
      PrivateSpace.release();
    }
    if (picked.isEmpty || !mounted) return;
    if (!PrivateSpace.unlocked.value) return; // locked while you were away
    setState(() {
      _busy = true;
      _busyText = 'Adding…';
    });
    var n = 0;
    try {
      for (final (path, name) in picked) {
        if (mounted) setState(() => _busyText = 'Adding ${n + 1} of ${picked.length}…');
        // (Moved, not copied: the picker's own plain copy must not stay behind.)
        final it = await _repo.importFile(path, displayName: name, private: true, move: true);
        if (_folder != null) await CollectionsRepo.instance.add(_folder!, it.id);
        n++;
      }
    } catch (e) {
      _snack('Could not add everything: $e');
    }
    if (mounted) {
      setState(() {
        _busy = false;
        _busyText = '';
      });
    }
    if (n > 0) {
      _snack('Added $n ${n == 1 ? 'item' : 'items'}. BYTE reads ${n == 1 ? 'it' : 'them'} first (so you can search inside), then locks ${n == 1 ? 'it' : 'them'}.');
    }
    // What the reader has finished with is locked now; the rest follows by itself.
    unawaited(PrivateSpace.sealPending());
  }

  // ───────────── folders ─────────────

  Future<void> _newFolder() async {
    final name = await ChecklistView.askLine(context, title: 'New private folder', action: 'Create');
    if (name == null) return;
    final c = await CollectionsRepo.instance.create(name, private: true);
    if (mounted) setState(() => _folder = c.id);
    _load();
  }

  Future<void> _folderMenu(Collection c) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(leading: const Icon(Icons.edit_outlined), title: const Text('Rename'), onTap: () => Navigator.pop(ctx, 'rename')),
            ListTile(
              leading: Icon(Icons.folder_off_outlined, color: ByteColors.danger),
              title: Text('Remove this folder', style: TextStyle(color: ByteColors.danger)),
              subtitle: const Text('What is in it stays in the private space'),
              onTap: () => Navigator.pop(ctx, 'delete'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    if (choice == 'rename') {
      final name = await ChecklistView.askLine(context, title: 'Rename folder', initial: c.name);
      if (name != null) await CollectionsRepo.instance.rename(c.id, name);
    } else {
      await CollectionsRepo.instance.delete(c.id);
      if (mounted && _folder == c.id) setState(() => _folder = null);
    }
    _load();
  }

  // ───────────── selection actions ─────────────

  Future<void> _fileSelected() async {
    final ids = _sel.ids.toList();
    if (ids.isEmpty) return;
    await CollectionPicker.show(context, itemIds: ids, title: 'Private folder', private: true);
    if (mounted) _sel.clear();
    _load();
  }

  Future<void> _moveOutSelected() async {
    final ids = _sel.ids.toList();
    if (ids.isEmpty || _busy) return;
    final n = ids.length;
    final ok = await confirmBulk(
      context,
      title: 'Take $n item${n == 1 ? '' : 's'} out of the private space?',
      body: '${n == 1 ? 'It goes' : 'They go'} back to your Library: shown there, found by Search, and stored in Google Drive like everything else.',
      action: 'Take out',
    );
    if (!ok || !mounted) return;
    setState(() {
      _busy = true;
      _busyText = 'Unlocking…';
    });
    final r = await PrivateSpace.moveOut(ids);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _busyText = '';
    });
    _sel.clear();
    _snack(r.failed == 0
        ? '${r.moved} item${r.moved == 1 ? ' is' : 's are'} back in your Library.'
        : '${r.moved} moved. ${r.failed} could not be unlocked right now. If ${r.failed == 1 ? 'it lives' : 'they live'} in Google Drive, the internet is needed. Try again in a moment.');
    _load();
  }

  Future<void> _deleteSelected() async {
    final ids = _sel.ids.toList();
    if (ids.isEmpty) return;
    final n = ids.length;
    final ok = await confirmBulk(
      context,
      title: 'Move $n item${n == 1 ? '' : 's'} to the private bin?',
      body: '${n == 1 ? 'It stays' : 'They stay'} there for 30 days. The private bin is in this screen\'s menu.',
      action: 'Move to bin',
    );
    if (!ok || !mounted) return;
    await _repo.deleteMany(ids);
    if (!mounted) return;
    _sel.clear();
    Haptics.confirm();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('Moved $n item${n == 1 ? '' : 's'} to the private bin'),
      duration: const Duration(seconds: 6),
      persist: false,
      action: SnackBarAction(label: 'Undo', onPressed: () => _repo.restoreMany(ids)),
    ));
  }

  Future<void> _open(LibraryItem it) async {
    if (it.kind == LibraryKind.note) {
      final note = await NotesRepo.instance.get(it.id);
      if (note == null || !mounted) return;
      await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => NoteEditorScreen(note: note, private: true)));
      return;
    }
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => PrivateViewer(item: it)));
  }

  Future<void> _menu(String v) async {
    switch (v) {
      case 'folder':
        await _newFolder();
      case 'bin':
        await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const BinScreen(private: true)));
      case 'pin':
        final changed = await PrivateGate.changePin(context);
        if (changed) _snack('The private PIN was changed.');
      case 'lock':
        Navigator.of(context).pop(); // dispose locks it
    }
  }

  // ───────────── UI ─────────────

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final selecting = _sel.active;
    final searching = _search.text.trim().isNotEmpty;
    return SelectionBack(
      sel: _sel,
      child: Scaffold(
        appBar: selecting
            ? selectionAppBar(
                sel: _sel,
                allIds: [for (final i in _items) i.id],
                actions: [
                  IconButton(tooltip: 'Put in a private folder', icon: const Icon(Icons.folder_outlined), onPressed: _fileSelected),
                  IconButton(tooltip: 'Take out of the private space', icon: const Icon(Icons.lock_open_rounded), onPressed: _moveOutSelected),
                  IconButton(tooltip: 'Move to the private bin', icon: Icon(Icons.delete_outline, color: ByteColors.danger), onPressed: _deleteSelected),
                ],
              )
            : AppBar(
                title: const Text('Private'),
                actions: [
                  IconButton(tooltip: 'Lock and close', icon: const Icon(Icons.lock_outline_rounded), onPressed: () => Navigator.of(context).pop()),
                  PopupMenuButton<String>(
                    tooltip: 'More',
                    onSelected: _menu,
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'folder', child: Text('New private folder')),
                      PopupMenuItem(value: 'bin', child: Text('Private bin')),
                      PopupMenuItem(value: 'pin', child: Text('Change the PIN')),
                      PopupMenuItem(value: 'lock', child: Text('Lock and close')),
                    ],
                  ),
                ],
              ),
        floatingActionButton: selecting || _busy
            ? null
            : FloatingActionButton(
                heroTag: 'private-fab',
                tooltip: 'Add to the private space',
                onPressed: _addSheet,
                child: const Icon(Icons.add_rounded),
              ),
        body: !_loaded
            ? const SizedBox.shrink()
            : CustomScrollView(
                slivers: [
                  SliverToBoxAdapter(child: QuietSearch(controller: _search, hint: 'Search the private space')),
                  if (_folders.isNotEmpty)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: ChipRow(
                          children: [
                            Pill('All', selected: _folder == null, onTap: () {
                              setState(() => _folder = null);
                              _load();
                            }),
                            for (final c in _folders)
                              GestureDetector(
                                onLongPress: () => _folderMenu(c),
                                child: Pill(c.name, count: c.count, selected: _folder == c.id, onTap: () {
                                  setState(() => _folder = c.id);
                                  _load();
                                }),
                              ),
                          ],
                        ),
                      ),
                    ),
                  if (_busy)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(ByteSpace.page, 12, ByteSpace.page, 0),
                        child: Row(
                          children: [
                            const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                            const SizedBox(width: 10),
                            Expanded(child: Text(_busyText, style: tt.bodySmall)),
                          ],
                        ),
                      ),
                    ),
                  if (_items.isEmpty)
                    SliverToBoxAdapter(
                      child: EmptyNote(
                        searching
                            ? 'Nothing in the private space matches that.'
                            : _folder != null
                                ? 'This private folder is empty. Select things in the private space and tap the folder button to put them here.'
                                : 'Nothing here yet. Add with +, or select things in your Library and choose "Make private".',
                        action: searching ? null : 'Add something',
                        onAction: _addSheet,
                      ),
                    )
                  else
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(ByteSpace.page, 14, ByteSpace.page, 96),
                      sliver: SliverGrid(
                        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, mainAxisSpacing: 6, crossAxisSpacing: 6),
                        delegate: SliverChildBuilderDelegate(
                          (_, i) {
                            final it = _items[i];
                            return _Tile(
                              key: ValueKey(it.id),
                              item: it,
                              selected: _sel.contains(it.id),
                              onTap: () => selecting ? _sel.toggle(it.id) : _open(it),
                              onLongPress: () => _sel.toggle(it.id),
                            );
                          },
                          childCount: _items.length,
                        ),
                      ),
                    ),
                ],
              ),
      ),
    );
  }
}

/// One private item in the grid: its picture when it has one, else an icon
/// and its name.
class _Tile extends StatelessWidget {
  const _Tile({super.key, required this.item, required this.selected, required this.onTap, required this.onLongPress});

  final LibraryItem item;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final it = item;
    final picture = it.kind == LibraryKind.photo || it.kind == LibraryKind.video;
    return Pressable(
      onTap: onTap,
      onLongPress: onLongPress,
      pressedScale: 0.97,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(ByteSpace.rs),
        child: Stack(
          fit: StackFit.expand,
          children: [
            PrivateThumb(item: it),
            if (!picture)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  padding: const EdgeInsets.fromLTRB(6, 14, 6, 5),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.black.withValues(alpha: 0), Colors.black.withValues(alpha: 0.55)],
                    ),
                  ),
                  child: Text(
                    it.displayTitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: tt.labelSmall?.copyWith(color: Colors.white, height: 1.15),
                  ),
                ),
              ),
            if (it.kind == LibraryKind.video)
              const Positioned(left: 6, bottom: 6, child: Icon(Icons.play_arrow_rounded, color: Colors.white, size: 18)),
            if (selected) ...[
              Positioned.fill(child: Container(color: ByteColors.accent.withValues(alpha: 0.28))),
              const Positioned(top: 6, right: 6, child: SelectedBadge()),
            ],
          ],
        ),
      ),
    );
  }
}

/// The preview of a private item. A locked preview is opened in memory
/// only; nothing readable is written to the phone for it.
class PrivateThumb extends StatefulWidget {
  const PrivateThumb({super.key, required this.item, this.fit = BoxFit.cover});

  final LibraryItem item;
  final BoxFit fit;

  @override
  State<PrivateThumb> createState() => _PrivateThumbState();
}

class _PrivateThumbState extends State<PrivateThumb> {
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _open();
  }

  @override
  void didUpdateWidget(covariant PrivateThumb old) {
    super.didUpdateWidget(old);
    if (old.item.thumb != widget.item.thumb) {
      _bytes = null;
      _open();
    }
  }

  Future<void> _open() async {
    final it = widget.item;
    if (!it.thumbSealed) return;
    final b = await PrivateSpace.thumbBytes(it);
    if (mounted && b != null && widget.item.thumb == it.thumb) setState(() => _bytes = b);
  }

  @override
  Widget build(BuildContext context) {
    final it = widget.item;
    final b = _bytes;
    if (b != null) {
      return Image.memory(b, fit: widget.fit, cacheWidth: 480, gaplessPlayback: true, errorBuilder: (_, _, _) => _icon(it));
    }
    // Not locked yet (BYTE is still reading it): the preview, if there is one
    // already, is an ordinary file.
    if (it.thumb.isNotEmpty && !it.thumbSealed && File(it.thumb).existsSync()) {
      return Image.file(File(it.thumb), fit: widget.fit, cacheWidth: 480, errorBuilder: (_, _, _) => _icon(it));
    }
    return _icon(it);
  }

  static Widget _icon(LibraryItem it) {
    final icon = switch (it.kind) {
      LibraryKind.photo => Icons.image_outlined,
      LibraryKind.video => Icons.videocam_outlined,
      LibraryKind.doc => it.ext == 'pdf' ? Icons.picture_as_pdf_outlined : Icons.insert_drive_file_outlined,
      LibraryKind.link => Icons.link_rounded,
      LibraryKind.audio => Icons.mic_rounded,
      LibraryKind.note => Icons.notes_rounded,
    };
    return Container(
      color: ByteColors.surface2,
      alignment: Alignment.center,
      child: Icon(icon, color: ByteColors.textDim, size: 26),
    );
  }
}
