import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/cloud_sync.dart';
import '../../core/friends.dart';
import '../../shared/theme.dart';
import '../../shared/ui.dart';
import '../notes/checklist_view.dart';
import '../share/shared_screen.dart';
import 'shared_album_screen.dart';

/// Friends: the people you share checklists with, and how to add one.
///
/// Adding a friend is a swap of two messages, once: you send an invite, they
/// paste it and send an answer back, you paste that. After it, sharing a
/// list with them is one tap on the list itself.
class FriendsScreen extends StatefulWidget {
  const FriendsScreen({super.key});

  @override
  State<FriendsScreen> createState() => _FriendsScreenState();
}

class _FriendsScreenState extends State<FriendsScreen> {
  List<Friend> _friends = const [];
  List<FriendAlbum> _albums = const [];
  bool _loaded = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    Friends.changed.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    Friends.changed.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final friends = await Friends.list();
    final albums = await Friends.albums();
    if (!mounted) return;
    setState(() {
      _friends = friends;
      _albums = albums;
      _loaded = true;
    });
  }

  void _say(String text) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  /// Friends need Google Drive (the lists travel through it) and a name to
  /// go by. Asks for what is missing; false when the user gave up.
  Future<bool> _ready() async {
    if (!await CloudSync.connected()) {
      if (mounted) _say('Connect Google Drive first: Settings, then Google Drive. Shared lists travel through it.');
      return false;
    }
    if (Friends.myName.isNotEmpty) return true;
    if (!mounted) return false;
    final name = await ChecklistView.askLine(context, title: 'Your name, as your friend will see it', action: 'OK');
    if (name == null) return false;
    await Friends.setMyName(name);
    return true;
  }

  Future<void> _invite() async {
    if (_busy || !await _ready() || !mounted) return;
    setState(() => _busy = true);
    try {
      final text = await Friends.invite();
      if (!mounted) return;
      await SharePlus.instance.share(ShareParams(text: text));
    } catch (_) {
      if (mounted) _say('Could not make the invite. It needs the internet and Google Drive. Try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// "I got a code": paste what the friend sent.
  Future<void> _gotCode() async {
    if (_busy || !await _ready()) return;
    if (!mounted) return;
    final ctl = TextEditingController();
    final pasted = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Paste your friend\'s message'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: ctl,
              autofocus: true,
              minLines: 2,
              maxLines: 4,
              decoration: const InputDecoration(hintText: 'The whole message, with BYTE-FRIEND: in it'),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                style: inlineButton,
                icon: const Icon(Icons.content_paste_rounded, size: 18),
                label: const Text('Paste'),
                onPressed: () async {
                  final clip = await Clipboard.getData(Clipboard.kTextPlain);
                  final text = clip?.text ?? '';
                  if (text.isNotEmpty) ctl.text = text;
                },
              ),
            ),
          ],
        ),
        actions: [
          TextButton(style: inlineButton, onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(style: inlineButton, onPressed: () => Navigator.pop(ctx, ctl.text), child: const Text('Add')),
        ],
      ),
    );
    // The dialog is still closing for a moment and uses the controller meanwhile.
    Future<void>.delayed(const Duration(seconds: 1), ctl.dispose);
    if (pasted == null || pasted.trim().isEmpty || !mounted) return;
    setState(() => _busy = true);
    try {
      final added = await Friends.accept(pasted);
      if (!mounted) return;
      if (added.reply.isEmpty) {
        _say('${added.friend.name} and you are connected. Open a checklist, tap the menu at the top, then "Share with a friend".');
      } else {
        await _sendBack(added);
      }
    } on FriendProblem catch (e) {
      if (mounted) _say(e.message);
    } catch (_) {
      if (mounted) _say('Could not add your friend. It needs the internet and Google Drive. Try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// The second half of the swap: the answer goes back to the friend.
  Future<void> _sendBack(FriendAdded added) async {
    final send = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text('One more step: answer ${added.friend.name}'),
        content: Text('${added.friend.name} is added on this phone. Now send your answer back, so their BYTE knows you too. Until they paste it, nothing is shared.'),
        actions: [
          TextButton(style: inlineButton, onPressed: () => Navigator.pop(ctx, false), child: const Text('Later')),
          FilledButton(style: inlineButton, onPressed: () => Navigator.pop(ctx, true), child: const Text('Send my answer')),
        ],
      ),
    );
    if (send == true) await SharePlus.instance.share(ShareParams(text: added.reply));
  }

  Future<void> _remove(Friend f) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove ${f.name}?'),
        content: const Text('Lists you share stop following each other. Each of you keeps the lists as they are now.'),
        actions: [
          TextButton(style: inlineButton, onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(style: inlineButton, onPressed: () => Navigator.pop(ctx, true), child: Text('Remove', style: TextStyle(color: ByteColors.danger))),
        ],
      ),
    );
    if (ok != true) return;
    await Friends.remove(f);
  }

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Friends and sharing')),
      body: !_loaded
          ? const SizedBox.shrink()
          : ListView(
              padding: const EdgeInsets.only(bottom: 32),
              children: [
                if (_busy) const LinearProgressIndicator(minHeight: 2),
                if (_friends.isEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(ByteSpace.page, 16, ByteSpace.page, 8),
                    child: Text(
                      'Share a checklist or a photo album with someone: you both see the same list and the same photos, and a change on one phone shows on the other within about a minute.\n\n'
                      'Adding a friend takes two messages, once: you send an invite, they send an answer back.',
                      style: tt.bodyMedium?.copyWith(color: ByteColors.textDim, height: 1.45),
                    ),
                  ),
                for (final f in _friends)
                  ByteRow(
                    icon: Icons.person_outline_rounded,
                    title: f.name,
                    subtitle: 'A list: its own menu, "Share with a friend". Photos: pick them, tap share',
                    trailing: IconButton(
                      tooltip: 'Remove',
                      icon: Icon(Icons.close_rounded, color: ByteColors.textFaint, size: 20),
                      onPressed: () => _remove(f),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(ByteSpace.page, 16, ByteSpace.page, 8),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilledButton.icon(
                        style: inlineButton,
                        onPressed: _busy ? null : _invite,
                        icon: const Icon(Icons.person_add_alt_1_rounded, size: 18),
                        label: const Text('Invite a friend'),
                      ),
                      FilledButton.tonalIcon(
                        style: inlineButton,
                        onPressed: _busy ? null : _gotCode,
                        icon: const Icon(Icons.content_paste_go_rounded, size: 18),
                        label: const Text('I got a code'),
                      ),
                    ],
                  ),
                ),
                // The albums you share with friends: both of you add, both of you see.
                if (_albums.isNotEmpty) const SectionLabel('Albums with friends', top: 20),
                for (final a in _albums)
                  ByteRow(
                    icon: Icons.photo_library_outlined,
                    title: a.title,
                    subtitle: '${a.friend.isEmpty ? 'A friend' : 'With ${a.friend}'} · ${a.count} ${a.count == 1 ? 'photo or video' : 'photos and videos'}',
                    chevron: true,
                    onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => SharedAlbumScreen(album: a))),
                  ),
                const SizedBox(height: 12),
                // The other way of sharing lives here too: a link anyone can open.
                ByteRow(
                  icon: Icons.link_rounded,
                  title: 'Links you made',
                  subtitle: 'Photos and files shared with a link. Stop any of them here',
                  chevron: true,
                  onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SharedScreen())),
                ),
              ],
            ),
    );
  }
}
