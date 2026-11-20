import 'package:flutter/material.dart';

import '../../shared/motion.dart';
import '../../shared/selection.dart';
import '../../shared/theme.dart';
import '../../shared/ui.dart';
import '../capture/audio_repo.dart';
import '../notes/notes_repo.dart';
import 'library_item.dart';
import 'library_repo.dart';
import 'library_screen.dart' show LibraryThumb;

/// How many whole days something deleted at [deletedAt] still has in the bin
/// (30 on the day it was deleted, 0 on its last day). Pure, unit-tested.
int binDaysLeft(DateTime deletedAt, {DateTime? now}) {
  final left = 30 - (now ?? DateTime.now()).difference(deletedAt).inDays;
  return left < 0 ? 0 : (left > 30 ? 30 : left);
}

/// The bin: everything you deleted in the last 30 days — photos, files,
/// notes, voice notes. Bring any of it back exactly as it was, or delete it
/// for good. Nothing leaves the bin on its own before its 30 days are up.
class BinScreen extends StatefulWidget {
  const BinScreen({super.key, this.private = false});

  /// The bin of the private space (its deleted things are kept apart).
  final bool private;

  @override
  State<BinScreen> createState() => _BinScreenState();
}

class _BinScreenState extends State<BinScreen> {
  final _repo = LibraryRepo.instance;
  final _sel = Selection();
  List<(LibraryItem, DateTime)> _items = const [];
  bool _loaded = false;
  bool _working = false;

  @override
  void initState() {
    super.initState();
    _repo.revision.addListener(_load);
    _sel.addListener(_onSelection);
    _load();
  }

  @override
  void dispose() {
    _repo.revision.removeListener(_load);
    _sel.dispose();
    super.dispose();
  }

  void _onSelection() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    final items = await _repo.listDeleted(private: widget.private);
    if (!mounted) return;
    setState(() {
      _items = items;
      _loaded = true;
    });
  }

  /// Notes and voice notes have their own lists; tell them something changed.
  void _tellOthers() {
    NotesRepo.instance.revision.value++;
    AudioRepo.instance.revision.value++;
  }

  Future<void> _restore(List<String> ids) async {
    if (ids.isEmpty || _working) return;
    setState(() => _working = true);
    try {
      await _repo.restoreMany(ids);
    } finally {
      if (mounted) setState(() => _working = false);
    }
    _tellOthers();
    if (!mounted) return;
    _sel.clear();
    Haptics.confirm();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(widget.private
        ? (ids.length == 1 ? 'Back in the private space' : '${ids.length} items are back in the private space')
        : (ids.length == 1 ? 'Back in your Library' : '${ids.length} items are back in your Library'))));
  }

  Future<void> _deleteForever(List<String> ids, {bool all = false}) async {
    if (ids.isEmpty || _working) return;
    final n = ids.length;
    final ok = await confirmBulk(
      context,
      title: all ? 'Empty the bin?' : 'Delete $n item${n == 1 ? '' : 's'} for good?',
      body: 'This cannot be undone. ${n == 1 ? 'It is' : 'They are'} removed from this phone, and any copy in Google Drive goes to Drive\'s own Trash. '
          'For photos from your phone\'s gallery, Android asks once whether the originals may go too.',
      action: all ? 'Empty bin' : 'Delete for good',
    );
    if (!ok || !mounted) return;
    setState(() => _working = true);
    try {
      // "Empty" means everything in the bin, also what is beyond the listed 1000.
      await _repo.deleteForeverMany(all ? await _repo.deletedIds(private: widget.private) : ids);
    } finally {
      if (mounted) setState(() => _working = false);
    }
    _tellOthers();
    if (mounted) _sel.clear();
  }

  static String _left(DateTime deletedAt) {
    final d = binDaysLeft(deletedAt);
    return d == 0 ? 'last day' : '$d day${d == 1 ? '' : 's'} left';
  }

  @override
  Widget build(BuildContext context) {
    final ids = [for (final (it, _) in _items) it.id];
    return SelectionBack(
      sel: _sel,
      child: Scaffold(
        appBar: _sel.active
            ? selectionAppBar(
                sel: _sel,
                allIds: ids,
                actions: [
                  IconButton(
                    tooltip: 'Bring back',
                    icon: Icon(Icons.restore_rounded, color: ByteColors.accentDim),
                    onPressed: () => _restore(_sel.ids.toList()),
                  ),
                  IconButton(
                    tooltip: 'Delete for good',
                    icon: Icon(Icons.delete_forever_outlined, color: ByteColors.danger),
                    onPressed: () => _deleteForever(_sel.ids.toList()),
                  ),
                ],
              )
            : AppBar(
                title: Text(widget.private ? 'Private bin' : 'Bin'),
                actions: [
                  if (_items.isNotEmpty)
                    TextButton(
                      style: inlineButton,
                      onPressed: _working ? null : () => _deleteForever(ids, all: true),
                      child: Text('Empty', style: TextStyle(color: ByteColors.danger)),
                    ),
                  const SizedBox(width: 8),
                ],
              ),
        body: !_loaded
            ? const SizedBox.shrink()
            : _items.isEmpty
                ? const EmptyNote('The bin is empty. Things you delete wait here for 30 days, so a slip of the finger never loses anything.')
                : ListView.builder(
                    padding: const EdgeInsets.only(bottom: 32),
                    itemCount: _items.length + 1,
                    itemBuilder: (_, i) {
                      if (i == 0) {
                        return Padding(
                          padding: const EdgeInsets.fromLTRB(ByteSpace.page, 12, ByteSpace.page, 12),
                          child: Text(
                            'Tap Bring back, or long-press to pick several. After 30 days in the bin a thing is deleted for good.',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        );
                      }
                      final (it, at) = _items[i - 1];
                      final selected = _sel.contains(it.id);
                      final kind = it.kind == LibraryKind.audio ? 'Voice note' : it.kind.label.replaceAll(RegExp(r's$'), '');
                      return ByteRow(
                        key: ValueKey(it.id),
                        title: it.displayTitle,
                        subtitle: '$kind · ${_left(at)}',
                        selected: selected,
                        leading: SizedBox(
                          width: 48,
                          height: 48,
                          child: ClipRRect(borderRadius: BorderRadius.circular(ByteSpace.rs), child: LibraryThumb(item: it, fit: BoxFit.cover)),
                        ),
                        trailing: selected
                            ? const SelectedBadge()
                            : _sel.active
                                ? null
                                : TextButton(style: inlineButton, onPressed: _working ? null : () => _restore([it.id]), child: const Text('Bring back')),
                        onLongPress: () => _sel.toggle(it.id),
                        onTap: _sel.active ? () => _sel.toggle(it.id) : null,
                      );
                    },
                  ),
      ),
    );
  }
}
