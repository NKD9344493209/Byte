import 'package:flutter/material.dart';

import 'motion.dart';
import 'theme.dart';

/// The handful of building blocks every BYTE screen is made of, so screens
/// stop inventing their own. Lists with hairlines for information; cards
/// only for things; one label style; one search box.

/// Big page title ("Notes", "Library", "Money").
class PageTitle extends StatelessWidget {
  const PageTitle(this.text, {super.key, this.trailing, this.top = 12});
  final String text;
  final Widget? trailing;
  final double top;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(ByteSpace.page, top, ByteSpace.page, 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(child: Text(text, style: Theme.of(context).textTheme.displaySmall)),
          ?trailing,
        ],
      ),
    );
  }
}

/// Quiet section label — sentence case, dim, never shouting.
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key, this.trailing, this.top = 28});
  final String text;
  final Widget? trailing;
  final double top;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(ByteSpace.page, top, ByteSpace.page - 8, 6),
      child: Row(
        children: [
          Expanded(child: Text(text, style: Theme.of(context).textTheme.labelMedium)),
          ?trailing,
        ],
      ),
    );
  }
}

/// A rounded icon well at the left of a row. [tone]: plain | act | hey | danger.
class IconWell extends StatelessWidget {
  const IconWell(this.icon, {super.key, this.tone = 'plain', this.size = 36});
  final IconData icon;
  final String tone;
  final double size;

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = switch (tone) {
      'act' => (ByteColors.accentSoft, ByteColors.accentDim),
      'hey' => (ByteColors.heySoft, ByteColors.heyInk),
      'danger' => (ByteColors.dangerSoft, ByteColors.danger),
      _ => (ByteColors.surface2, ByteColors.textDim),
    };
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(size / 3)),
      alignment: Alignment.center,
      child: Icon(icon, size: size * 0.5, color: fg),
    );
  }
}

/// One line of a list: optional icon well, title, caption, trailing. Hairline
/// below. Tap and long-press.
class ByteRow extends StatelessWidget {
  const ByteRow({
    super.key,
    required this.title,
    this.subtitle,
    this.icon,
    this.tone = 'plain',
    this.leading,
    this.trailing,
    this.onTap,
    this.onLongPress,
    this.chevron = false,
    this.titleWeight = FontWeight.w700,
    this.hairline = true,
    this.selected = false,
    this.titleLines = 2,
    this.subtitleLines = 2,
  });

  /// How many lines the title and the caption may take.
  final int titleLines;
  final int subtitleLines;
  final String title;
  final String? subtitle;
  final IconData? icon;
  final String tone;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool chevron;
  final FontWeight titleWeight;
  final bool hairline;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Pressable(
      onTap: onTap,
      onLongPress: onLongPress,
      pressedScale: 0.985,
      child: Container(
        decoration: BoxDecoration(
          color: selected ? ByteColors.accentSoft : null,
          border: hairline ? Border(bottom: BorderSide(color: ByteColors.border)) : null,
        ),
        constraints: const BoxConstraints(minHeight: 60),
        padding: const EdgeInsets.symmetric(horizontal: ByteSpace.page, vertical: 12),
        child: Row(
          children: [
            if (leading != null) ...[leading!, const SizedBox(width: 14)] else if (icon != null) ...[IconWell(icon!, tone: tone), const SizedBox(width: 14)],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(title, maxLines: titleLines, overflow: TextOverflow.ellipsis, style: tt.titleMedium?.copyWith(fontWeight: titleWeight)),
                  if (subtitle != null && subtitle!.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(subtitle!, maxLines: subtitleLines, overflow: TextOverflow.ellipsis, style: tt.bodySmall),
                  ],
                ],
              ),
            ),
            if (trailing != null) ...[const SizedBox(width: 12), trailing!],
            if (chevron) ...[const SizedBox(width: 8), Icon(Icons.chevron_right_rounded, color: ByteColors.textFaint)],
          ],
        ),
      ),
    );
  }
}

/// A list of [ByteRow]s with a hairline on top. The rows arrive in a small
/// wave the first time the list appears; later rebuilds don't re-animate.
class ByteList extends StatefulWidget {
  const ByteList({super.key, required this.children, this.topLine = true, this.wave = true});
  final List<Widget> children;
  final bool topLine;
  final bool wave;

  @override
  State<ByteList> createState() => _ByteListState();
}

class _ByteListState extends State<ByteList> {
  /// True until the first frame is on screen. Rows are *always* wrapped in a
  /// [Reveal] (so the element tree never changes shape and stateful rows such
  /// as a Dismissible keep their state); only the stagger changes: rows that
  /// appear later arrive without the wave delay.
  bool _first = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _first = false; // no setState: Reveal reads index/animate once, in initState
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: widget.topLine ? BoxDecoration(border: Border(top: BorderSide(color: ByteColors.border))) : null,
      child: Column(
        children: [
          for (var i = 0; i < widget.children.length; i++)
            Reveal(
              // Carry the row's key up so sibling diffing (Dismissible rows) still works.
              key: widget.children[i].key == null ? null : ValueKey<Object>(('reveal', widget.children[i].key)),
              index: _first ? i : 0,
              animate: widget.wave,
              child: widget.children[i],
            ),
        ],
      ),
    );
  }
}

/// Small, right-aligned time or count beside a row.
class Meta extends StatelessWidget {
  const Meta(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) => Text(text, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: ByteColors.textFaint));
}

/// The search box every list screen opens with.
class QuietSearch extends StatelessWidget {
  const QuietSearch({super.key, required this.controller, required this.hint, this.autofocus = false, this.onChanged});
  final TextEditingController controller;
  final String hint;
  final bool autofocus;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(ByteSpace.page, 8, ByteSpace.page, 0),
      child: ListenableBuilder(
        listenable: controller,
        builder: (_, _) => TextField(
          controller: controller,
          autofocus: autofocus,
          onChanged: onChanged,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            hintText: hint,
            prefixIcon: Icon(Icons.search_rounded, color: ByteColors.textFaint),
            suffixIcon: controller.text.isEmpty ? null : IconButton(icon: const Icon(Icons.close_rounded), onPressed: controller.clear),
          ),
        ),
      ),
    );
  }
}

/// Filter chips in one scrolling line ("All · Photos 118 · Videos 9").
class ChipRow extends StatelessWidget {
  const ChipRow({super.key, required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: ByteSpace.page, vertical: 4),
        itemCount: children.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (_, i) => children[i],
      ),
    );
  }
}

/// One filter chip. Selected = ink pill with paper text.
class Pill extends StatelessWidget {
  const Pill(this.label, {super.key, required this.selected, required this.onTap, this.count, this.dot = false});
  final String label;
  final int? count;

  /// A small green dot: something new is in there.
  final bool dot;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = count == null || count == 0 ? label : '$label $count';
    return Pressable(
      onTap: onTap,
      pressedScale: 0.94,
      child: AnimatedContainer(
        duration: Motion.d(context, 220),
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? ByteColors.text : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: selected ? ByteColors.text : ByteColors.border),
        ),
        child: AnimatedDefaultTextStyle(
          duration: Motion.d(context, 220),
          style: TextStyle(fontFamily: 'Manrope', fontSize: 13, fontWeight: FontWeight.w700, color: selected ? ByteColors.bg : ByteColors.textDim),
          child: dot
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(width: 7, height: 7, margin: const EdgeInsets.only(right: 6), decoration: BoxDecoration(color: ByteColors.accentBright, shape: BoxShape.circle)),
                    Text(text),
                  ],
                )
              : Text(text),
        ),
      ),
    );
  }
}

/// A small inline yes/no pair used in "Needs you" lines.
class YesNo extends StatelessWidget {
  const YesNo({super.key, required this.onYes, required this.onNo, this.yes = 'Yes', this.no = 'No'});
  final VoidCallback onYes;
  final VoidCallback onNo;
  final String yes;
  final String no;

  @override
  Widget build(BuildContext context) {
    Widget b(String t, bool primary, VoidCallback f) => Pressable(
          onTap: () {
            if (primary) Haptics.confirm();
            f();
          },
          haptic: !primary,
          pressedScale: 0.92,
          child: Container(
            decoration: ShapeDecoration(
              color: primary ? ByteColors.accentSoft : Colors.transparent,
              shape: StadiumBorder(side: BorderSide(color: primary ? Colors.transparent : ByteColors.border)),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
            child: Text(t, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: primary ? ByteColors.accentDim : ByteColors.text)),
          ),
        );
    return Row(mainAxisSize: MainAxisSize.min, children: [b(yes, true, onYes), const SizedBox(width: 6), b(no, false, onNo)]);
  }
}

/// A quiet well at the page gutter for the things that are not a plain row:
/// a radio group, a slider, a paragraph.
class Well extends StatelessWidget {
  const Well({super.key, required this.child, this.padding = const EdgeInsets.all(16)});
  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: ByteSpace.page),
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(color: ByteColors.surface2, borderRadius: BorderRadius.circular(ByteSpace.rm)),
        padding: padding,
        child: child,
      ),
    );
  }
}

/// Empty state: a sentence and, when useful, one action. Never a mascot alone.
class EmptyNote extends StatelessWidget {
  const EmptyNote(this.text, {super.key, this.action, this.onAction, this.second, this.onSecond});
  final String text;
  final String? action;
  final VoidCallback? onAction;

  /// A second thing to start with, beside the first.
  final String? second;
  final VoidCallback? onSecond;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(ByteSpace.page, 24, ByteSpace.page, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(text, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: ByteColors.textDim)),
          if (action != null && onAction != null) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.tonal(style: inlineButton, onPressed: onAction, child: Text(action!)),
                if (second != null && onSecond != null) FilledButton.tonal(style: inlineButton, onPressed: onSecond, child: Text(second!)),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
