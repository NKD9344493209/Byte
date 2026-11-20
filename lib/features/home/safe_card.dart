import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/cloud_sync.dart';
import '../../core/drive_media.dart';
import '../../core/gallery.dart';
import '../../core/prefs.dart';
import '../../shared/theme.dart';
import '../../shared/ui.dart';
import '../library/library_item.dart' show humanSize;
import '../settings/gallery_screen.dart';

/// A quiet card in the Library that looks after two things by itself:
///
///  * "kept for good" — when your gallery photos are only on this phone, it
///    offers to keep a copy of each in your own Google Drive;
///  * "light on the phone" — when many photos are already safe in Drive, it
///    offers to take them off the phone (a small preview stays).
///
/// "Not now" hides it for a week.
class SafeCard extends StatefulWidget {
  const SafeCard({super.key});

  @override
  State<SafeCard> createState() => _SafeCardState();
}

class _SafeCardState extends State<SafeCard> {
  static const _kBackupNext = 'safe_card_backup_next';
  static const _kFreeNext = 'safe_card_free_next';

  /// Worth a card from this much on (500 MB).
  static const _worthFreeing = 500 * 1024 * 1024;

  String _what = ''; // '' | 'backup' | 'free'
  int _count = 0;
  int _bytes = 0;
  Timer? _soon;

  @override
  void initState() {
    super.initState();
    DriveMedia.changed.addListener(_later);
    Gallery.state.addListener(_later);
    // A little after the Library is up; never in the way of opening BYTE.
    _soon = Timer(const Duration(seconds: 6), _look);
  }

  @override
  void dispose() {
    _soon?.cancel();
    DriveMedia.changed.removeListener(_later);
    Gallery.state.removeListener(_later);
    super.dispose();
  }

  void _later() {
    _soon?.cancel();
    _soon = Timer(const Duration(seconds: 4), _look);
  }

  bool _due(String key) => Prefs.number(key) <= DateTime.now().millisecondsSinceEpoch;

  Future<void> _look() async {
    var what = '';
    var count = 0;
    var bytes = 0;
    try {
      if (Gallery.on && await CloudSync.connected()) {
        if (!Gallery.backup) {
          if (_due(_kBackupNext)) what = 'backup';
        } else if (_due(_kFreeNext)) {
          final (n, b) = await Gallery.freeable();
          if (b >= _worthFreeing) {
            what = 'free';
            count = n;
            bytes = b;
          }
        }
      }
    } catch (_) {}
    if (!mounted) return;
    if (what != _what || count != _count || bytes != _bytes) {
      setState(() {
        _what = what;
        _count = count;
        _bytes = bytes;
      });
    }
  }

  Future<void> _notNow() async {
    await Prefs.setNumber(_what == 'backup' ? _kBackupNext : _kFreeNext, DateTime.now().add(const Duration(days: 7)).millisecondsSinceEpoch);
    if (mounted) setState(() => _what = '');
  }

  Future<void> _open() async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const GalleryScreen()));
    if (mounted) _later();
  }

  @override
  Widget build(BuildContext context) {
    if (_what.isEmpty) return const SizedBox.shrink();
    final tt = Theme.of(context).textTheme;
    final backup = _what == 'backup';
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Well(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(backup ? 'Your gallery photos are only on this phone' : '${humanSize(_bytes)} can come off this phone', style: tt.titleSmall),
            const SizedBox(height: 6),
            Text(
              backup
                  ? 'If the phone is lost or breaks, they are gone. BYTE can keep a copy of each one in your own Google Drive, in full quality, and then take them off the phone when you say so.'
                  : '$_count photos and videos are safely in your Google Drive. BYTE can remove them from the phone: a small preview stays, and opening one brings it back.',
              style: tt.bodySmall,
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                FilledButton(style: inlineButton, onPressed: _open, child: Text(backup ? 'Keep them safe' : 'Free up space')),
                const SizedBox(width: 8),
                TextButton(style: inlineButton, onPressed: _notNow, child: const Text('Not now')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
