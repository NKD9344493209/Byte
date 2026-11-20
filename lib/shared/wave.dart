import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'theme.dart';

/// Amber bars that breathe while BYTE listens or records (plain bars when
/// animations are off). Pass an [animation] to share a ticker you already
/// run; leave it out and the wave keeps its own. [level] (0–1, the mic)
/// makes the bars rise with your voice.
class ListeningWave extends StatefulWidget {
  const ListeningWave({
    super.key,
    this.animation,
    this.level,
    this.height = 36,
    this.bars = 24,
    this.color,
    this.alignment = MainAxisAlignment.start,
  });

  final Animation<double>? animation;
  final double? level;
  final double height;
  final int bars;

  /// Defaults to [ByteColors.hey].
  final Color? color;
  final MainAxisAlignment alignment;

  @override
  State<ListeningWave> createState() => _ListeningWaveState();
}

class _ListeningWaveState extends State<ListeningWave> with SingleTickerProviderStateMixin {
  AnimationController? _own;

  Animation<double> get _anim => widget.animation ?? _own!;

  @override
  void initState() {
    super.initState();
    if (widget.animation == null) {
      _own = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..repeat();
    }
  }

  @override
  void dispose() {
    _own?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduce = MediaQuery.of(context).disableAnimations;
    final color = widget.color ?? ByteColors.hey;
    final amp = widget.height - 12;
    final double gain = widget.level == null ? 1.0 : 0.35 + 0.65 * widget.level!.clamp(0.0, 1.0).toDouble();
    return SizedBox(
      height: widget.height,
      child: AnimatedBuilder(
        animation: _anim,
        builder: (_, _) => Row(
          mainAxisAlignment: widget.alignment,
          children: [
            for (var i = 0; i < widget.bars; i++) ...[
              Container(
                width: 4,
                height: reduce ? widget.height * 0.4 : 8 + amp * gain * (0.5 + 0.5 * math.sin(_anim.value * 6.28 + i * 0.7)).abs(),
                decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2)),
              ),
              if (i < widget.bars - 1) const SizedBox(width: 4),
            ],
          ],
        ),
      ),
    );
  }
}
