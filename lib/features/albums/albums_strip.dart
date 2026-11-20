import 'dart:async';

import 'package:flutter/material.dart';

import '../../shared/motion.dart';
import '../../shared/theme.dart';
import '../../shared/ui.dart';
import '../library/library_repo.dart';
import '../library/library_screen.dart' show LibraryThumb;
import 'album_screen.dart';
import 'albums.dart';

/// The row of albums at the top of the Library: BYTE's own filing. Camera,
/// people, food, ID cards, bills, busy days, screenshots, WhatsApp… each a
/// card with its newest picture. Slide it sideways; tap one to open it.
class AlbumsStrip extends StatefulWidget {
  const AlbumsStrip({super.key});

  @override
  State<AlbumsStrip> createState() => _AlbumsStripState();
}

class _AlbumsStripState extends State<AlbumsStrip> {
  List<Album> _albums = Albums.last;
  Timer? _soon;
  bool _looking = false;
  bool _again = false;

  @override
  void initState() {
    super.initState();
    Albums.changed.addListener(_later);
    LibraryRepo.instance.revision.addListener(_later);
    _look();
  }

  @override
  void dispose() {
    _soon?.cancel();
    Albums.changed.removeListener(_later);
    LibraryRepo.instance.revision.removeListener(_later);
    super.dispose();
  }

  void _later() {
    _soon?.cancel();
    _soon = Timer(const Duration(milliseconds: 900), _look);
  }

  Future<void> _look() async {
    if (_looking) {
      _again = true;
      return;
    }
    _looking = true;
    try {
      final albums = await Albums.list();
      if (mounted) setState(() => _albums = albums);
    } finally {
      _looking = false;
      if (_again && mounted) {
        _again = false;
        _later();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final albums = _albums;
    if (albums.isEmpty) return const SizedBox.shrink();
    final tt = Theme.of(context).textTheme;
    final apps = albums.any((a) => a.source && a.title != 'Camera' && a.title != 'Saved in BYTE');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionLabel('Sorted by BYTE', top: 14),
        SizedBox(
          // Picture + gap + two lines of text, which grow with the phone's font size.
          height: 118 + MediaQuery.textScalerOf(context).scale(34),
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: ByteSpace.page),
            itemCount: albums.length,
            separatorBuilder: (_, _) => const SizedBox(width: 10),
            itemBuilder: (_, i) => _AlbumCard(album: albums[i]),
          ),
        ),
        if (apps)
          Padding(
            padding: const EdgeInsets.fromLTRB(ByteSpace.page, 2, ByteSpace.page, 6),
            child: Text(
              'Screenshots and pictures saved by other apps stay in their albums, out of the list below.',
              style: tt.bodySmall?.copyWith(color: ByteColors.textFaint),
            ),
          ),
      ],
    );
  }
}

class _AlbumCard extends StatelessWidget {
  const _AlbumCard({required this.album});
  final Album album;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final a = album;
    final cover = a.cover;
    return Pressable(
      onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => AlbumScreen(album: a))),
      child: SizedBox(
        width: 108,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: SizedBox(
                width: 108,
                height: 108,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (cover != null)
                      LibraryThumb(item: cover, fit: BoxFit.cover)
                    else
                      Container(
                        color: ByteColors.surface2,
                        alignment: Alignment.center,
                        child: Icon(a.isDays ? Icons.event_rounded : Icons.photo_library_outlined, color: ByteColors.textFaint, size: 28),
                      ),
                    if (a.isDays)
                      Positioned(
                        left: 6,
                        top: 6,
                        child: Container(
                          padding: const EdgeInsets.all(4),
                          decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.5), shape: BoxShape.circle),
                          child: const Icon(Icons.event_rounded, color: Colors.white, size: 13),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(a.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: tt.titleSmall?.copyWith(fontWeight: FontWeight.w600, fontSize: 13)),
            Text('${a.count}', maxLines: 1, style: tt.bodySmall?.copyWith(fontSize: 12, color: ByteColors.textFaint)),
          ],
        ),
      ),
    );
  }
}
