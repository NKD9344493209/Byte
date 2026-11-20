import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/cloud_sync.dart';
import '../../core/drive_media.dart';
import '../../core/storage_rules.dart';
import '../../shared/theme.dart';
import 'cloud_screen.dart';

/// Top of "Drive & storage": how full Google Drive is, how much the phone has
/// been spared, and the one-time "Move to Drive" for older photos and videos.
class DriveSpaceCard extends StatefulWidget {
  const DriveSpaceCard({super.key});

  @override
  State<DriveSpaceCard> createState() => _DriveSpaceCardState();
}

class _DriveSpaceCardState extends State<DriveSpaceCard> {
  (int, int)? _quota;
  (int, int) _freed = (0, 0);
  (int, int) _movable = (0, 0);
  bool _loaded = false;
  bool _moving = false;

  @override
  void initState() {
    super.initState();
    DriveMedia.state.addListener(_onState);
    DriveMedia.changed.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    DriveMedia.state.removeListener(_onState);
    DriveMedia.changed.removeListener(_load);
    super.dispose();
  }

  void _onState() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    await DriveMedia.refresh();
    final freed = await DriveMedia.freed();
    final movable = await DriveMedia.movable();
    if (!mounted) return;
    setState(() {
      _freed = freed;
      _movable = movable;
      _loaded = true;
    });
    if (DriveMedia.state.value.good && _quota == null) {
      final q = await CloudSync.quota();
      if (mounted) setState(() => _quota = q);
    }
  }

  Future<void> _move() async {
    HapticFeedback.lightImpact();
    setState(() => _moving = true);
    final (n, bytes) = await DriveMedia.queueAllExisting();
    if (!mounted) return;
    setState(() => _moving = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(n == 0 ? 'Everything is already in Drive.' : 'Moving $n to Drive (${fmtBytes(bytes)}). Keep using BYTE, it happens in the background.'),
    ));
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final s = DriveMedia.state.value;
    if (!_loaded) return const SizedBox(height: 8);
    return Padding(
      padding: const EdgeInsets.fromLTRB(ByteSpace.page, 8, ByteSpace.page, 0),
      child: AnimatedSize(
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
        alignment: Alignment.topCenter,
        child: Container(
          width: double.infinity,
          decoration: BoxDecoration(color: s.good ? ByteColors.accentSoft : ByteColors.surface2, borderRadius: BorderRadius.circular(ByteSpace.rl)),
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(s.good ? Icons.cloud_done_rounded : Icons.cloud_off_rounded, color: s.good ? ByteColors.accentDim : ByteColors.textDim),
                  const SizedBox(width: 10),
                  Expanded(child: Text('Google Drive', style: tt.titleLarge)),
                  if (s.uploading) Text('${(s.progress * 100).round()}%', style: tt.labelLarge?.copyWith(color: ByteColors.accentDim, fontFeatures: const [FontFeature.tabularFigures()])),
                ],
              ),
              const SizedBox(height: 6),
              if (!s.connected) ...[
                Text('Connect once, and every photo and video you send to BYTE lives in your Drive instead of filling the phone.', style: tt.bodyMedium?.copyWith(color: ByteColors.textDim)),
                const SizedBox(height: 14),
                FilledButton(
                  onPressed: () async {
                    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const CloudScreen()));
                    await _load();
                  },
                  child: const Text('Connect Google Drive'),
                ),
              ] else ...[
                Text(
                  !s.online
                      ? 'No internet right now. Anything new waits and goes up by itself.'
                      : s.uploading
                          ? 'Uploading ${s.waiting} ${s.waiting == 1 ? 'item' : 'items'}…'
                          : s.waiting > 0
                              ? '${s.waiting} waiting to upload'
                              : 'Photos and videos go here by themselves.',
                  style: tt.bodyMedium?.copyWith(color: ByteColors.textDim),
                ),
                if (_quota != null && _quota!.$2 > 0) ...[
                  const SizedBox(height: 14),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: TweenAnimationBuilder<double>(
                      tween: Tween(begin: 0, end: (_quota!.$1 / _quota!.$2).clamp(0.0, 1.0).toDouble()),
                      duration: const Duration(milliseconds: 900),
                      curve: Curves.easeOutCubic,
                      builder: (_, v, _) => LinearProgressIndicator(value: v, minHeight: 8, backgroundColor: ByteColors.surface, color: v > 0.9 ? ByteColors.danger : ByteColors.accent),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text('${fmtBytes(_quota!.$1)} of ${fmtBytes(_quota!.$2)} used (shared with Gmail and Photos)', style: tt.bodySmall),
                ],
                if (_freed.$1 > 0) ...[
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Icon(Icons.smartphone_rounded, size: 16, color: ByteColors.accentDim),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TweenAnimationBuilder<double>(
                          tween: Tween(begin: 0, end: _freed.$2.toDouble()),
                          duration: const Duration(milliseconds: 900),
                          curve: Curves.easeOutCubic,
                          builder: (_, v, _) => Text('${fmtBytes(v.round())} freed on this phone (${_freed.$1} ${_freed.$1 == 1 ? 'item' : 'items'})', style: tt.bodyMedium?.copyWith(fontWeight: FontWeight.w700)),
                        ),
                      ),
                    ],
                  ),
                ],
                if (_movable.$1 > 0) ...[
                  const SizedBox(height: 14),
                  Text('${_movable.$1} older ${_movable.$1 == 1 ? 'photo or video is' : 'photos and videos are'} only on this phone (${fmtBytes(_movable.$2)}).', style: tt.bodyMedium),
                  const SizedBox(height: 10),
                  FilledButton.icon(
                    onPressed: _moving ? null : _move,
                    icon: const Icon(Icons.cloud_upload_rounded, size: 18),
                    label: Text('Move to Drive, free ${fmtBytes(_movable.$2)}'),
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}

