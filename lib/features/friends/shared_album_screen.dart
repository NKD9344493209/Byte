import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/cloud_sync.dart';
import '../../core/friends.dart';
import '../../shared/theme.dart';
import '../../shared/ui.dart';
import '../library/library_repo.dart';

/// An album you share with a friend: the photos and videos both of you put
/// in, newest first. Each picture is a copy in the Google Drive of whoever
/// added it; BYTE shows it from there.
class SharedAlbumScreen extends StatefulWidget {
  const SharedAlbumScreen({super.key, required this.album});
  final FriendAlbum album;

  @override
  State<SharedAlbumScreen> createState() => _SharedAlbumScreenState();
}

class _SharedAlbumScreenState extends State<SharedAlbumScreen> {
  List<FriendPhoto> _photos = const [];
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    Friends.changed.addListener(_load);
    _load();
    // What the friend added a moment ago comes in.
    Friends.syncSoon();
  }

  @override
  void dispose() {
    Friends.changed.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final photos = await Friends.photos(widget.album.id);
    if (!mounted) return;
    setState(() {
      _photos = photos;
      _loaded = true;
    });
  }

  Future<void> _leave() async {
    final navigator = Navigator.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Take this album off your phone?'),
        content: const Text('The photos you put in stop being shared (your own photos in the Library are not touched). Your friend keeps theirs.'),
        actions: [
          TextButton(style: inlineButton, onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(style: inlineButton, onPressed: () => Navigator.pop(ctx, true), child: Text('Take it off', style: TextStyle(color: ByteColors.danger))),
        ],
      ),
    );
    if (ok != true) return;
    await Friends.leaveAlbum(widget.album.id);
    if (mounted) navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.album;
    final theirs = _photos.where((x) => !x.mine).length;
    return Scaffold(
      appBar: AppBar(
        title: Text(a.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          PopupMenuButton<String>(
            tooltip: 'More',
            onSelected: (_) => _leave(),
            itemBuilder: (_) => [PopupMenuItem(value: 'leave', child: Text('Take it off this phone', style: TextStyle(color: ByteColors.danger)))],
          ),
        ],
      ),
      body: !_loaded
          ? const SizedBox.shrink()
          : _photos.isEmpty
              ? const EmptyNote('Nothing in this album yet. To add photos: pick them in the Library, tap share, and choose your friend.')
              : CustomScrollView(
                  slivers: [
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(ByteSpace.page, 4, ByteSpace.page, 10),
                        child: Meta('With ${a.friend.isEmpty ? 'a friend' : a.friend} · ${_photos.length - theirs} from you, $theirs from them'),
                      ),
                    ),
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(2, 0, 2, 24),
                      sliver: SliverGrid.builder(
                        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, mainAxisSpacing: 2, crossAxisSpacing: 2),
                        itemCount: _photos.length,
                        itemBuilder: (context, i) => _Tile(
                          photo: _photos[i],
                          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => _PhotoPage(photos: _photos, index: i))),
                        ),
                      ),
                    ),
                  ],
                ),
    );
  }
}

/// A picture that could not be loaded: a quiet grey square, never an error.
Widget _missing(BuildContext context, Object error, StackTrace? stack) =>
    ColoredBox(color: ByteColors.surface2, child: Center(child: Icon(Icons.cloud_off_outlined, color: ByteColors.textFaint, size: 22)));

class _Tile extends StatelessWidget {
  const _Tile({required this.photo, required this.onTap});
  final FriendPhoto photo;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(color: ByteColors.surface2),
          Image.network(CloudSync.publicPicture(photo.k), fit: BoxFit.cover, gaplessPlayback: true, errorBuilder: _missing),
          if (photo.video) const Center(child: Icon(Icons.play_circle_fill_rounded, color: Colors.white, size: 30)),
        ],
      ),
    );
  }
}

/// One picture, large; swipe for the next. A friend's picture can be saved
/// into your own BYTE.
class _PhotoPage extends StatefulWidget {
  const _PhotoPage({required this.photos, required this.index});
  final List<FriendPhoto> photos;
  final int index;

  @override
  State<_PhotoPage> createState() => _PhotoPageState();
}

class _PhotoPageState extends State<_PhotoPage> {
  late final PageController _pages = PageController(initialPage: widget.index);
  late int _at = widget.index;
  bool _saving = false;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  /// A copy of the friend's picture goes into your own Library.
  Future<void> _save(FriendPhoto photo) async {
    if (_saving) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _saving = true);
    try {
      final bytes = await CloudSync.publicBytes(photo.k);
      if (bytes == null) {
        messenger.showSnackBar(const SnackBar(content: Text('Could not fetch it now. Check the internet and try again.')));
        return;
      }
      // The name may hold a dot that is no file ending ("Screenshot 10.30"):
      // only a known picture or video ending is taken as one.
      const endings = {'.jpg', '.jpeg', '.png', '.webp', '.heic', '.heif', '.gif', '.mp4', '.mov', '.mkv', '.webm', '.3gp', '.m4v'};
      final had = p.extension(photo.name).toLowerCase();
      final known = endings.contains(had);
      final ext = known ? had : (photo.video ? '.mp4' : '.jpg');
      final words = (known ? p.basenameWithoutExtension(photo.name) : photo.name).trim();
      final name = words.isEmpty ? 'From a friend' : words;
      final tmp = File(p.join((await getTemporaryDirectory()).path, 'friend_${photo.k}$ext'));
      await tmp.writeAsBytes(bytes, flush: true);
      await LibraryRepo.instance.importFile(tmp.path, displayName: '$name$ext', source: 'friend', move: true);
      messenger.showSnackBar(const SnackBar(content: Text('Saved to your Library.')));
    } catch (e) {
      debugPrint('[album] save: $e');
      messenger.showSnackBar(const SnackBar(content: Text('Could not save it. Try again.')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final photo = widget.photos[_at];
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(photo.mine ? 'From you' : 'From your friend', style: const TextStyle(fontSize: 16)),
        actions: [
          if (photo.video)
            IconButton(
              tooltip: 'Play in Google Drive',
              icon: const Icon(Icons.open_in_new_rounded),
              onPressed: () => launchUrl(Uri.parse(CloudSync.publicPage(photo.k)), mode: LaunchMode.externalApplication),
            ),
          if (!photo.mine)
            IconButton(
              tooltip: 'Save to my Library',
              icon: _saving ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.download_rounded),
              onPressed: _saving ? null : () => _save(photo),
            ),
        ],
      ),
      body: PageView.builder(
        controller: _pages,
        itemCount: widget.photos.length,
        onPageChanged: (i) => setState(() => _at = i),
        itemBuilder: (context, i) {
          final it = widget.photos[i];
          return InteractiveViewer(
            maxScale: 4,
            child: Center(
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Image.network(CloudSync.publicPicture(it.k, width: 1600), fit: BoxFit.contain, gaplessPlayback: true, errorBuilder: _missing),
                  if (it.video) const Icon(Icons.play_circle_fill_rounded, color: Colors.white70, size: 64),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
