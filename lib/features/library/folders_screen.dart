import 'package:flutter/material.dart';

import '../../core/private_space.dart';
import '../../shared/theme.dart';
import '../../shared/ui.dart';
import '../capture/audio_repo.dart';
import '../capture/capture_screen.dart';
import '../friends/friends_screen.dart';
import '../librarian/activity_screen.dart';
import '../librarian/tidy_screen.dart';
import '../notes/notes_repo.dart';
import '../notes/notes_screen.dart';
import '../private/private_screen.dart';
import '../wallet/wallet_screen.dart';
import 'bin_screen.dart';
import 'collection_picker.dart';
import 'collections_repo.dart';
import 'library_item.dart';
import 'library_repo.dart';
import 'library_screen.dart' show FolderCard, NewFolderCard;
import 'playlist_screen.dart';

/// The third tab: your folders as cards, then the places that are always
/// there — Notes, Voice notes, the private space and the Bin.
class FoldersScreen extends StatefulWidget {
  const FoldersScreen({super.key});

  @override
  State<FoldersScreen> createState() => _FoldersScreenState();
}

class _FoldersScreenState extends State<FoldersScreen> {
  final _repo = CollectionsRepo.instance;
  List<Collection> _folders = const [];
  Map<String, List<LibraryItem>> _covers = const {};
  int _notes = 0;
  int _voice = 0;
  int _bin = 0;
  int _private = 0;
  bool _privateSetUp = false;
  bool _loaded = false;
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    _repo.revision.addListener(_load);
    LibraryRepo.instance.revision.addListener(_load);
    NotesRepo.instance.revision.addListener(_load);
    AudioRepo.instance.revision.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    _repo.revision.removeListener(_load);
    LibraryRepo.instance.revision.removeListener(_load);
    NotesRepo.instance.revision.removeListener(_load);
    AudioRepo.instance.revision.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final seq = ++_seq;
    final all = await _repo.list();
    // The built-in "Watch later" only takes a card once something is in it.
    final folders = all.where((c) => !(c.isLater && c.count == 0)).toList();
    final covers = <String, List<LibraryItem>>{};
    for (final c in folders) {
      if (c.count > 0) covers[c.id] = await _repo.covers(c.id);
    }
    final counts = await LibraryRepo.instance.counts();
    final voice = await LibraryRepo.instance.voiceNoteCount();
    final bin = await LibraryRepo.instance.deletedCount();
    final private = await PrivateSpace.count();
    final privateSetUp = await PrivateSpace.isSetUp();
    if (!mounted || seq != _seq) return;
    setState(() {
      _private = private;
      _privateSetUp = privateSetUp;
      _folders = folders;
      _covers = covers;
      _notes = counts[LibraryKind.note] ?? 0;
      _voice = voice;
      _bin = bin;
      _loaded = true;
    });
  }

  void _push(Widget page) {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
  }

  Future<void> _newFolder() async {
    final ctl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New folder'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(hintText: 'College, Bills, Trips…'),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(style: inlineButton, onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(style: inlineButton, onPressed: () => Navigator.pop(ctx, ctl.text), child: const Text('Create')),
        ],
      ),
    );
    Future<void>.delayed(const Duration(seconds: 1), ctl.dispose);
    if (name == null || name.trim().isEmpty) return;
    final c = await _repo.create(name);
    if (!mounted) return;
    _push(PlaylistScreen(collectionId: c.id));
  }

  Future<void> _folderMenu(Collection c) async {
    final v = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(CollectionPicker.iconFor(c), color: ByteColors.accentDim),
              title: Text(c.name),
              subtitle: Text('${c.count} item${c.count == 1 ? '' : 's'}'),
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
    if (v == 'delete') {
      await _repo.delete(c.id);
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

  static String _count(int n, String one, String many) => n == 0 ? 'None yet' : '$n ${n == 1 ? one : many}';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: !_loaded
            ? const SizedBox.shrink()
            : CustomScrollView(
                slivers: [
                  SliverToBoxAdapter(
                    child: PageTitle(
                      'Folders',
                      trailing: IconButton(tooltip: 'New folder', icon: const Icon(Icons.create_new_folder_outlined), onPressed: _newFolder),
                    ),
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(ByteSpace.page, 12, ByteSpace.page, 0),
                    sliver: SliverGrid(
                      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 2, mainAxisSpacing: 14, crossAxisSpacing: 14, childAspectRatio: 1.05),
                      delegate: SliverChildBuilderDelegate(
                        (_, i) {
                          if (i == _folders.length) return NewFolderCard(onTap: _newFolder);
                          final c = _folders[i];
                          return FolderCard(
                            c: c,
                            covers: _covers[c.id] ?? const [],
                            onTap: () => _push(PlaylistScreen(collectionId: c.id)),
                            onLongPress: () => _folderMenu(c),
                          );
                        },
                        childCount: _folders.length + 1,
                      ),
                    ),
                  ),
                  const SliverToBoxAdapter(child: SectionLabel('Always here', top: 28)),
                  SliverToBoxAdapter(
                    child: ByteList(
                      children: [
                        ByteRow(
                          icon: Icons.notes_rounded,
                          title: 'Notes',
                          subtitle: _count(_notes, 'note', 'notes'),
                          chevron: true,
                          onTap: () => _push(const NotesScreen()),
                        ),
                        ByteRow(
                          icon: Icons.mic_none_rounded,
                          title: 'Voice notes',
                          subtitle: _count(_voice, 'voice note', 'voice notes'),
                          chevron: true,
                          onTap: () => _push(const CaptureScreen()),
                        ),
                        ByteRow(
                          icon: Icons.badge_outlined,
                          title: 'Document wallet',
                          subtitle: 'ID cards and papers that matter, with a reminder before one runs out',
                          chevron: true,
                          onTap: () => WalletScreen.open(context),
                        ),
                        ByteRow(
                          icon: Icons.ios_share_rounded,
                          title: 'Friends and sharing',
                          subtitle: 'Lists you share with a friend, and the links you made',
                          chevron: true,
                          onTap: () => _push(const FriendsScreen()),
                        ),
                        ByteRow(
                          icon: Icons.lock_outline_rounded,
                          title: 'Private',
                          subtitle: !_privateSetUp
                              ? 'Photos, files and notes behind their own PIN'
                              : _private == 0
                                  ? 'Empty. Opens with your private PIN'
                                  : '$_private item${_private == 1 ? '' : 's'}. Opens with your private PIN',
                          chevron: true,
                          onTap: () => PrivateScreen.open(context),
                        ),
                        ByteRow(
                          icon: Icons.delete_outline_rounded,
                          title: 'Bin',
                          subtitle: _bin == 0 ? 'Empty. Deleted things wait here for 30 days.' : '$_bin item${_bin == 1 ? '' : 's'}, kept for 30 days',
                          chevron: true,
                          onTap: () => _push(const BinScreen()),
                        ),
                        ByteRow(
                          icon: Icons.auto_awesome_outlined,
                          title: 'Tidy up',
                          subtitle: 'BYTE suggests folders, names and what could go. You decide',
                          chevron: true,
                          onTap: () => _push(const TidyScreen()),
                        ),
                        ByteRow(
                          icon: Icons.history_rounded,
                          title: 'Activity',
                          subtitle: 'What was moved, renamed or binned lately, each with an Undo',
                          chevron: true,
                          onTap: () => _push(const ActivityScreen()),
                        ),
                      ],
                    ),
                  ),
                  const SliverToBoxAdapter(child: SizedBox(height: 96)),
                ],
              ),
      ),
    );
  }
}
