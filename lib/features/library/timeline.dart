import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../core/user_busy.dart';
import '../../shared/theme.dart';
import '../../shared/ui.dart';
import 'library_item.dart';

/// The timeline every picture list in BYTE is made of: one heading per DAY,
/// pictures as a grid under it, other things as rows — and a handle at the
/// right edge to slide up and down through years in one move.
///
/// Every row has a height that is known before it is built, so a jump to
/// "last March" costs the same as a jump to yesterday.

/// The heading a day falls under: "Today", "Yesterday", "Wed, 18 Nov" (this
/// year), "Sun, 5 Jan 2025" (other years). Pure, so it can be unit-tested.
String timelineLabel(DateTime t, {DateTime? now}) {
  final n = now ?? DateTime.now();
  // Calendar days apart, counted in UTC so a clock change cannot make a day 23 hours long.
  final diff = DateTime.utc(n.year, n.month, n.day).difference(DateTime.utc(t.year, t.month, t.day)).inDays;
  if (diff <= 0) return 'Today';
  if (diff == 1) return 'Yesterday';
  const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  final day = '${days[t.weekday - 1]}, ${t.day} ${months[t.month - 1]}';
  return t.year == n.year ? day : '$day ${t.year}';
}

/// "November 2026" — what the slider shows while you drag it.
String monthLabel(DateTime t) {
  const months = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
  return '${months[t.month - 1]} ${t.year}';
}

/// One row of the timeline.
sealed class TimelineRow {
  const TimelineRow(this.day);

  /// The day (midnight, local time) this row belongs to.
  final DateTime day;
}

/// A day's heading.
final class HeadRow extends TimelineRow {
  const HeadRow(super.day, this.label, this.count);
  final String label;
  final int count;
}

/// Up to [TimelineMetrics.columns] pictures side by side.
final class TilesRow extends TimelineRow {
  const TilesRow(super.day, this.items);
  final List<LibraryItem> items;
}

/// One thing that is not a picture (a document, a note, a voice note, a link).
final class LineRow extends TimelineRow {
  const LineRow(super.day, this.item);
  final LibraryItem item;
}

bool _isPicture(LibraryItem i) => i.kind == LibraryKind.photo || i.kind == LibraryKind.video;

/// Turns a list (newest first) into rows: per day a heading, its pictures in
/// rows of [columns], then its other things. Pure.
List<TimelineRow> timelineRows(List<LibraryItem> items, {int columns = 3, DateTime? now}) {
  final rows = <TimelineRow>[];
  var i = 0;
  while (i < items.length) {
    final t = items[i].createdAt;
    final day = DateTime(t.year, t.month, t.day);
    var j = i;
    while (j < items.length) {
      final u = items[j].createdAt;
      if (u.year != day.year || u.month != day.month || u.day != day.day) break;
      j++;
    }
    final group = items.sublist(i, j);
    rows.add(HeadRow(day, timelineLabel(day, now: now), group.length));
    final pictures = [
      for (final it in group)
        if (_isPicture(it)) it,
    ];
    for (var k = 0; k < pictures.length; k += columns) {
      rows.add(TilesRow(day, pictures.sublist(k, math.min(k + columns, pictures.length))));
    }
    for (final it in group) {
      if (!_isPicture(it)) rows.add(LineRow(day, it));
    }
    i = j;
  }
  return rows;
}

/// The sizes of the rows, for one screen width and font size.
class TimelineMetrics {
  const TimelineMetrics({required this.width, required this.textScale, this.columns = 3});
  final double width;

  /// How much bigger than normal the phone's font is (1.0 = normal).
  final double textScale;
  final int columns;

  static const double gap = 4;

  double get tile => (width - 2 * ByteSpace.page - (columns - 1) * gap) / columns;
  double get head => 32 + 18 * textScale;
  double get line => 26 + math.max(48.0, 44 * textScale);

  double extentOf(TimelineRow r) => switch (r) {
        HeadRow() => head,
        TilesRow() => tile + gap,
        LineRow() => line,
      };

  @override
  bool operator ==(Object other) => other is TimelineMetrics && other.width == width && other.textScale == textScale && other.columns == columns;

  @override
  int get hashCode => Object.hash(width, textScale, columns);
}

/// Rows with their place on the page worked out: which row lies at a height,
/// and how tall the whole list is.
class TimelineLayout {
  TimelineLayout(this.rows, this.metrics) : _tops = _measure(rows, metrics);

  final List<TimelineRow> rows;
  final TimelineMetrics metrics;
  final List<double> _tops; // _tops[i] = where row i starts; one more entry = the end

  static List<double> _measure(List<TimelineRow> rows, TimelineMetrics m) {
    final tops = List<double>.filled(rows.length + 1, 0);
    var y = 0.0;
    for (var i = 0; i < rows.length; i++) {
      tops[i] = y;
      y += m.extentOf(rows[i]);
    }
    tops[rows.length] = y;
    return tops;
  }

  double get height => _tops[rows.length];

  /// How tall row [i] is (null when there is no such row).
  double? extentAt(int i) => i >= 0 && i < rows.length ? _tops[i + 1] - _tops[i] : null;

  /// The row at [y] (measured from the top of the list), or null when empty.
  TimelineRow? rowAt(double y) {
    if (rows.isEmpty) return null;
    var lo = 0;
    var hi = rows.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (_tops[mid] <= y) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return rows[lo];
  }
}

/// The rows as a sliver (put it into a CustomScrollView).
class TimelineSliver extends StatelessWidget {
  const TimelineSliver({super.key, required this.layout, required this.tile, required this.line});
  final TimelineLayout layout;

  /// One picture square.
  final Widget Function(LibraryItem item) tile;

  /// One row for a thing that is not a picture.
  final Widget Function(LibraryItem item) line;

  @override
  Widget build(BuildContext context) {
    final rows = layout.rows;
    final m = layout.metrics;
    return SliverVariedExtentList(
      itemExtentBuilder: (i, _) => layout.extentAt(i),
      delegate: _ExactHeightDelegate(
        height: layout.height,
        childCount: rows.length,
        (context, i) {
        final r = rows[i];
        switch (r) {
          case HeadRow():
            return Padding(
              padding: const EdgeInsets.fromLTRB(ByteSpace.page, 0, ByteSpace.page, 6),
              child: Align(
                alignment: Alignment.bottomLeft,
                child: Row(
                  children: [
                    Expanded(child: Text(r.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.labelMedium?.copyWith(color: ByteColors.text))),
                    Meta('${r.count}'),
                  ],
                ),
              ),
            );
          case TilesRow():
            return Padding(
              padding: const EdgeInsets.fromLTRB(ByteSpace.page, 0, ByteSpace.page, TimelineMetrics.gap),
              child: Row(
                children: [
                  for (var k = 0; k < r.items.length; k++) ...[
                    if (k > 0) const SizedBox(width: TimelineMetrics.gap),
                    SizedBox(width: m.tile, height: m.tile, child: tile(r.items[k])),
                  ],
                ],
              ),
            );
          case LineRow():
            return line(r.item);
        }
        },
      ),
    );
  }
}

/// Tells the list its true height. (Flutter otherwise guesses it from the
/// rows on screen, and the slider and its month label would drift.)
class _ExactHeightDelegate extends SliverChildBuilderDelegate {
  const _ExactHeightDelegate(super.builder, {required this.height, super.childCount});
  final double height;

  @override
  double? estimateMaxScrollOffset(int firstIndex, int lastIndex, double leadingScrollOffset, double trailingScrollOffset) => height;
}

/// Loads a long list in pieces: a first small one so the screen fills at
/// once, then the rest in the background (stepping aside while the screen is
/// touched), so the slider can reach every year.
///
/// [fetch] gets (limit, offset). [stale] says "a newer load has started —
/// stop". [onPiece] gets everything loaded so far and whether that is all.
Future<void> loadInPieces({
  required Future<List<LibraryItem>> Function(int limit, int offset) fetch,
  required bool Function() stale,
  required void Function(List<LibraryItem> soFar, bool done) onPiece,
  int first = 300,
  int piece = 1500,
  int cap = 30000,
}) async {
  final all = <LibraryItem>[];
  final ids = <String>{};
  var offset = 0;
  var size = first;
  while (true) {
    // One more than wanted: the extra row only says "there is more".
    final rows = await fetch(size + 1, offset);
    if (stale()) return;
    final more = rows.length > size;
    final take = more ? rows.sublist(0, size) : rows;
    offset += take.length;
    // (Something added or removed between two pieces must not show twice.)
    for (final it in take) {
      if (ids.add(it.id)) all.add(it);
    }
    final done = !more || all.length >= cap;
    onPiece(List<LibraryItem>.of(all), done);
    if (done) return;
    size = piece;
    await UserBusy.whenIdle(quietMs: 250, maxWaitMs: 1500);
    if (stale()) return;
  }
}

/// The slider: a handle at the right edge of a long list. It shows while you
/// scroll; drag it to move through the whole list in one go. While you drag,
/// a small label says where you are ("November 2026").
class FastScroller extends StatefulWidget {
  const FastScroller({super.key, required this.controller, required this.child, this.labelAt, this.bottomInset = 0});
  final ScrollController controller;
  final Widget child;

  /// What the label says for a scroll position (in pixels), or '' for none.
  final String Function(double pixels)? labelAt;

  /// Room kept free at the bottom (a floating button).
  final double bottomInset;

  @override
  State<FastScroller> createState() => _FastScrollerState();
}

class _FastScrollerState extends State<FastScroller> {
  static const double _handleHeight = 48;
  static const double _handleWidth = 30;
  static const double _topGap = 8;

  bool _shown = false;
  bool _dragging = false;
  Timer? _hide;

  /// Where on the handle the finger took hold (so the list does not jump).
  double _grab = 0;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onScroll);
  }

  @override
  void didUpdateWidget(covariant FastScroller old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_onScroll);
      widget.controller.addListener(_onScroll);
    }
  }

  @override
  void dispose() {
    _hide?.cancel();
    widget.controller.removeListener(_onScroll);
    super.dispose();
  }

  void _onScroll() {
    if (!mounted) return;
    // A list can move while the screen is being laid out; the handle then
    // follows right after that frame.
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _show();
      });
    } else {
      _show();
    }
  }

  void _show() {
    _hide?.cancel();
    if (!_dragging) {
      _hide = Timer(const Duration(milliseconds: 1800), () {
        if (mounted && !_dragging) setState(() => _shown = false);
      });
    }
    // The handle follows the list.
    setState(() => _shown = true);
  }

  /// How far the list can scroll, or 0 when it is not laid out yet.
  double get _max {
    final c = widget.controller;
    if (!c.hasClients || !c.position.hasContentDimensions) return 0;
    return c.position.maxScrollExtent;
  }

  void _dragTo(Offset global, double travel) {
    final box = context.findRenderObject();
    if (box is! RenderBox || travel <= 0) return;
    final y = box.globalToLocal(global).dy - _grab;
    final f = ((y - _topGap - _handleHeight / 2) / travel).clamp(0.0, 1.0);
    final max = _max;
    if (max > 0) widget.controller.jumpTo(f * max);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final max = _max;
        final c = widget.controller;
        // Only for lists worth sliding through (more than three screens).
        final worth = max > 0 && c.hasClients && max > c.position.viewportDimension * 2;
        final travel = box.maxHeight - _topGap - _handleHeight - 8 - widget.bottomInset;
        final f = worth ? (c.position.pixels / max).clamp(0.0, 1.0) : 0.0;
        final top = _topGap + f * (travel > 0 ? travel : 0);
        final visible = worth && travel > 0 && (_shown || _dragging);
        final label = _dragging && worth ? (widget.labelAt?.call(c.position.pixels) ?? '') : '';
        return Stack(
          children: [
            widget.child,
            if (label.isNotEmpty)
              Positioned(
                right: _handleWidth + 14,
                top: top + 6,
                child: IgnorePointer(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    decoration: BoxDecoration(color: ByteColors.text, borderRadius: BorderRadius.circular(999)),
                    child: Text(label, style: TextStyle(color: ByteColors.bg, fontSize: 14, fontWeight: FontWeight.w700)),
                  ),
                ),
              ),
            Positioned(
              right: 0,
              top: top,
              child: IgnorePointer(
                ignoring: !visible,
                child: AnimatedOpacity(
                  opacity: visible ? 1 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onVerticalDragStart: (d) {
                      _hide?.cancel();
                      final me = context.findRenderObject();
                      _grab = me is RenderBox ? me.globalToLocal(d.globalPosition).dy - (top + _handleHeight / 2) : 0;
                      setState(() => _dragging = true);
                    },
                    onVerticalDragUpdate: (d) => _dragTo(d.globalPosition, travel),
                    onVerticalDragEnd: (_) {
                      setState(() => _dragging = false);
                      _onScroll(); // starts the countdown to hide
                    },
                    onVerticalDragCancel: () => setState(() => _dragging = false),
                    child: SizedBox(
                      width: _handleWidth + 12,
                      height: _handleHeight,
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: Container(
                          width: _handleWidth,
                          height: _handleHeight,
                          decoration: BoxDecoration(
                            color: _dragging ? ByteColors.accentBright : ByteColors.surface,
                            borderRadius: const BorderRadius.horizontal(left: Radius.circular(16)),
                            border: Border.all(color: _dragging ? ByteColors.accentBright : ByteColors.border),
                            boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.18), blurRadius: 8, offset: const Offset(0, 2))],
                          ),
                          child: Icon(Icons.unfold_more_rounded, size: 20, color: _dragging ? ByteColors.onAccent : ByteColors.textDim),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
