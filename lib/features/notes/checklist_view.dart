import 'package:flutter/material.dart';

import '../../core/bubble.dart';
import '../../shared/motion.dart';
import '../../shared/theme.dart';
import 'checklist.dart';

/// A note's body shown as a checklist: tick, rename, add a step under a
/// task, set a reminder, remove. The body stays plain text; every change is
/// handed back whole through [onChanged].
class ChecklistView extends StatelessWidget {
  const ChecklistView({super.key, required this.body, required this.onChanged, this.bottomPadding = 24});

  final String body;
  final ValueChanged<String> onChanged;
  final double bottomPadding;

  /// One line of text from the user, or null when cancelled.
  static Future<String?> askLine(BuildContext context, {required String title, String initial = '', String action = 'Save'}) async {
    final ctl = TextEditingController(text: initial);
    final v = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctl,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(style: inlineButton, onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(style: inlineButton, onPressed: () => Navigator.pop(ctx, ctl.text), child: Text(action)),
        ],
      ),
    );
    // The dialog is still closing for a moment and uses the controller meanwhile.
    Future<void>.delayed(const Duration(seconds: 1), ctl.dispose);
    final t = v?.trim() ?? '';
    return t.isEmpty ? null : t;
  }

  /// [now]: the task as it is written (maybe with a reminder, which stays).
  Future<void> _rename(BuildContext context, int task, String now) async {
    final words = plainTask(now);
    final t = await askLine(context, title: 'Change this item', initial: words);
    if (t != null && t != words) onChanged(renameTask(body, task, withDue(t, dueOf(now))));
  }

  static const _weekdays = ['monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday', 'sunday'];

  /// The "+" beside a heading: items for that section ("gym, call amma" is two).
  Future<void> _addUnder(BuildContext context, int line, String heading) async {
    final t = await askLine(context, title: 'Add under $heading', action: 'Add');
    if (t == null) return;
    var next = body;
    // (Each one goes below the one before it.)
    for (final task in tasksFromTyped(t)) {
      next = addTaskUnderLine(next, line, task);
    }
    if (next != body) onChanged(next);
  }

  /// "Remind me": a few ready times, or any day and time.
  Future<void> _remind(BuildContext context, int task, String now) async {
    final messenger = ScaffoldMessenger.of(context);
    final has = dueOf(now);
    final n = DateTime.now();
    final inAnHour = DateTime(n.year, n.month, n.day, n.hour, n.minute).add(const Duration(hours: 1));
    final evening = DateTime(n.year, n.month, n.day, 18);
    final tomorrow = DateTime(n.year, n.month, n.day + 1, 9);
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(plainTask(now), maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(has == null ? 'When should BYTE remind you?' : 'Reminder: ${dueLabel(has)}'),
            ),
            ListTile(leading: const Icon(Icons.timer_outlined), title: const Text('In 1 hour'), subtitle: Text(dueLabel(inAnHour)), onTap: () => Navigator.pop(ctx, 'hour')),
            if (n.isBefore(evening.subtract(const Duration(minutes: 30))))
              ListTile(leading: const Icon(Icons.wb_twilight_rounded), title: const Text('This evening'), subtitle: Text(dueLabel(evening)), onTap: () => Navigator.pop(ctx, 'evening')),
            ListTile(leading: const Icon(Icons.wb_sunny_outlined), title: const Text('Tomorrow morning'), subtitle: Text(dueLabel(tomorrow)), onTap: () => Navigator.pop(ctx, 'tomorrow')),
            ListTile(leading: const Icon(Icons.event_outlined), title: const Text('Pick a day and time'), onTap: () => Navigator.pop(ctx, 'pick')),
            if (has != null)
              ListTile(leading: Icon(Icons.notifications_off_outlined, color: ByteColors.danger), title: Text('No reminder', style: TextStyle(color: ByteColors.danger)), onTap: () => Navigator.pop(ctx, 'none')),
          ],
        ),
      ),
    );
    if (choice == null || !context.mounted) return;
    DateTime? at;
    switch (choice) {
      case 'hour':
        at = inAnHour;
      case 'evening':
        at = evening;
      case 'tomorrow':
        at = tomorrow;
      case 'pick':
        final from = has != null && has.isAfter(n) ? has : inAnHour;
        final day = await showDatePicker(
          context: context,
          initialDate: DateTime(from.year, from.month, from.day),
          firstDate: DateTime(n.year, n.month, n.day),
          lastDate: DateTime(n.year + 5, 12, 31),
        );
        if (day == null || !context.mounted) return;
        final time = await showTimePicker(context: context, initialTime: TimeOfDay(hour: from.hour, minute: from.minute));
        if (time == null || !context.mounted) return;
        at = DateTime(day.year, day.month, day.day, time.hour, time.minute);
      default:
        at = null; // 'none'
    }
    onChanged(setTaskDue(body, task, at));
    if (at == null) return;
    // A reminder is a notification: Android asks once whether BYTE may show them.
    final allowed = await Bubble.askNotifications();
    if (!allowed && Bubble.supported) {
      messenger.showSnackBar(const SnackBar(content: Text('Notifications are off for BYTE, so the reminder cannot show. Allow them in the phone\'s settings.')));
    }
  }

  Future<void> _addStep(BuildContext context, int task) async {
    final t = await askLine(context, title: 'Add a step under this', action: 'Add');
    if (t != null) onChanged(addTask(body, t, underTask: task));
  }

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final lines = parseLines(body);
    final (done, total) = checklistProgress(body);

    final rows = <Widget>[];
    if (total > 0) {
      rows.add(Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 10),
        child: Row(
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: done / total,
                  minHeight: 4,
                  backgroundColor: ByteColors.border,
                  color: ByteColors.accent,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Text(done == total ? 'All $total done' : '$done of $total done', style: tt.bodySmall),
          ],
        ),
      ));
    }

    var task = -1;
    for (var k = 0; k < lines.length; k++) {
      final l = lines[k];
      if (!l.isTask) {
        // Ordinary lines of the note stay where they are, between the tasks.
        // One with words is a heading ("Monday"): its "+" adds an item under it.
        if (l.text.trim().isEmpty) {
          rows.add(const SizedBox(height: 8));
          continue;
        }
        final line = k;
        final heading = l.text.trim();
        final today = heading.toLowerCase() == _weekdays[DateTime.now().weekday - 1];
        rows.add(Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  today ? '$heading · today' : heading,
                  style: tt.titleSmall?.copyWith(color: today ? ByteColors.accentDim : ByteColors.textDim, fontWeight: FontWeight.w700),
                ),
              ),
              IconButton(
                tooltip: 'Add under $heading',
                visualDensity: VisualDensity.compact,
                icon: Icon(Icons.add_rounded, color: ByteColors.textFaint, size: 20),
                onPressed: () => _addUnder(context, line, heading),
              ),
            ],
          ),
        ));
        continue;
      }
      task++;
      final index = task;
      rows.add(_TaskRow(
        key: ValueKey('task-$index-${l.level}'),
        line: l,
        hasSteps: l.level == 0 && k + 1 < lines.length && lines[k + 1].isTask && lines[k + 1].level == 1,
        onTick: () {
          Haptics.confirm();
          onChanged(setTaskDone(body, index));
        },
        onRename: () => _rename(context, index, l.text),
        onRemind: () => _remind(context, index, l.text),
        onAddStep: () => _addStep(context, index),
        onRemove: () => onChanged(removeTask(body, index)),
      ));
    }

    if (total == 0 && rows.isEmpty) {
      rows.add(Padding(
        padding: const EdgeInsets.only(top: 24),
        child: Text('Nothing on the list yet. Type the first item below.', style: tt.bodyLarge?.copyWith(color: ByteColors.textFaint)),
      ));
    }

    return ListView(
      padding: EdgeInsets.only(bottom: bottomPadding),
      children: rows,
    );
  }
}

class _TaskRow extends StatelessWidget {
  const _TaskRow({super.key, required this.line, required this.hasSteps, required this.onTick, required this.onRename, required this.onRemind, required this.onAddStep, required this.onRemove});

  final NoteLine line;
  final bool hasSteps;
  final VoidCallback onTick;
  final VoidCallback onRename;
  final VoidCallback onRemind;
  final VoidCallback onAddStep;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final sub = line.level > 0;
    final words = plainTask(line.text);
    final due = dueOf(line.text);
    // Red once its time has passed and it is still not done.
    final dueColor = line.done ? ByteColors.textFaint : (due != null && due.isBefore(DateTime.now()) ? ByteColors.danger : ByteColors.accentDim);
    final box = AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOutCubic,
      width: sub ? 20 : 24,
      height: sub ? 20 : 24,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: line.done ? ByteColors.accent : Colors.transparent,
        border: Border.all(color: line.done ? ByteColors.accent : ByteColors.textFaint, width: 1.6),
      ),
      child: line.done ? Icon(Icons.check_rounded, size: sub ? 14 : 16, color: ByteColors.onAccent) : null,
    );
    return Padding(
      padding: EdgeInsets.only(left: sub ? 34 : 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // A finger-sized target around the small circle.
          Semantics(
            checked: line.done,
            label: words,
            child: InkResponse(
              onTap: onTick,
              radius: 24,
              child: Padding(padding: const EdgeInsets.fromLTRB(2, 12, 12, 12), child: box),
            ),
          ),
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onRename,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AnimatedDefaultTextStyle(
                      duration: const Duration(milliseconds: 160),
                      style: (sub ? tt.bodyMedium : tt.bodyLarge)!.copyWith(
                        color: line.done ? ByteColors.textFaint : ByteColors.text,
                        decoration: line.done ? TextDecoration.lineThrough : TextDecoration.none,
                        decorationColor: ByteColors.textFaint,
                      ),
                      child: Text(words),
                    ),
                    // The reminder, in words, under the item it belongs to.
                    if (due != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.notifications_none_rounded, size: 14, color: dueColor),
                            const SizedBox(width: 4),
                            Flexible(child: Text(dueLabel(due), style: tt.bodySmall?.copyWith(color: dueColor), maxLines: 1, overflow: TextOverflow.ellipsis)),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          PopupMenuButton<String>(
            tooltip: 'More',
            icon: Icon(Icons.more_horiz_rounded, color: ByteColors.textFaint, size: 20),
            onSelected: (v) {
              switch (v) {
                case 'remind':
                  onRemind();
                case 'step':
                  onAddStep();
                case 'rename':
                  onRename();
                case 'remove':
                  onRemove();
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(value: 'remind', child: Text(due == null ? 'Remind me' : 'Change the reminder')),
              const PopupMenuItem(value: 'step', child: Text('Add a step under this')),
              const PopupMenuItem(value: 'rename', child: Text('Change the words')),
              PopupMenuItem(value: 'remove', child: Text(hasSteps ? 'Remove, with its steps' : 'Remove', style: TextStyle(color: ByteColors.danger))),
            ],
          ),
        ],
      ),
    );
  }
}
