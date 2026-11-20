import 'dart:io';

import 'package:flutter/material.dart';

import '../../shared/selection.dart';
import '../../shared/theme.dart';
import '../../shared/ui.dart';
import '../capture/audio_repo.dart';
import '../notes/note_editor_screen.dart';
import '../notes/notes_repo.dart';
import 'collection_picker.dart';
import 'collections_repo.dart';
import 'library_item.dart';
import 'library_repo.dart';
import 'library_screen.dart';
import 'library_viewer.dart';
import 'media_pager.dart';
import '../share/share_flow.dart';

/// One folder: a cover, the name, how many things, and
/// the things themselves in the order you added them.
class PlaylistScreen extends StatefulWidget {
  const PlaylistScreen({super.key, required this.collectionId});
  final String collectionId;

  @override
  State<PlaylistScreen> createState() => _PlaylistScreenState();
}

class _PlaylistScreenState extends State<PlaylistScreen> {
  final _repo = CollectionsRepo.instance;
  final _sel = Selection();
  Collection? _c;
  List<LibraryItem> _items = const [];
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _repo.revision.addListener(_load);
    LibraryRepo.instance.revision.addListener(_load);
    NotesRepo.instance.revision.addListener(_load);
    AudioRepo.instance.revision.addListener(_load);
    _sel.addListener(() {
      if (mounted) setState(() {});
    });
    _load();
  }

  @override
  void dispose() {
    _repo.revision.removeListener(_load);
    LibraryRepo.instance.revision.removeListener(_load);
    NotesRepo.instance.revision.removeListener(_load);
    AudioRepo.instance.revision.removeListener(_load);
    _sel.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final all = await _repo.list();
    final c = all.where((x) => x.id == widget.collectionId).firstOrNull;
    final items = c == null ? const <LibraryItem>[] : await _repo.items(c.id);
    if (!mounted) return;
    setState(() {
      _c = c;
      _items = items;
      _loaded = true;
    });
  }

  Future<void> _open(LibraryItem it) async {
    switch (it.kind) {
      case LibraryKind.note:
        final note = await NotesRepo.instance.get(it.id);
        if (note == null || !mounted) return;
        await Navigator.of(context).push(MaterialPageRoute(builder: (_) => NoteEditorScreen(note: note)));
      case LibraryKind.photo || LibraryKind.video:
        await MediaPager.open(context, it, around: _items);
      default:
        await Navigator.of(context).push(MaterialPageRoute(builder: (_) => LibraryViewer(itemId: it.id)));
    }
  }

  Future<void> _removeSelected() async {
    final ids = _sel.ids.toList();
    for (final id in ids) {
      await _repo.remove(widget.collectionId, id);
    }
    _sel.clear();
    if (mounted) _snack('Taken out of this folder (still in your Library).');
  }

  Future<void> _moveSelected() async {
    final ids = _sel.ids.toList();
    if (ids.isEmpty) return;
    final changed = await CollectionPicker.show(context, itemIds: ids);
    if (!mounted) return;
    _sel.clear();
    if (changed != null && changed.isNotEmpty) _snack(changed.join(', '));
  }

  Future<void> _deleteSelected() async {
    final n = _sel.count;
    final ok = await confirmBulk(context, title: 'Move $n item${n == 1 ? '' : 's'} to the bin?', body: 'They stay in the bin for 30 days.', action: 'Move to bin');
    if (!ok) return;
    for (final id in _sel.ids.toList()) {
      final it = _items.where((i) => i.id == id).firstOrNull;
      if (it == null) continue;
      switch (it.kind) {
        case LibraryKind.note:
          await NotesRepo.instance.delete(id);
        case LibraryKind.audio:
          await AudioRepo.instance.delete(id);
        default:
          await LibraryRepo.instance.delete(id);
      }
    }
    _sel.clear();
  }

  Future<void> _menu() async {
    final c = _c;
    if (c == null) return;
    final v = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.ios_share_rounded),
              title: const Text('Share this folder with a link'),
              subtitle: const Text('Copies of what is in it now, in your Google Drive'),
              onTap: () => Navigator.pop(ctx, 'share'),
            ),
            if (!c.isLater) ListTile(leading: const Icon(Icons.edit_outlined), title: const Text('Rename'), onTap: () => Navigator.pop(ctx, 'rename')),
            if (!c.isLater)
              ListTile(
                leading: Icon(Icons.delete_outline, color: ByteColors.danger),
                title: const Text('Delete folder'),
                subtitle: const Text('The things inside stay in your Library'),
                onTap: () => Navigator.pop(ctx, 'delete'),
              ),
            ListTile(leading: const Icon(Icons.close), title: const Text('Cancel'), onTap: () => Navigator.pop(ctx)),
          ],
        ),
      ),
    );
    if (!mounted || v == null) return;
    if (v == 'share') {
      await ShareFlow.start(context, [for (final i in _items) i.id], name: c.name);
      return;
    }
    if (v == 'delete') {
      await _repo.delete(c.id);
      if (mounted) Navigator.of(context).pop();
      return;
    }
    if (v == 'rename') {
      final ctl = TextEditingController(text: c.name);
      final name = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Rename folder'),
          content: TextField(controller: ctl, autofocus: true, textCapitalization: TextCapitalization.words),
          actions: [
            TextButton(style: inlineButton, onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(style: inlineButton, onPressed: () => Navigator.pop(ctx, ctl.text), child: const Text('Save')),
          ],
        ),
      );
      Future<void>.delayed(const Duration(seconds: 1), ctl.dispose);
      if (name != null && name.trim().isNotEmpty) await _repo.rename(c.id, name);
    }
  }

  Future<void> _addItems() async {
    final added = await Navigator.of(context).push<int>(
      MaterialPageRoute(fullscreenDialog: true, builder: (_) => _AddItemsScreen(collectionId: widget.collectionId, already: {for (final i in _items) i.id})),
    );
    if (added != null && added > 0 && mounted) _snack('Added $added ${added == 1 ? 'item' : 'items'}.');
  }

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  @override
  Widget build(BuildContext context) {
    final c = _c;
    final allPictures = _items.isNotEmpty && _items.every((i) => i.kind == LibraryKind.photo || i.kind == LibraryKind.video);
    return SelectionBack(
      sel: _sel,
      child: Scaffold(
        appBar: _sel.active
            ? selectionAppBar(
                sel: _sel,
                allIds: [for (final i in _items) i.id],
                actions: [
                  IconButton(
                    tooltip: 'Share with a link',
                    icon: Icon(Icons.ios_share_rounded, color: ByteColors.accentDim),
                    onPressed: () async {
                      final ids = _sel.ids.toList();
                      final made = await ShareFlow.start(context, ids);
                      if (made && mounted) _sel.clear();
                    },
                  ),
                  IconButton(tooltip: 'Take out of this folder', icon: Icon(Icons.folder_off_outlined, color: ByteColors.accentDim), onPressed: _removeSelected),
                  IconButton(tooltip: 'Move to another folder', icon: Icon(Icons.drive_file_move_outline, color: ByteColors.accentDim), onPressed: _moveSelected),
                  IconButton(tooltip: 'Delete', icon: Icon(Icons.delete_outline, color: ByteColors.danger), onPressed: _deleteSelected),
                ],
              )
            : AppBar(
                title: Text(c?.name ?? 'Folder'),
                actions: [IconButton(tooltip: 'More', icon: const Icon(Icons.more_vert_rounded), onPressed: _menu)],
              ),
        floatingActionButton: _sel.active
            ? null
            : FloatingActionButton.extended(onPressed: _addItems, icon: const Icon(Icons.add_rounded), label: const Text('Add')),
        body: !_loaded
            ? const SizedBox.shrink()
            : c == null
                ? const EmptyNote('This folder is gone.')
                : CustomScrollView(
                    slivers: [
                      SliverToBoxAdapter(child: _Header(c: c, items: _items)),
                      if (_items.isEmpty)
                        const SliverToBoxAdapter(
                          child: EmptyNote('Nothing here yet. Tap Add, or open anything in the Library and choose "Move to".'),
                        )
                      else if (allPictures)
                        SliverPadding(
                          padding: const EdgeInsets.fromLTRB(ByteSpace.page, 12, ByteSpace.page, 96),
                          sliver: SliverGrid(
                            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, mainAxisSpacing: 4, crossAxisSpacing: 4),
                            delegate: SliverChildBuilderDelegate((_, i) {
                              final it = _items[i];
                              final selected = _sel.contains(it.id);
                              return GestureDetector(
                                onLongPress: () => _sel.toggle(it.id),
                                onTap: () => _sel.active ? _sel.toggle(it.id) : _open(it),
                                child: Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    ClipRRect(borderRadius: BorderRadius.circular(8), child: LibraryThumb(item: it, fit: BoxFit.cover)),
                                    if (it.kind == LibraryKind.video) const Positioned(bottom: 6, left: 6, child: Icon(Icons.play_circle_fill_rounded, color: Colors.white, size: 22)),
                                    if (selected)
                                      Container(
                                        decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), border: Border.all(color: ByteColors.accent, width: 2), color: ByteColors.accent.withValues(alpha: 0.18)),
                                        child: const Align(alignment: Alignment.topRight, child: Padding(padding: EdgeInsets.all(6), child: SelectedBadge())),
                                      ),
                                  ],
                                ),
                              );
                            }, childCount: _items.length),
                          ),
                        )
                      else ...[
                        SliverToBoxAdapter(child: Container(height: 1, margin: const EdgeInsets.only(top: 12), color: ByteColors.border)),
                        SliverList.builder(
                          itemCount: _items.length,
                          itemBuilder: (_, i) {
                            final it = _items[i];
                            return LibraryRow(
                              item: it,
                              query: '',
                              index: i + 1,
                              selected: _sel.contains(it.id),
                              onLongPress: () => _sel.toggle(it.id),
                              onTap: () => _sel.active ? _sel.toggle(it.id) : _open(it),
                            );
                          },
                        ),
                        const SliverToBoxAdapter(child: SizedBox(height: 96)),
                      ],
                    ],
                  ),
      ),
    );
  }
}

/// The playlist header: a cover, the name and how many things are inside.
class _Header extends StatelessWidget {
  const _Header({required this.c, required this.items});
  final Collection c;
  final List<LibraryItem> items;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final covers = items.where((i) => i.thumb.isNotEmpty || (i.kind == LibraryKind.photo && i.path.isNotEmpty && File(i.path).existsSync())).take(1).toList();
    return Padding(
      padding: const EdgeInsets.fromLTRB(ByteSpace.page, 8, ByteSpace.page, 0),
      child: Row(
        children: [
          SizedBox(
            width: 96,
            height: 72,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: covers.isEmpty
                  ? Container(
                      color: ByteColors.surface2,
                      alignment: Alignment.center,
                      child: Icon(CollectionPicker.iconFor(c), color: ByteColors.textFaint, size: 30),
                    )
                  : LibraryThumb(item: covers.first, fit: BoxFit.cover),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(c.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: tt.titleLarge?.copyWith(fontSize: 18)),
                const SizedBox(height: 4),
                Text(
                  [
                    '${items.length} ${items.length == 1 ? 'item' : 'items'}',
                    if (c.updatedAt != null) 'updated ${agoText(c.updatedAt!)}',
                  ].join(' · '),
                  style: tt.bodySmall,
                ),
                if (c.isLater) Text('Things you bookmarked to come back to.', style: tt.bodySmall),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Pick things from the whole Library to put into this playlist.
class _AddItemsScreen extends StatefulWidget {
  const _AddItemsScreen({required this.collectionId, required this.already});
  final String collectionId;
  final Set<String> already;

  @override
  State<_AddItemsScreen> createState() => _AddItemsScreenState();
}

class _AddItemsScreenState extends State<_AddItemsScreen> {
  final _search = TextEditingController();
  List<LibraryItem> _items = const [];
  final _picked = <String>{};
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _search.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final all = await LibraryRepo.instance.list(query: _search.text);
    if (!mounted) return;
    setState(() {
      _items = all.where((i) => !widget.already.contains(i.id)).toList();
      _loaded = true;
    });
  }

  Future<void> _done() async {
    await CollectionsRepo.instance.addAll(widget.collectionId, _picked);
    if (mounted) Navigator.of(context).pop(_picked.length);
  }

  void _toggle(String id) => setState(() => _picked.contains(id) ? _picked.remove(id) : _picked.add(id));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Add to this folder'),
        actions: [
          TextButton(
            style: inlineButton,
            onPressed: _picked.isEmpty ? null : _done,
            child: Text(_picked.isEmpty ? 'Add' : 'Add ${_picked.length}'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          QuietSearch(controller: _search, hint: 'Search your Library'),
          const SizedBox(height: 12),
          Expanded(
            child: !_loaded
                ? const SizedBox.shrink()
                : _items.isEmpty
                    ? const EmptyNote('Nothing to add.')
                    : ListView.builder(
                        padding: const EdgeInsets.only(bottom: 24),
                        itemCount: _items.length + 1,
                        itemBuilder: (_, i) {
                          if (i == 0) return Container(height: 1, color: ByteColors.border);
                          final it = _items[i - 1];
                          return LibraryRow(
                            item: it,
                            query: _search.text,
                            selected: _picked.contains(it.id),
                            onTap: () => _toggle(it.id),
                            onLongPress: () => _toggle(it.id),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}
