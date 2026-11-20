import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/drive_media.dart';
import '../../shared/theme.dart';
import '../settings/cloud_screen.dart';
import '../settings/storage_screen.dart';

/// The small "Drive" pill on Today.
///
/// Light green: internet on and Drive connected. While uploading, the green
/// softly fills from left to right; when a batch lands, a tick pops in for a
/// moment. Light red: something is off — a tap fixes the first problem
/// (internet → Wi-Fi for big files → connect Drive).
class DrivePill extends StatefulWidget {
  const DrivePill({super.key});

  @override
  State<DrivePill> createState() => _DrivePillState();
}

class _DrivePillState extends State<DrivePill> with SingleTickerProviderStateMixin {
  bool _down = false;
  late final AnimationController _shine = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600));

  @override
  void initState() {
    super.initState();
    DriveMedia.state.addListener(_onState);
    _onState();
  }

  @override
  void dispose() {
    DriveMedia.state.removeListener(_onState);
    _shine.dispose();
    super.dispose();
  }

  void _onState() {
    final s = DriveMedia.state.value;
    if (s.uploading && !_shine.isAnimating) {
      _shine.repeat();
    } else if (!s.uploading && _shine.isAnimating) {
      _shine.stop();
    }
    if (mounted) setState(() {});
  }

  Future<void> _tap() async {
    HapticFeedback.selectionClick();
    final s = DriveMedia.state.value;
    if (s.good) {
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const StorageScreen()));
      return;
    }
    final did = await DriveMedia.fixFirst();
    if (!mounted) return;
    if (did == 'drive') {
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const CloudScreen()));
    }
    await DriveMedia.refresh();
  }

  @override
  Widget build(BuildContext context) {
    final s = DriveMedia.state.value;
    final good = s.good;
    final bg = good ? ByteColors.accentSoft : ByteColors.dangerSoft;
    final fg = good ? ByteColors.accentDim : ByteColors.danger;
    final fill = ByteColors.accent.withValues(alpha: ByteColors.dark ? 0.35 : 0.28);
    final label = !s.online
        ? 'No internet. Tap to turn it on'
        : !s.connected
            ? 'Google Drive not connected. Tap to connect'
            : s.uploading
                ? 'Uploading to Google Drive, ${(s.progress * 100).round()} percent'
                : 'Google Drive connected';
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true, // the label says it all (not "… Drive" twice)
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _down = true),
        onTapCancel: () => setState(() => _down = false),
        onTapUp: (_) => setState(() => _down = false),
        onTap: _tap,
        child: AnimatedScale(
          scale: _down ? 0.92 : 1,
          duration: Duration(milliseconds: _down ? 90 : 300),
          curve: _down ? Curves.easeOut : Curves.elasticOut,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 380),
            curve: Curves.easeOutCubic,
            height: 30,
            decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
            clipBehavior: Clip.antiAlias,
            child: Stack(
              // The icon + "Drive" row sits in the middle of the 30 px pill, not at its top.
              alignment: Alignment.centerLeft,
              children: [
                // The upload filling in, left to right.
                Positioned.fill(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: AnimatedFractionallySizedBox(
                      duration: const Duration(milliseconds: 420),
                      curve: Curves.easeOutCubic,
                      widthFactor: good && (s.uploading || s.justFinished) ? s.progress.clamp(0.04, 1.0).toDouble() : 0,
                      heightFactor: 1,
                      child: AnimatedOpacity(
                        opacity: s.uploading ? 1 : 0,
                        duration: const Duration(milliseconds: 600),
                        child: ColoredBox(color: fill),
                      ),
                    ),
                  ),
                ),
                // A soft light passing through while it works.
                if (s.uploading && good)
                  Positioned.fill(
                    child: AnimatedBuilder(
                      animation: _shine,
                      builder: (context, _) => DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment(-1.6 + 3.2 * _shine.value, 0),
                            end: Alignment(-0.6 + 3.2 * _shine.value, 0),
                            colors: [Colors.white.withValues(alpha: 0), Colors.white.withValues(alpha: ByteColors.dark ? 0.10 : 0.35), Colors.white.withValues(alpha: 0)],
                          ),
                        ),
                      ),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 320),
                        switchInCurve: Curves.elasticOut,
                        switchOutCurve: Curves.easeIn,
                        transitionBuilder: (child, a) => ScaleTransition(scale: a, child: FadeTransition(opacity: a, child: child)),
                        child: Icon(
                          s.justFinished && good
                              ? Icons.cloud_done_rounded
                              : good
                                  ? (s.uploading ? Icons.cloud_upload_rounded : Icons.cloud_rounded)
                                  : Icons.cloud_off_rounded,
                          key: ValueKey('${s.justFinished && good}-$good-${s.uploading}'),
                          size: 16,
                          color: fg,
                        ),
                      ),
                      const SizedBox(width: 6),
                      AnimatedDefaultTextStyle(
                        duration: const Duration(milliseconds: 380),
                        style: TextStyle(fontFamily: 'Manrope', fontSize: 13, fontWeight: FontWeight.w700, color: fg),
                        child: const Text('Drive'),
                      ),
                    ],
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
