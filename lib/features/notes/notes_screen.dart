import 'package:flutter/material.dart';

import '../../core/stars.dart';
import '../../shared/motion.dart';
import '../../shared/selection.dart';
import '../../shared/theme.dart';
import '../../shared/ui.dart';
import 'checklist.dart';
import 'note.dart';
import 'note_editor_screen.dart';
import 'notes_import.dart';
import 'notes_repo.dart';
import 'repeats.dart';

/// Notes — the second tab. One search box, a line of tag chips, then your
/// notes grouped by the day you last touched them. Long-press to select.
class NotesScreen extends StatefulWidget {
  const NotesScreen({super.key});

  @override
  State<NotesScreen> createState() => _NotesScreenState();
}

class _NotesScreenState extends State<NotesScreen> {
  final _search = TextEditingController();
  final _sel = Selection();
  List<Note> _notes = const [];

  /// The lists that start again by themselves: note id → 'daily' | 'weekly'.
  Map<String, String> _repeats = const {};
  String? _tag;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _search.addListener(_reload);
    NotesRepo.instance.revision.addListener(_reload);
    _sel.addListener(() {
      if (mounted) setState(() {});
    });
    _reload();
  }

  @override
  void dispose() {
    NotesRepo.instance.revision.removeListener(_reload);
    _search.dispose();
    _sel.dispose();
    super.dispose();
  }

  Future<void> _deleteSelected() async {
    final n = _sel.count;
    final ok = await confirmBulk(
      context,
      title: 'Move $n note${n == 1 ? '' : 's'} to the bin?',
      body: '${n == 1 ? 'It stays' : 'They stay'} in the bin for 30 days. Bring ${n == 1 ? 'it' : 'them'} back from Folders, then Bin.',
      action: 'Move to bin',
    );
    if (!ok) return;
    for (final id in _sel.ids.toList()) {
      await NotesRepo.instance.delete(id);
    }
    _sel.clear();
    _reload();
  }

  Future<void> _pinSelected() async {
    final ids = _sel.ids.toList();
    final pinned = await Stars.toggleMany(ids);
    _sel.clear();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(pinned ? 'Starred' : 'Star removed'),
    ));
  }

  Future<void> _reload() async {
    final notes = await NotesRepo.instance.list(query: _search.text);
    final repeats = await Repeats.all();
    if (!mounted) return;
    setState(() {
      _notes = notes;
      _repeats = repeats;
      _loading = false;
      // A tag chip that no longer exists falls back to All.
      if (_tag != null && !notes.any((n) => n.tags.contains(_tag))) _tag = null;
    });
  }

  Future<void> _openEditor([Note? note, bool checklist = false]) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => NoteEditorScreen(note: note, checklist: checklist)),
    );
    _reload();
  }

  /// The + button: a note, or a checklist.
  Future<void> _addSheet() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(Icons.sticky_note_2_outlined, color: ByteColors.accentDim),
              title: const Text('Note'),
              subtitle: const Text('Write, or speak'),
              onTap: () => Navigator.pop(ctx, 'note'),
            ),
            ListTile(
              leading: Icon(Icons.checklist_rounded, color: ByteColors.accentDim),
              title: const Text('Checklist'),
              subtitle: const Text('Things to do. Tick them from your notifications'),
              onTap: () => Navigator.pop(ctx, 'checklist'),
            ),
            ListTile(
              leading: Icon(Icons.repeat_rounded, color: ByteColors.accentDim),
              title: const Text('Routine'),
              subtitle: const Text('A list that starts again by itself: daily habits, the grocery list, a week plan'),
              onTap: () => Navigator.pop(ctx, 'routine'),
            ),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    if (choice == 'routine') {
      await _newRoutine();
      return;
    }
    await _openEditor(null, choice == 'checklist');
  }

  /// "Routine": which kind, then the new list opens, ready for its items.
  Future<void> _newRoutine() async {
    final start = await showModalBottomSheet<(String, String, String, String, String)>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(
              title: Text('A list that starts again by itself'),
              subtitle: Text('The items stay; only the ticks start again. You can change it any time, and give any item a reminder.'),
            ),
            for (final s in Repeats.starts)
              ListTile(
                leading: Icon(Icons.repeat_rounded, color: ByteColors.accentDim),
                title: Text(s.$1),
                subtitle: Text(s.$2),
                onTap: () => Navigator.pop(ctx, s),
              ),
          ],
        ),
      ),
    );
    if (start == null || !mounted) return;
    final note = await Repeats.make(start);
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => NoteEditorScreen(note: note, checklist: true)));
    _reload();
  }

  // ───────────── grouping ─────────────

  /// Tags by how often they are used, most used first.
  List<String> get _tags {
    final count = <String, int>{};
    for (final n in _notes) {
      for (final t in n.tags) {
        count[t] = (count[t] ?? 0) + 1;
      }
    }
    final tags = count.keys.toList()..sort((a, b) => count[b]!.compareTo(count[a]!));
    return tags.take(8).toList();
  }

  List<Note> get _visible => _tag == null ? _notes : _notes.where((n) => n.tags.contains(_tag)).toList();

  static String _dayLabel(DateTime t) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(t.year, t.month, t.day);
    final diff = today.difference(day).inDays;
    if (diff == 0) return 'Today';
    if (diff == 1) return 'Yesterday';
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final year = t.year == now.year ? '' : ' ${t.year}';
    return '${days[t.weekday - 1]} ${t.day} ${months[t.month - 1]}$year';
  }

  /// "now", "12 min", "3 h" for today's notes; nothing for older ones (the
  /// section label already says the day).
  static String? _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inDays >= 1 || d.isNegative) return null;
    if (d.inMinutes < 1) return 'now';
    if (d.inHours < 1) return '${d.inMinutes} min';
    return '${d.inHours} h';
  }

  /// What the row says under the title: time, tags, then the rest of the body.
  String _caption(Note n) {
    // When the title is blank the first body line is already the title.
    final preview = notePreview(n.body, skipFirst: n.title.trim().isEmpty);
    return [
      TimeOfDay.fromDateTime(n.updatedAt).format(context),
      ...n.tags.take(2),
      preview.isEmpty ? 'typed' : preview,
    ].join(' · ');
  }

  // ───────────── UI ─────────────

  @override
  Widget build(BuildContext context) {
    final visible = _visible;
    final tags = _tags;
    final searching = _search.text.trim().isNotEmpty;
    // Pushed from a Space it needs a back arrow; as a tab it gets the page title.
    final pushed = ModalRoute.of(context)?.canPop ?? false;

    final body = <Widget>[];
    if (!_sel.active && !pushed) {
      body.add(PageTitle(
        'Notes',
        trailing: Pressable(
          onTap: () => NotesImport.start(context),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 6, 0, 6),
            child: Icon(Icons.download_rounded, color: ByteColors.textDim, semanticLabel: 'Import notes'),
          ),
        ),
      ));
    }
    body.add(QuietSearch(controller: _search, hint: 'Search notes'));
    if (tags.isNotEmpty) {
      body.add(const SizedBox(height: 6));
      body.add(ChipRow(
        children: [
          Pill('All', selected: _tag == null, onTap: () => setState(() => _tag = null)),
          for (final t in tags) Pill(t, selected: _tag == t, onTap: () => setState(() => _tag = t)),
        ],
      ));
    }
    if (!_loading) {
      if (visible.isEmpty) {
        body.add(EmptyNote(
          searching
              ? 'Nothing matches that. Try another word.'
              : _tag != null
                  ? 'No notes tagged "$_tag".'
                  : 'Nothing here yet. Write a note, or make a checklist of things to do.',
          action: searching || _tag != null ? null : 'New note',
          onAction: () => _openEditor(),
          second: 'New checklist',
          onSecond: () => _openEditor(null, true),
        ));
        if (!searching && _tag == null) {
          body.add(Padding(
            padding: const EdgeInsets.symmetric(horizontal: ByteSpace.page),
            child: TextButton(onPressed: () => NotesImport.start(context), child: const Text('Import notes from another app')),
          ));
        }
      } else {
        // Routines first, in one place: they are opened again and again, and
        // would otherwise wander down the list with the days.
        final apart = _search.text.trim().isEmpty && _tag == null;
        final routines = apart ? [for (final n in visible) if (_repeats.containsKey(n.id)) n] : const <Note>[];
        if (routines.isNotEmpty) {
          body.add(const SectionLabel('Routines · they start again by themselves', top: 20));
          body.add(Container(height: 1, color: ByteColors.border));
          for (final n in routines) {
            final selected = _sel.contains(n.id);
            final preview = notePreview(n.body, skipFirst: n.title.trim().isEmpty);
            body.add(ByteRow(
              icon: Icons.repeat_rounded,
              title: n.displayTitle,
              subtitle: '${_repeats[n.id] == Repeats.daily ? 'Every day' : 'Every week'}${preview.isEmpty ? '' : ' · $preview'}',
              selected: selected,
              trailing: selected ? const SelectedBadge() : null,
              onLongPress: () => _sel.toggle(n.id),
              // (A routine opens as a list even while it has no items yet.)
              onTap: () => _sel.active ? _sel.toggle(n.id) : _openEditor(n, true),
            ));
          }
        }
        String? day;
        for (final n in visible) {
          if (apart && _repeats.containsKey(n.id)) continue; // shown above
          final label = _dayLabel(n.updatedAt);
          if (label != day) {
            body.add(SectionLabel(label, top: day == null ? 20 : 28));
            body.add(Container(height: 1, color: ByteColors.border));
            day = label;
          }
          final selected = _sel.contains(n.id);
          final ago = _ago(n.updatedAt);
          body.add(ByteRow(
            title: n.displayTitle,
            subtitle: _caption(n),
            selected: selected,
            trailing: selected ? const SelectedBadge() : (ago == null ? null : Meta(ago)),
            onLongPress: () => _sel.toggle(n.id),
            onTap: () => _sel.active ? _sel.toggle(n.id) : _openEditor(n),
          ));
        }
      }
    }

    return SelectionBack(
      sel: _sel,
      child: Scaffold(
        appBar: _sel.active
            ? selectionAppBar(
                sel: _sel,
                allIds: [for (final n in visible) n.id],
                actions: [
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
            : pushed
                ? AppBar(
                    title: const Text('Notes'),
                    actions: [IconButton(tooltip: 'Import notes', icon: const Icon(Icons.download_rounded), onPressed: () => NotesImport.start(context))],
                  )
                : null,
        floatingActionButton: _sel.active
            ? null
            : FloatingActionButton(
                // Notes and Library both live in Home's IndexedStack, so both FABs
                // exist at once; the default (shared) hero tag would throw on push.
                heroTag: 'notes-fab',
                tooltip: 'New note or checklist',
                onPressed: _addSheet,
                child: const Icon(Icons.add_rounded),
              ),
        body: SafeArea(
          bottom: false,
          child: ListView.builder(
            padding: const EdgeInsets.only(bottom: 96),
            itemCount: body.length,
            itemBuilder: (_, i) => body[i],
          ),
        ),
      ),
    );
  }
}
