import 'package:flutter/material.dart';

import '../../shared/theme.dart';
import 'collections_repo.dart';

/// "Save to…" sheet: tick the playlists / albums an item (or several) should
/// be in, or type a new one. Works for recordings, photos, videos, notes, files.
class CollectionPicker extends StatefulWidget {
  const CollectionPicker({super.key, required this.itemIds, this.title = 'Move to', this.private = false});
  final List<String> itemIds;
  final String title;

  /// Choose among the folders inside the private space.
  final bool private;

  /// Shows the sheet. Returns the names that changed (for a snackbar), or null.
  static Future<List<String>?> show(BuildContext context, {required List<String> itemIds, String title = 'Move to', bool private = false}) {
    return showModalBottomSheet<List<String>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: ByteColors.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => CollectionPicker(itemIds: itemIds, title: title, private: private),
    );
  }

  static IconData iconFor(Collection c) => c.isLater ? Icons.watch_later_outlined : Icons.folder_outlined;

  @override
  State<CollectionPicker> createState() => _CollectionPickerState();
}

class _CollectionPickerState extends State<CollectionPicker> {
  final _repo = CollectionsRepo.instance;
  final _newName = TextEditingController();
  List<Collection> _all = const [];
  final _in = <String>{}; // collection ids that already hold the (first) item
  final _changed = <String>[];
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _newName.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final all = await _repo.list(private: widget.private);
    final mine = widget.itemIds.length == 1 ? await _repo.collectionsOf(widget.itemIds.first) : <String>{};
    if (!mounted) return;
    setState(() {
      _all = all;
      _in
        ..clear()
        ..addAll(mine);
      _loaded = true;
    });
  }

  Future<void> _toggle(Collection c) async {
    final on = _in.contains(c.id);
    if (on && widget.itemIds.length == 1) {
      await _repo.remove(c.id, widget.itemIds.first);
      _in.remove(c.id);
      _changed.add('− ${c.name}');
    } else {
      await _repo.addAll(c.id, widget.itemIds);
      _in.add(c.id);
      _changed.add('+ ${c.name}');
    }
    if (mounted) setState(() {});
  }

  Future<void> _create() async {
    final name = _newName.text.trim();
    if (name.isEmpty) return;
    final c = await _repo.create(name, private: widget.private);
    await _repo.addAll(c.id, widget.itemIds);
    _changed.add('+ ${c.name}');
    _newName.clear();
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final n = widget.itemIds.length;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 16, 20, 16 + MediaQuery.of(context).viewInsets.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(n == 1 ? widget.title : '${widget.title} ($n items)', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text(
            widget.private
                ? 'Tick the private folders this belongs in. One thing can be in several folders.'
                : 'Tick the folders this belongs in. It stays in your Library and in Search; one thing can be in several folders.',
            style: TextStyle(fontSize: 12, color: ByteColors.textDim, height: 1.3),
          ),
          const SizedBox(height: 10),
          if (!_loaded)
            const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator()))
          else
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.45),
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final c in _all)
                    CheckboxListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      value: _in.contains(c.id),
                      onChanged: (_) => _toggle(c),
                      title: Text(c.name),
                      subtitle: Text('${c.count} item${c.count == 1 ? '' : 's'}', style: TextStyle(fontSize: 11, color: ByteColors.textDim)),
                      secondary: Icon(CollectionPicker.iconFor(c), color: _in.contains(c.id) ? ByteColors.accent : ByteColors.textDim),
                    ),
                ],
              ),
            ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _newName,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(hintText: 'New folder name', isDense: true),
                  onSubmitted: (_) => _create(),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.tonal(style: inlineButton, onPressed: _create, child: const Text('Create')),
            ],
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton(onPressed: () => Navigator.pop(context, _changed), child: const Text('Done')),
          ),
        ],
      ),
    );
  }
}
