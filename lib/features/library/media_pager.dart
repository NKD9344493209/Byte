import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart';

import '../../core/drive_media.dart';
import '../../shared/motion.dart';
import '../../shared/theme.dart';
import '../albums/albums.dart';
import '../albums/places.dart';
import 'library_item.dart';
import 'library_repo.dart';
import 'library_screen.dart' show LibraryThumb;
import 'library_viewer.dart';

/// Photos and videos, full screen: only the picture, swipe left and right to
/// the next one, pinch or double-tap to look closer.
///
/// One glowing green button sits in the corner. Its sheet holds everything
/// else — the sticky note, name, tags, star, folder, share, Google Drive,
/// the words BYTE read in the picture. A tap on the picture hides the two
/// buttons too.
class MediaPager extends StatefulWidget {
  const MediaPager({super.key, required this.items, this.index = 0, this.find = ''});

  /// The pictures to swipe through, in the order of the list they came from.
  final List<LibraryItem> items;
  final int index;

  /// Opened from Search with these words (the sheet shows where they were found).
  final String find;

  static bool isMedia(LibraryItem i) => i.kind == LibraryKind.photo || i.kind == LibraryKind.video;

  static Route<void> route(List<LibraryItem> items, {int index = 0, String find = ''}) => PageRouteBuilder<void>(
        transitionDuration: const Duration(milliseconds: 260),
        reverseTransitionDuration: const Duration(milliseconds: 220),
        pageBuilder: (_, a, _) => FadeTransition(
          opacity: CurvedAnimation(parent: a, curve: Curves.easeOutCubic),
          child: MediaPager(items: items, index: index, find: find),
        ),
      );

  /// Opens [it] full screen. [around] is the list it was tapped in: its
  /// photos and videos become the ones you can swipe to.
  static Future<void> open(BuildContext context, LibraryItem it, {List<LibraryItem> around = const [], String find = ''}) {
    var media = [
      for (final i in around)
        if (isMedia(i)) i,
    ];
    var at = media.indexWhere((i) => i.id == it.id);
    if (at < 0) {
      media = [it];
      at = 0;
    }
    return Navigator.of(context).push(route(media, index: at, find: find));
  }

  @override
  State<MediaPager> createState() => _MediaPagerState();
}

class _MediaPagerState extends State<MediaPager> {
  late final List<LibraryItem> _items = List<LibraryItem>.of(widget.items);
  late int _at = _items.isEmpty ? 0 : widget.index.clamp(0, _items.length - 1).toInt();
  late final PageController _pages = PageController(initialPage: _at);
  bool _buttons = true;
  bool _zoomed = false;
  ModalRoute<dynamic>? _route;

  /// Under the picture: its day and the albums BYTE filed it in.
  String _caption = '';

  @override
  void initState() {
    super.initState();
    LibraryRepo.instance.revision.addListener(_check);
    Albums.changed.addListener(_describe);
    _describe();
  }

  /// "Wed, 18 Nov 2026 · Camera, Food" for the picture on screen.
  Future<void> _describe() async {
    if (_items.isEmpty) return;
    final it = _items[_at];
    final places = await LibraryRepo.instance.placesOf(it.id);
    if (!mounted || _items.isEmpty || _items[_at].id != it.id) return;
    places.sort((a, b) => placeRank(a).compareTo(placeRank(b)));
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final t = it.createdAt;
    final day = '${days[t.weekday - 1]}, ${t.day} ${months[t.month - 1]} ${t.year}';
    setState(() => _caption = places.isEmpty ? day : '$day · ${places.join(', ')}');
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
  }

  @override
  void dispose() {
    LibraryRepo.instance.revision.removeListener(_check);
    Albums.changed.removeListener(_describe);
    _pages.dispose();
    super.dispose();
  }

  /// Something changed in the Library: if the picture on screen went to the
  /// bin or into the private space, show the next one — or close when it was
  /// the only one.
  Future<void> _check() async {
    if (_items.isEmpty) return;
    final id = _items[_at].id;
    final there = await LibraryRepo.instance.inLibrary([id]);
    if (!mounted || there.contains(id)) return;
    final i = _items.indexWhere((x) => x.id == id);
    if (i < 0) return;
    if (_items.length == 1) {
      _close();
      return;
    }
    setState(() {
      _items.removeAt(i);
      if (_at >= _items.length) _at = _items.length - 1;
      _zoomed = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _pages.hasClients) _pages.jumpToPage(_at);
    });
    unawaited(_describe());
  }

  /// Closes this screen — also when the details sheet still lies on top of it.
  void _close() {
    final route = _route;
    final nav = Navigator.of(context);
    if (route == null || route.isCurrent) {
      nav.maybePop();
    } else if (route.isActive) {
      nav.removeRoute(route);
    }
  }

  Future<void> _details() async {
    if (_items.isEmpty) return;
    final it = _items[_at];
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      clipBehavior: Clip.antiAlias,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        minChildSize: 0.35,
        maxChildSize: 0.94,
        // Its own place for messages ("Starred"), so they show on the sheet.
        builder: (ctx, scroll) => ScaffoldMessenger(
          child: Scaffold(
            backgroundColor: Colors.transparent,
            body: LibraryViewer(itemId: it.id, find: widget.find, embedded: true, scroll: scroll),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pad = MediaQuery.paddingOf(context);
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            PageView.builder(
              controller: _pages,
              // Looking closer: a drag moves the picture, not the page.
              physics: _zoomed ? const NeverScrollableScrollPhysics() : const PageScrollPhysics(),
              itemCount: _items.length,
              onPageChanged: (i) {
                setState(() {
                  _at = i;
                  _zoomed = false;
                  _caption = '';
                });
                _describe();
              },
              itemBuilder: (_, i) {
                final it = _items[i];
                void tap() => setState(() => _buttons = !_buttons);
                if (it.kind == LibraryKind.video) {
                  return _VideoPage(key: ValueKey('page-${it.id}'), item: it, active: i == _at, onTap: tap);
                }
                return _PhotoPage(
                  key: ValueKey('page-${it.id}'),
                  item: it,
                  onTap: tap,
                  onZoom: (z) {
                    if (i == _at && z != _zoomed && mounted) setState(() => _zoomed = z);
                  },
                );
              },
            ),
            // Back, top left.
            Positioned(
              top: pad.top + 8,
              left: 8,
              child: _Fading(
                shown: _buttons,
                child: Material(
                  color: Colors.black.withValues(alpha: 0.35),
                  shape: const CircleBorder(),
                  clipBehavior: Clip.antiAlias,
                  child: IconButton(
                    tooltip: 'Back',
                    icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                ),
              ),
            ),
            // Bottom left, small: the day, and where BYTE filed it.
            if (_caption.isNotEmpty)
              Positioned(
                left: 16,
                right: 92,
                bottom: pad.bottom + 30,
                child: _Fading(
                  shown: _buttons,
                  child: IgnorePointer(
                    child: Text(
                      _caption,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.w600, shadows: [Shadow(color: Colors.black87, blurRadius: 6)]),
                    ),
                  ),
                ),
              ),
            // The one green button: everything about this picture.
            Positioned(
              right: 18,
              bottom: pad.bottom + 22,
              child: _Fading(shown: _buttons, child: _GlowButton(onTap: _details)),
            ),
          ],
        ),
      ),
    );
  }
}

/// Fades its child in and out; while hidden it cannot be tapped.
class _Fading extends StatelessWidget {
  const _Fading({required this.shown, required this.child});
  final bool shown;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: !shown,
      child: AnimatedOpacity(opacity: shown ? 1 : 0, duration: Motion.d(context, 180), child: child),
    );
  }
}

/// The round green button with a soft glow that breathes.
class _GlowButton extends StatefulWidget {
  const _GlowButton({required this.onTap});
  final VoidCallback onTap;

  @override
  State<_GlowButton> createState() => _GlowButtonState();
}

class _GlowButtonState extends State<_GlowButton> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1800));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // "Motion: off" keeps the glow still.
    if (Motion.off(context)) {
      _c.stop();
      _c.value = 0.5;
    } else if (!_c.isAnimating) {
      _c.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final green = ByteColors.accentBright;
    return Tooltip(
      message: 'About this picture',
      child: RepaintBoundary(
        child: AnimatedBuilder(
          animation: _c,
          builder: (_, child) {
            final t = Curves.easeInOut.transform(_c.value);
            return Container(
              width: 54,
              height: 54,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: green,
                boxShadow: [BoxShadow(color: green.withValues(alpha: 0.35 + 0.4 * t), blurRadius: 12 + 12 * t, spreadRadius: 1 + 3 * t)],
              ),
              child: child,
            );
          },
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: () {
                Haptics.tap();
                widget.onTap();
              },
              child: Center(child: Icon(Icons.auto_awesome_rounded, color: ByteColors.onAccent, size: 24)),
            ),
          ),
        ),
      ),
    );
  }
}

/// One photo: the small preview at once, the sharp picture over it as soon
/// as it is read (from the phone, or brought back from Google Drive).
class _PhotoPage extends StatefulWidget {
  const _PhotoPage({super.key, required this.item, required this.onTap, required this.onZoom});
  final LibraryItem item;
  final VoidCallback onTap;
  final ValueChanged<bool> onZoom;

  @override
  State<_PhotoPage> createState() => _PhotoPageState();
}

class _PhotoPageState extends State<_PhotoPage> with SingleTickerProviderStateMixin {
  final TransformationController _view = TransformationController();
  late final AnimationController _anim = AnimationController(vsync: this, duration: const Duration(milliseconds: 220));
  Animation<Matrix4>? _move;
  Offset _tapAt = Offset.zero;
  bool _close = false; // looking closer (zoomed in)

  String? _full;
  double? _progress; // null = not downloading
  String _note = '';

  @override
  void initState() {
    super.initState();
    _view.addListener(_zoomChanged);
    _anim.addListener(() {
      final m = _move;
      if (m != null) _view.value = m.value;
    });
    final it = widget.item;
    if (it.path.isNotEmpty && File(it.path).existsSync()) {
      _full = it.path;
      unawaited(DriveMedia.ensureLocal(it)); // on screen: not freed for a while
    } else {
      _fetch();
    }
  }

  @override
  void dispose() {
    _view.removeListener(_zoomChanged);
    _view.dispose();
    _anim.dispose();
    super.dispose();
  }

  void _zoomChanged() {
    final close = _view.value.getMaxScaleOnAxis() > 1.01;
    if (close == _close) return;
    _close = close;
    if (mounted) setState(() {});
    widget.onZoom(close);
  }

  /// The full photo is not on the phone: bring it back from Google Drive.
  Future<void> _fetch() async {
    final it = widget.item;
    final e = await DriveMedia.entry(it.id);
    if (!mounted) return;
    if (e == null || !e.inDrive) {
      setState(() => _note = 'The full photo is not on this phone right now.');
      return;
    }
    setState(() {
      _progress = 0;
      _note = '';
    });
    final path = await DriveMedia.ensureLocal(it, onProgress: (got, total) {
      if (mounted && total > 0) setState(() => _progress = got / total);
    });
    if (!mounted) return;
    setState(() {
      _full = path;
      _progress = null;
      _note = path == null ? 'The full photo is in Google Drive. Tap when you are online.' : '';
    });
  }

  void _toggleZoom() {
    final Matrix4 end;
    if (_close) {
      end = Matrix4.identity();
    } else {
      // 2.5× around the spot that was tapped.
      const s = 2.5;
      end = Matrix4.identity()
        ..setEntry(0, 0, s)
        ..setEntry(1, 1, s)
        ..setEntry(0, 3, -_tapAt.dx * (s - 1))
        ..setEntry(1, 3, -_tapAt.dy * (s - 1));
    }
    _move = Matrix4Tween(begin: _view.value, end: end).animate(CurvedAnimation(parent: _anim, curve: Curves.easeOutCubic));
    _anim.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final it = widget.item;
    final full = _full;
    final size = MediaQuery.sizeOf(context);
    // Sharp enough to look closer, without opening a 50-megapixel photo in full.
    final px = (size.width * MediaQuery.devicePixelRatioOf(context) * 1.5).round().clamp(1080, 2600).toInt();
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        if (full == null && _progress == null) _fetch();
        widget.onTap();
      },
      onDoubleTapDown: (d) => _tapAt = d.localPosition,
      onDoubleTap: _toggleZoom,
      child: InteractiveViewer(
        transformationController: _view,
        minScale: 1,
        maxScale: 5,
        panEnabled: _close,
        child: SizedBox.expand(
          child: Hero(
            tag: 'media-${it.id}',
            child: Stack(
              fit: StackFit.expand,
              children: [
                // The preview is always under, so nothing ever flashes empty.
                LibraryThumb(item: it, fit: BoxFit.contain, bare: true),
                if (full != null)
                  Image.file(
                    File(full),
                    fit: BoxFit.contain,
                    cacheWidth: px,
                    gaplessPlayback: true,
                    frameBuilder: (_, child, frame, sync) => sync
                        ? child
                        : AnimatedOpacity(opacity: frame == null ? 0 : 1, duration: const Duration(milliseconds: 260), curve: Curves.easeOut, child: child),
                    errorBuilder: (_, _, _) => const SizedBox.shrink(),
                  ),
                if (_progress != null)
                  Align(
                    alignment: Alignment.bottomCenter,
                    child: LinearProgressIndicator(value: _progress == 0 ? null : _progress, minHeight: 2, backgroundColor: Colors.transparent, color: ByteColors.accent),
                  ),
                if (_note.isNotEmpty)
                  Align(
                    alignment: const Alignment(0, 0.8),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.55), borderRadius: BorderRadius.circular(999)),
                      child: Text(_note, style: const TextStyle(color: Colors.white, fontSize: 12)),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One video: its preview with a play button. It starts only when you tap
/// play, and stops when you swipe away.
class _VideoPage extends StatefulWidget {
  const _VideoPage({super.key, required this.item, required this.active, required this.onTap});
  final LibraryItem item;
  final bool active;
  final VoidCallback onTap;

  @override
  State<_VideoPage> createState() => _VideoPageState();
}

class _VideoPageState extends State<_VideoPage> {
  bool _playing = false;
  String? _remote;

  @override
  void didUpdateWidget(covariant _VideoPage old) {
    super.didUpdateWidget(old);
    if (!widget.active) _playing = false; // swiped away: the player is closed
  }

  Future<void> _play() async {
    final it = widget.item;
    if (it.path.isNotEmpty && File(it.path).existsSync()) {
      setState(() {
        _remote = null;
        _playing = true;
      });
      return;
    }
    final e = await DriveMedia.entry(it.id);
    if (!mounted) return;
    if (e != null && e.inDrive) {
      setState(() {
        _remote = e.remoteId;
        _playing = true;
      });
    } else {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('This video is not on the phone right now.')));
    }
  }

  Future<void> _openOutside() async {
    final it = widget.item;
    if (it.path.isEmpty || !File(it.path).existsSync()) return;
    await OpenFilex.open(it.path);
  }

  @override
  Widget build(BuildContext context) {
    final it = widget.item;
    if (_playing) {
      return LayoutBuilder(
        builder: (_, box) => Center(
          child: VideoBox(
            key: ValueKey('v-${_remote ?? it.path}'),
            item: it,
            remoteId: _remote,
            onOpen: _openOutside,
            maxHeight: box.maxHeight - 96,
            autoPlay: true,
          ),
        ),
      );
    }
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Hero(tag: 'media-${it.id}', child: LibraryThumb(item: it, fit: BoxFit.contain, bare: true)),
          Center(
            child: IconButton(
              tooltip: 'Play',
              iconSize: 76,
              icon: const Icon(Icons.play_circle_fill_rounded, color: Colors.white70),
              onPressed: _play,
            ),
          ),
        ],
      ),
    );
  }
}
