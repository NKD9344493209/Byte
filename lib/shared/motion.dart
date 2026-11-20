import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'theme.dart';

/// The feel of BYTE, in one place: how long things take to move, the press-
/// back on every tap, the small click under the finger, lists that arrive in
/// a wave, and sheets that rise over glass. Every screen uses these instead
/// of inventing its own.
///
/// Settings: Me → Appearance → Motion (Full / Calm / Off) and Haptics.
/// "Reduce motion" in the phone's accessibility settings counts as Off.
class Motion {
  Motion._();

  static const _kMotion = 'motion';
  static const _kHaptics = 'haptics';

  /// 'full' | 'calm' | 'off'
  static final ValueNotifier<String> mode = ValueNotifier<String>('full');
  static final ValueNotifier<bool> haptics = ValueNotifier<bool>(true);

  static Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    mode.value = p.getString(_kMotion) ?? 'full';
    haptics.value = p.getBool(_kHaptics) ?? true;
  }

  static Future<void> setMode(String v) async {
    mode.value = v;
    (await SharedPreferences.getInstance()).setString(_kMotion, v);
  }

  static Future<void> setHaptics(bool v) async {
    haptics.value = v;
    (await SharedPreferences.getInstance()).setBool(_kHaptics, v);
  }

  /// 1.0 on Full, 0.6 on Calm, 0 on Off (or when the phone asks for less motion).
  static double scale(BuildContext context) {
    if (MediaQuery.maybeDisableAnimationsOf(context) == true) return 0;
    return switch (mode.value) { 'off' => 0, 'calm' => 0.6, _ => 1 };
  }

  static bool off(BuildContext context) => scale(context) == 0;

  /// A duration that respects the setting (never below 1 ms, so controllers
  /// still complete and listeners still fire).
  static Duration d(BuildContext context, int ms) {
    final s = scale(context);
    return Duration(milliseconds: s == 0 ? 1 : (ms * s).round());
  }

  // The curves. Enter: fast start, soft landing. Exit: quick and clean.
  static const Curve enter = Curves.easeOutQuint;
  static const Curve exit = Curves.easeInCubic;
  static const Curve spring = Curves.elasticOut;
  static const Curve move = Curves.easeInOutCubic;
}

/// The small clicks under the finger.
class Haptics {
  Haptics._();

  static bool get _on => Motion.haptics.value;

  /// Any ordinary tap: a row, a chip, a tab.
  static void tap() {
    if (_on) HapticFeedback.selectionClick();
  }

  /// Something happened: saved, ticked, switched.
  static void confirm() {
    if (_on) HapticFeedback.lightImpact();
  }

  /// Something big: done with a burst, deleted.
  static void heavy() {
    if (_on) HapticFeedback.mediumImpact();
  }

  /// Passing a notch (a slider, a scrubber).
  static void tick() {
    if (_on) HapticFeedback.selectionClick();
  }
}

/// Presses back under the finger (0.96, or [pressedScale]) and springs back
/// on release, with a click. Wrap anything tappable that is not a Material
/// button. Keeps the child's own hit area.
class Pressable extends StatefulWidget {
  const Pressable({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.pressedScale = 0.96,
    this.haptic = true,
    this.behavior = HitTestBehavior.opaque,
    this.enabled = true,
  });
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final double pressedScale;
  final bool haptic;
  final HitTestBehavior behavior;
  final bool enabled;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _down = false;

  void _set(bool v) {
    if (_down != v && mounted) setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) {
    final active = widget.enabled && (widget.onTap != null || widget.onLongPress != null);
    final s = Motion.scale(context);
    return GestureDetector(
      behavior: widget.behavior,
      onTapDown: active ? (_) => _set(true) : null,
      onTapCancel: () => _set(false),
      onTapUp: (_) => _set(false),
      onTap: active && widget.onTap != null
          ? () {
              if (widget.haptic) Haptics.tap();
              widget.onTap!();
            }
          : null,
      onLongPress: active && widget.onLongPress != null
          ? () {
              if (widget.haptic) Haptics.confirm();
              widget.onLongPress!();
            }
          : null,
      child: AnimatedScale(
        scale: _down && s > 0 ? widget.pressedScale : 1,
        duration: Duration(milliseconds: _down ? 80 : (s == 0 ? 1 : 320)),
        curve: _down ? Curves.easeOut : Motion.spring,
        child: AnimatedOpacity(
          opacity: _down && s > 0 ? 0.85 : 1,
          duration: const Duration(milliseconds: 80),
          child: widget.child,
        ),
      ),
    );
  }
}

/// Fades and rises a child into place once, [index] × 28 ms after the one
/// before it. Lists wrap their rows with this so content arrives in a wave
/// instead of popping. Animates only on first build.
class Reveal extends StatefulWidget {
  const Reveal({super.key, required this.child, this.index = 0, this.animate = true, this.rise = 12});
  final Widget child;
  final int index;
  final bool animate;
  final double rise;

  @override
  State<Reveal> createState() => _RevealState();
}

class _RevealState extends State<Reveal> with SingleTickerProviderStateMixin {
  AnimationController? _c;

  @override
  void initState() {
    super.initState();
    if (widget.animate) {
      _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 420));
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final s = Motion.scale(context);
        if (s == 0) {
          _c?.value = 1;
          return;
        }
        _c?.duration = Duration(milliseconds: (420 * s).round());
        Future<void>.delayed(Duration(milliseconds: (28 * widget.index.clamp(0, 14) * s).round()), () {
          if (mounted) _c?.forward();
        });
      });
    }
  }

  @override
  void dispose() {
    _c?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    if (c == null) return widget.child;
    final a = CurvedAnimation(parent: c, curve: Motion.enter);
    return FadeTransition(
      opacity: a,
      child: AnimatedBuilder(
        animation: a,
        builder: (_, child) => Transform.translate(offset: Offset(0, (1 - a.value) * widget.rise), child: child),
        child: widget.child,
      ),
    );
  }
}

/// iOS-style switch: a pill whose thumb slides with a little bounce and a
/// click. Same two parameters as [Switch].
class ByteSwitch extends StatelessWidget {
  const ByteSwitch({super.key, required this.value, required this.onChanged});
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final enabled = onChanged != null;
    final s = Motion.scale(context);
    return Semantics(
      toggled: value,
      enabled: enabled,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled
            ? () {
                Haptics.confirm();
                onChanged!(!value);
              }
            : null,
        onHorizontalDragEnd: enabled
            ? (d) {
                final v = d.primaryVelocity ?? 0;
                if (v > 80 && !value) {
                  Haptics.confirm();
                  onChanged!(true);
                } else if (v < -80 && value) {
                  Haptics.confirm();
                  onChanged!(false);
                }
              }
            : null,
        child: Opacity(
          opacity: enabled ? 1 : 0.45,
          child: AnimatedContainer(
            duration: Duration(milliseconds: s == 0 ? 1 : 260),
            curve: Curves.easeOutCubic,
            width: 50,
            height: 30,
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(color: value ? ByteColors.accent : ByteColors.border, borderRadius: BorderRadius.circular(999)),
            child: AnimatedAlign(
              duration: Duration(milliseconds: s == 0 ? 1 : 380),
              curve: s == 0 ? Curves.linear : Motion.spring,
              alignment: value ? Alignment.centerRight : Alignment.centerLeft,
              child: Container(
                width: 26,
                height: 26,
                decoration: BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                  boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.18), blurRadius: 4, offset: const Offset(0, 1))],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A bottom sheet that rises on a spring over a blurred, dimmed page.
/// [builder] gets the sheet's context; return any content (it is wrapped in
/// the rounded panel with a grab handle and the safe area).
Future<T?> showGlassSheet<T>(BuildContext context, {required WidgetBuilder builder, bool dismissible = true}) {
  final s = Motion.scale(context);
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: dismissible,
    barrierLabel: 'Close',
    barrierColor: Colors.transparent,
    transitionDuration: Duration(milliseconds: s == 0 ? 1 : 460),
    pageBuilder: (ctx, a, _) => _GlassSheet(animation: a, dismissible: dismissible, child: Builder(builder: builder)),
    transitionBuilder: (ctx, a, _, child) => child,
  );
}

class _GlassSheet extends StatelessWidget {
  const _GlassSheet({required this.animation, required this.child, required this.dismissible});
  final Animation<double> animation;
  final Widget child;
  final bool dismissible;

  @override
  Widget build(BuildContext context) {
    final rise = CurvedAnimation(parent: animation, curve: Motion.enter, reverseCurve: Motion.exit);
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    final safe = MediaQuery.paddingOf(context).bottom;
    return Material(
      type: MaterialType.transparency,
      child: AnimatedBuilder(
        animation: rise,
        builder: (context, _) {
          final t = rise.value.clamp(0.0, 1.0);
          return Stack(
            children: [
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: dismissible ? () => Navigator.of(context).maybePop() : null,
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 10 * t, sigmaY: 10 * t),
                    child: ColoredBox(color: Colors.black.withValues(alpha: (ByteColors.dark ? 0.5 : 0.28) * t)),
                  ),
                ),
              ),
              Align(
                alignment: Alignment.bottomCenter,
                child: Transform.translate(
                  offset: Offset(0, (1 - t) * 60),
                  child: Opacity(
                    opacity: t,
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(10, 0, 10, 10 + (bottom > 0 ? bottom : safe)),
                      child: Container(
                        width: double.infinity,
                        constraints: const BoxConstraints(maxWidth: 560),
                        decoration: BoxDecoration(
                          color: ByteColors.surface,
                          borderRadius: BorderRadius.circular(28),
                          border: Border.all(color: ByteColors.border),
                          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: ByteColors.dark ? 0.5 : 0.18), blurRadius: 40, offset: const Offset(0, 16))],
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const SizedBox(height: 12),
                            Container(width: 36, height: 4, decoration: BoxDecoration(color: ByteColors.border, borderRadius: BorderRadius.circular(2))),
                            const SizedBox(height: 6),
                            Flexible(child: SingleChildScrollView(child: child)),
                            const SizedBox(height: 8),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Cross-fades (with a 6 px rise) whenever [token] changes: the tab switch.
class TabFade extends StatefulWidget {
  const TabFade({super.key, required this.token, required this.child});
  final Object token;
  final Widget child;

  @override
  State<TabFade> createState() => _TabFadeState();
}

class _TabFadeState extends State<TabFade> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 260), value: 1);

  @override
  void didUpdateWidget(covariant TabFade old) {
    super.didUpdateWidget(old);
    if (old.token != widget.token) {
      final s = Motion.scale(context);
      if (s == 0) return;
      _c.duration = Duration(milliseconds: (260 * s).round());
      _c.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final a = CurvedAnimation(parent: _c, curve: Curves.easeOutCubic);
    return FadeTransition(
      opacity: Tween(begin: 0.6, end: 1.0).animate(a),
      child: AnimatedBuilder(
        animation: a,
        builder: (_, child) => Transform.translate(offset: Offset(0, (1 - a.value) * 6), child: child),
        child: widget.child,
      ),
    );
  }
}

// ───────────── the arrival: edge glow → pool of light → glass ─────────────

/// The bright-green light that runs around the edges of the screen when BYTE
/// is summoned, then gathers at the bottom into a pool the glass window
/// rises out of. Drive it with a 0→1 animation; it ignores touches.
///
/// Cheap on purpose: a few stroked paths and gradients per frame, no blur
/// filters, so a ₹3,000 phone keeps 60 fps.
class EdgeGlow extends StatelessWidget {
  const EdgeGlow({super.key, required this.animation, this.color, this.settle = true});
  final Animation<double> animation;
  final Color? color;

  /// true: the light stays as a soft pool at the bottom (a sheet is coming).
  /// false: it fades away completely (the app just opened).
  final bool settle;

  @override
  Widget build(BuildContext context) {
    final c = color ?? ByteColors.accent;
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: animation,
        builder: (_, _) => CustomPaint(painter: _EdgeGlowPainter(animation.value, c, settle), size: Size.infinite),
      ),
    );
  }
}

class _EdgeGlowPainter extends CustomPainter {
  _EdgeGlowPainter(this.t, this.color, this.settle);
  final double t;
  final Color color;
  final bool settle;

  @override
  void paint(Canvas canvas, Size size) {
    if (t <= 0) return;
    // Phase A (0 → 0.62): the light eases in and makes one slow lap of the edge.
    // Phase B (0.62 → 1): the edges let go and the light gathers at the bottom.
    final a = (t / 0.62).clamp(0.0, 1.0);
    final b = ((t - 0.62) / 0.38).clamp(0.0, 1.0);
    final edgeAlpha = Curves.easeInOutSine.transform(a) * (1 - Curves.easeInOutSine.transform(b));

    if (edgeAlpha > 0.01) {
      final r = RRect.fromRectAndRadius(Rect.fromLTWH(1, 1, size.width - 2, size.height - 2), const Radius.circular(36));
      // A bright arc that travels around the edge during phase A.
      final sweep = SweepGradient(
        center: Alignment.center,
        startAngle: 0,
        endAngle: 6.283185,
        // One unhurried lap, easing in and out — never a flick.
        transform: GradientRotation(-1.5708 + Curves.easeInOutCubic.transform(a) * 6.283185),
        colors: [color.withValues(alpha: 0.22), color.withValues(alpha: 1), color.withValues(alpha: 0.22), color.withValues(alpha: 0.22)],
        stops: const [0, 0.22, 0.55, 1],
      ).createShader(Offset.zero & size);
      // Three strokes of growing width and falling alpha fake a soft bloom.
      for (final (w, k) in const [(26.0, 0.10), (14.0, 0.22), (5.0, 0.95)]) {
        canvas.drawRRect(
          r,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = w * (0.6 + 0.4 * a)
            ..shader = sweep
            ..color = Colors.white.withValues(alpha: k * edgeAlpha),
        );
      }
    }

    // The pool at the bottom: grows through phase B, then stays as a soft
    // floor light while the glass is up.
    var pool = Curves.easeInOutSine.transform(b);
    // Launch glow: the pool breathes in and out again instead of staying.
    if (!settle) pool = pool < 0.5 ? pool * 2 : (1 - pool) * 2;
    if (pool > 0.01) {
      final h = size.height * (0.18 + 0.22 * pool);
      final rect = Rect.fromLTWH(0, size.height - h, size.width, h);
      canvas.drawRect(
        rect,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [color.withValues(alpha: 0.55 * pool), color.withValues(alpha: 0.18 * pool), color.withValues(alpha: 0)],
            stops: const [0, 0.45, 1],
          ).createShader(rect),
      );
      // A brighter core at the bottom centre, where the glass will rise.
      final core = Rect.fromCenter(center: Offset(size.width / 2, size.height), width: size.width * 1.2, height: h * 0.9);
      canvas.drawOval(
        core,
        Paint()
          ..shader = RadialGradient(colors: [color.withValues(alpha: 0.5 * pool), color.withValues(alpha: 0)]).createShader(core),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _EdgeGlowPainter old) => old.t != t || old.color != color || old.settle != settle;
}

/// The mirror-like glass window: a blurred, lightly tinted pane with a thin
/// bright edge on top and a soft diagonal sheen. [child] is the content.
class GlassPanel extends StatelessWidget {
  const GlassPanel({super.key, required this.child, this.radius = 28, this.padding = EdgeInsets.zero});
  final Widget child;
  final double radius;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final dark = ByteColors.dark;
    final blur = Motion.scale(context) == 0 ? 0.0 : (Motion.mode.value == 'calm' ? 10.0 : 18.0);
    final fill = dark ? const Color(0xFF111B21) : Colors.white;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: Stack(
          children: [
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [fill.withValues(alpha: dark ? 0.82 : 0.80), fill.withValues(alpha: dark ? 0.70 : 0.64)],
                  ),
                ),
              ),
            ),
            // The sheen: a soft diagonal band of light, like a reflection.
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: const Alignment(-1, -1),
                    end: const Alignment(1, 1),
                    colors: [Colors.white.withValues(alpha: dark ? 0.08 : 0.35), Colors.white.withValues(alpha: 0), Colors.white.withValues(alpha: dark ? 0.03 : 0.10)],
                    stops: const [0, 0.45, 1],
                  ),
                ),
              ),
            ),
            // The bright hairline along the top edge.
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              height: 1.2,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(colors: [Colors.white.withValues(alpha: 0), Colors.white.withValues(alpha: dark ? 0.45 : 0.9), Colors.white.withValues(alpha: 0)]),
                ),
              ),
            ),
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(radius),
                  border: Border.all(color: Colors.white.withValues(alpha: dark ? 0.12 : 0.55), width: 1),
                ),
              ),
            ),
            Padding(padding: padding, child: child),
          ],
        ),
      ),
    );
  }
}

/// One timeline for a summoned sheet: the glow runs for the first part, the
/// panel rises out of the pool for the rest. Use [glow] for [EdgeGlow] and
/// [rise] for the panel's slide/fade.
class Arrival {
  Arrival(TickerProvider vsync, {int ms = 1700})
      : _ms = ms,
        controller = AnimationController(vsync: vsync, duration: Duration(milliseconds: ms), reverseDuration: const Duration(milliseconds: 260));
  final int _ms;
  final AnimationController controller;

  late final Animation<double> glow = CurvedAnimation(parent: controller, curve: const Interval(0, 1, curve: Curves.linear), reverseCurve: Curves.easeIn);
  late final Animation<double> rise = CurvedAnimation(parent: controller, curve: const Interval(0.58, 1, curve: Curves.easeOutQuint), reverseCurve: Curves.easeInCubic);

  TickerFuture forward(BuildContext context) {
    final s = Motion.scale(context);
    controller.duration = Duration(milliseconds: s == 0 ? 1 : (_ms * (s < 1 ? 0.75 : 1)).round());
    controller.reverseDuration = Duration(milliseconds: s == 0 ? 1 : 260);
    return controller.forward();
  }

  TickerFuture reverse() => controller.reverse();

  void dispose() => controller.dispose();
}
