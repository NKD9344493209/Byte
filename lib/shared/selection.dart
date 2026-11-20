import 'package:flutter/material.dart';

import 'theme.dart';

/// Long-press multi-select, shared by every list in BYTE.
/// Long-press starts it, tap toggles, the bar on top acts on all selected.
class Selection extends ChangeNotifier {
  final Set<String> ids = <String>{};

  bool get active => ids.isNotEmpty;
  int get count => ids.length;
  bool contains(String id) => ids.contains(id);

  void toggle(String id) {
    if (!ids.remove(id)) ids.add(id);
    notifyListeners();
  }

  void setAll(Iterable<String> all) {
    ids
      ..clear()
      ..addAll(all);
    notifyListeners();
  }

  void clear() {
    if (ids.isEmpty) return;
    ids.clear();
    notifyListeners();
  }
}

/// Back, while things are selected, only takes the selection away (it does
/// not leave the screen or close BYTE). Wrap a screen's Scaffold with it.
class SelectionBack extends StatelessWidget {
  const SelectionBack({super.key, required this.sel, required this.child});
  final Selection sel;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: sel,
      builder: (context, child) => PopScope(
        canPop: !sel.active,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) sel.clear();
        },
        child: child!,
      ),
      child: child,
    );
  }
}

/// App bar shown while selecting: "3 selected", select-all, and actions.
AppBar selectionAppBar({
  required Selection sel,
  required List<String> allIds,
  required List<Widget> actions,
}) {
  return AppBar(
    leading: IconButton(
      tooltip: 'Cancel',
      icon: const Icon(Icons.close_rounded),
      onPressed: sel.clear,
    ),
    titleSpacing: 0,
    title: Text('${sel.count} selected', maxLines: 1, softWrap: false, overflow: TextOverflow.fade),
    actions: [
      if (sel.count < allIds.length)
        IconButton(
          tooltip: 'Select all',
          icon: const Icon(Icons.select_all_rounded),
          onPressed: () => sel.setAll(allIds),
        ),
      ...actions,
    ],
  );
}

/// A tick beside (or in the corner of) a selected item.
class SelectedBadge extends StatelessWidget {
  const SelectedBadge({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 22,
      height: 22,
      decoration: BoxDecoration(color: ByteColors.accent, shape: BoxShape.circle),
      child: Icon(Icons.check_rounded, size: 16, color: ByteColors.onAccent),
    );
  }
}

/// Wraps a card: tint + badge when selected, long-press to start selecting.
class Selectable extends StatelessWidget {
  const Selectable({
    super.key,
    required this.selected,
    required this.onLongPress,
    required this.onTap,
    required this.child,
  });

  final bool selected;
  final VoidCallback onLongPress;
  final VoidCallback? onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPress: onLongPress,
      onTap: onTap,
      child: Stack(
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(ByteSpace.rm),
              border: Border.all(
                color: selected ? ByteColors.accent : Colors.transparent,
                width: 1.5,
              ),
            ),
            child: child,
          ),
          if (selected)
            const Positioned(top: 8, right: 8, child: SelectedBadge()),
        ],
      ),
    );
  }
}

/// Standard "delete N?" confirmation.
Future<bool> confirmBulk(
  BuildContext context, {
  required String title,
  required String body,
  String action = 'Delete',
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(body, style: Theme.of(ctx).textTheme.bodyMedium?.copyWith(color: ByteColors.textDim)),
      actions: [
        TextButton(style: inlineButton, onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        TextButton(
          style: inlineButton,
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(action, style: TextStyle(color: ByteColors.danger)),
        ),
      ],
    ),
  );
  return ok == true;
}
