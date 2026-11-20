import 'package:flutter/material.dart';

import '../../core/cloud_sync.dart';
import '../../core/gallery.dart';
import '../../core/prefs.dart';
import '../../shared/motion.dart';
import '../../shared/theme.dart';
import '../../shared/ui.dart';
import '../library/library_item.dart' show humanSize;

/// On the Library, above everything: the offer to bring the phone's gallery
/// into BYTE, the progress while that happens, and a nudge when Android no
/// longer lets BYTE see the gallery. Shows nothing the rest of the time.
class GalleryCard extends StatefulWidget {
  const GalleryCard({super.key});

  @override
  State<GalleryCard> createState() => _GalleryCardState();
}

class _GalleryCardState extends State<GalleryCard> {
  bool _asking = false;

  Future<void> _bringIn() async {
    if (_asking) return;
    setState(() => _asking = true);
    final perm = await Gallery.turnOn();
    if (!mounted) return;
    setState(() => _asking = false);
    if (perm == 'none') {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('BYTE was not allowed to see your photos. You can allow it in the phone\'s Settings → Apps → BYTE → Permissions.'),
      ));
    } else if (perm == 'partial') {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('BYTE can see only the photos you picked. Choose "Allow all" to see the whole gallery.'),
      ));
    }
  }

  Future<void> _notNow() async {
    await Prefs.setFlag('gallery_card_hidden', true);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return ValueListenableBuilder<GalleryState>(
      valueListenable: Gallery.state,
      builder: (_, s, _) {
        if (s.on && s.running && s.added > 0) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(ByteSpace.page, 10, ByteSpace.page, 0),
            child: Row(
              children: [
                const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: 10),
                Expanded(child: Text('Bringing in your gallery… ${s.added} so far', style: tt.bodySmall)),
              ],
            ),
          );
        }
        if (s.on && !s.allowed) {
          return Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Well(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('BYTE can no longer see your gallery', style: tt.titleSmall),
                  const SizedBox(height: 6),
                  Text('Photos you take now will not appear here until you allow it again.', style: tt.bodySmall),
                  const SizedBox(height: 10),
                  FilledButton(style: inlineButton, onPressed: _asking ? null : _bringIn, child: const Text('Allow again')),
                ],
              ),
            ),
          );
        }
        if (s.on || Prefs.flag('gallery_card_hidden')) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Well(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Your phone\'s photos, here', style: tt.titleSmall),
                const SizedBox(height: 6),
                Text(
                  'BYTE can show the photos and videos already on this phone, and every new one you take. Nothing is copied and nothing is moved — they stay in your gallery too.',
                  style: tt.bodySmall,
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    FilledButton(style: inlineButton, onPressed: _asking ? null : _bringIn, child: const Text('Bring in my gallery')),
                    const SizedBox(width: 8),
                    TextButton(style: inlineButton, onPressed: _notNow, child: const Text('Not now')),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Settings → Phone gallery: bring it in, copy it to Drive, free up space,
/// call recordings.
class GalleryScreen extends StatefulWidget {
  const GalleryScreen({super.key});

  @override
  State<GalleryScreen> createState() => _GalleryScreenState();
}

class _GalleryScreenState extends State<GalleryScreen> {
  bool _busy = false;
  bool _driveOn = false;
  int _freeCount = 0;
  int _freeBytes = 0;
  String _progress = '';

  @override
  void initState() {
    super.initState();
    Gallery.state.addListener(_changed);
    _load();
  }

  @override
  void dispose() {
    Gallery.state.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    final drive = await CloudSync.connected();
    final (n, b) = await Gallery.freeable();
    if (!mounted) return;
    setState(() {
      _driveOn = drive;
      _freeCount = n;
      _freeBytes = b;
    });
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _setOn(bool v) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      if (v) {
        final perm = await Gallery.turnOn();
        if (!mounted) return;
        if (perm == 'none') {
          _snack('BYTE was not allowed to see your photos. Allow it in the phone\'s Settings → Apps → BYTE → Permissions.');
        } else if (perm == 'partial') {
          _snack('BYTE can see only the photos you picked. Choose "Allow all" to see the whole gallery.');
        }
      } else {
        await Gallery.turnOff();
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _setBackup(bool v) async {
    if (v && !_driveOn) {
      _snack('Connect Google Drive first (Settings → Google Drive).');
      return;
    }
    if (v) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Copy your gallery to Google Drive?'),
          content: const Text(
            'Every photo and video BYTE shows from your gallery is copied to your own Drive, in the "BYTE Vault" folder. '
            'This uses your Drive space — a big gallery can fill the free 15 GB.\n\n'
            'Nothing is removed from the phone. After they are safe in Drive, "Free up space" can remove the phone copies when you ask.',
          ),
          actions: [
            TextButton(style: inlineButton, onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(style: inlineButton, onPressed: () => Navigator.pop(ctx, true), child: const Text('Copy to Drive')),
          ],
        ),
      );
      if (ok != true) return;
    }
    await Gallery.setBackup(v);
    if (mounted) setState(() {});
  }

  Future<void> _setCalls(bool v) async {
    final on = await Gallery.setCalls(v);
    if (!mounted) return;
    setState(() {});
    if (v && !on) _snack('BYTE was not allowed to see audio files, so call recordings stay out.');
  }

  Future<void> _lookAgain() async {
    if (_busy) return;
    setState(() => _busy = true);
    final added = await Gallery.sync(full: true);
    if (!mounted) return;
    setState(() => _busy = false);
    _snack(added == 0 ? 'Nothing new in your gallery.' : '$added new item${added == 1 ? '' : 's'} from your gallery.');
    _load();
  }

  Future<void> _freeUp() async {
    if (_busy) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Free up space?'),
        content: Text(
          '$_freeCount item${_freeCount == 1 ? '' : 's'} (${humanSize(_freeBytes)}) ${_freeCount == 1 ? 'is' : 'are'} safely in your Google Drive.\n\n'
          'BYTE checks each one with Drive again, then Android asks you once before anything is removed from the phone. '
          'They stay in BYTE with a small preview, and opening one brings it back from Drive.\n\n'
          'Up to 200 are done at a time, biggest first.',
        ),
        actions: [
          TextButton(style: inlineButton, onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(style: inlineButton, onPressed: () => Navigator.pop(ctx, true), child: const Text('Continue')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() {
      _busy = true;
      _progress = 'Checking with Drive…';
    });
    FreeUpResult r;
    try {
      r = await Gallery.freeUp(
        onProgress: (done, total) {
          if (mounted) setState(() => _progress = 'Checking with Drive… $done of $total');
        },
      );
    } catch (e) {
      debugPrint('[gallery] free up: $e');
      r = const FreeUpResult();
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _progress = '';
    });
    if (r.offline) {
      _snack('Could not reach Google Drive, so nothing was removed. Try again when you are online.');
    } else if (r.checking) {
      _snack('BYTE is still matching the restored list with this phone\'s gallery. Nothing was removed. Try again in a few minutes.');
    } else if (r.declined) {
      _snack('Nothing was removed.');
    } else if (r.freed == 0) {
      _snack('Nothing could be freed just now. Please try again in a little while.');
    } else {
      Haptics.confirm();
      _snack('Freed ${humanSize(r.bytes)} — ${r.freed} item${r.freed == 1 ? '' : 's'} now live in Drive.${r.left > 0 ? ' ${r.left} more can be freed.' : ''}');
    }
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final s = Gallery.state.value;
    final tt = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Phone gallery')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 40),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(ByteSpace.page, 8, ByteSpace.page, 12),
            child: Text(
              'BYTE lists the photos and videos already on this phone. It does not copy them: each one stays in your gallery, and BYTE adds search, folders and stars on top.',
              style: tt.bodyMedium?.copyWith(color: ByteColors.textDim),
            ),
          ),
          ByteList(
            children: [
              ByteRow(
                icon: Icons.photo_library_outlined,
                title: 'Show my gallery in BYTE',
                subtitle: !s.on
                    ? 'Off'
                    : !s.allowed
                        ? 'BYTE is not allowed to see your photos'
                        : s.running
                            ? 'Looking… ${s.added} added so far'
                            : '${s.count} item${s.count == 1 ? '' : 's'} from your gallery${s.permission == 'partial' ? ' (only the ones you picked)' : ''}',
                trailing: ByteSwitch(value: s.on, onChanged: _busy ? null : _setOn),
              ),
              if (s.on)
                ByteRow(
                  icon: Icons.refresh_rounded,
                  title: 'Look again now',
                  subtitle: 'New photos appear by themselves; this checks at once',
                  onTap: _busy ? null : _lookAgain,
                ),
            ],
          ),
          const SectionLabel('Space on this phone'),
          ByteList(
            children: [
              ByteRow(
                icon: Icons.cloud_upload_outlined,
                title: 'Copy gallery photos to Google Drive',
                subtitle: _driveOn ? 'Uses your Drive space. Nothing leaves the phone by itself.' : 'Connect Google Drive first',
                trailing: ByteSwitch(value: Gallery.backup, onChanged: _busy ? null : _setBackup),
              ),
              ByteRow(
                icon: Icons.cleaning_services_outlined,
                title: 'Free up space',
                subtitle: _progress.isNotEmpty
                    ? _progress
                    : _freeCount == 0
                        ? 'Nothing to free yet. Photos can be freed once they are safely in Drive.'
                        : '$_freeCount item${_freeCount == 1 ? '' : 's'} safely in Drive — ${humanSize(_freeBytes)} can be freed',
                chevron: _freeCount > 0 && !_busy,
                onTap: _freeCount > 0 && !_busy ? _freeUp : null,
              ),
            ],
          ),
          const SectionLabel('Also bring in'),
          ByteList(
            children: [
              ByteRow(
                icon: Icons.call_outlined,
                title: 'Call recordings',
                subtitle: 'Recordings your phone\'s dialer saved. They appear under Voice in the Library.',
                trailing: ByteSwitch(value: Gallery.calls, onChanged: _busy ? null : _setCalls),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(ByteSpace.page, 18, ByteSpace.page, 0),
            child: Text(
              'Deleting a gallery photo in BYTE moves it to BYTE\'s bin for 30 days; the photo itself stays on the phone. '
              '"Delete for good" asks Android to remove the original too.',
              style: tt.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}
