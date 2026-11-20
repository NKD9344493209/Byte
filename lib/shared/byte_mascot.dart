import 'package:flutter/material.dart';

import 'theme.dart';

enum ByteMood { happy, neutral, sad, excited }

/// Placeholder mascot: a rounded "byte" face drawn with code.
/// Replaced by real artwork later; the API (mood + size) stays the same.
class ByteMascot extends StatelessWidget {
  const ByteMascot({super.key, this.mood = ByteMood.happy, this.size = 96});

  final ByteMood mood;
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _MascotPainter(mood)),
    );
  }
}

class _MascotPainter extends CustomPainter {
  _MascotPainter(this.mood);
  final ByteMood mood;

  @override
  void paint(Canvas canvas, Size size) {
    final r = size.width / 2;
    final c = Offset(r, r);

    // Glow
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..color = ByteColors.accent.withValues(alpha: 0.15)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12),
    );
    // Body
    final body = RRect.fromRectAndRadius(
      Rect.fromCircle(center: c, radius: r * 0.78),
      Radius.circular(r * 0.4),
    );
    canvas.drawRRect(body, Paint()..color = ByteColors.accent);

    // Eyes
    final eyePaint = Paint()..color = Colors.white;
    final eyeY = r * 0.85;
    final eyeDx = r * 0.3;
    final eyeR = r * 0.09;
    switch (mood) {
      case ByteMood.sad:
        canvas.drawCircle(Offset(r - eyeDx, eyeY + 4), eyeR, eyePaint);
        canvas.drawCircle(Offset(r + eyeDx, eyeY + 4), eyeR, eyePaint);
      case ByteMood.excited:
        canvas.drawCircle(Offset(r - eyeDx, eyeY), eyeR * 1.4, eyePaint);
        canvas.drawCircle(Offset(r + eyeDx, eyeY), eyeR * 1.4, eyePaint);
      default:
        canvas.drawCircle(Offset(r - eyeDx, eyeY), eyeR, eyePaint);
        canvas.drawCircle(Offset(r + eyeDx, eyeY), eyeR, eyePaint);
    }

    // Mouth
    final mouth = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = r * 0.07
      ..strokeCap = StrokeCap.round;
    final mouthRect = Rect.fromCenter(
      center: Offset(r, r * 1.2),
      width: r * 0.6,
      height: r * 0.35,
    );
    switch (mood) {
      case ByteMood.sad:
        canvas.drawArc(mouthRect.shift(Offset(0, r * 0.2)), 3.3, 2.8, false,
            mouth);
      case ByteMood.neutral:
        canvas.drawLine(
          Offset(r - r * 0.25, r * 1.22),
          Offset(r + r * 0.25, r * 1.22),
          mouth,
        );
      case ByteMood.excited:
        canvas.drawArc(mouthRect, 0.2, 2.7, false, mouth);
      case ByteMood.happy:
        canvas.drawArc(mouthRect, 0.3, 2.5, false, mouth);
    }
  }

  @override
  bool shouldRepaint(covariant _MascotPainter old) => old.mood != mood;
}
