import 'package:flutter/material.dart';

import '../../core/activity.dart';
import '../../shared/theme.dart';
import '../../shared/ui.dart';

/// What BYTE did lately, newest first, with an Undo on each line that can
/// be taken back.
class ActivityScreen extends StatefulWidget {
  const ActivityScreen({super.key});

  @override
  State<ActivityScreen> createState() => _ActivityScreenState();
}

class _ActivityScreenState extends State<ActivityScreen> {
  List<ActivityEntry> _entries = const [];
  bool _loading = true;
  int? _undoing;

  @override
  void initState() {
    super.initState();
    Activity.changed.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    Activity.changed.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final e = await Activity.recent();
    if (!mounted) return;
    setState(() {
      _entries = e;
      _loading = false;
    });
  }

  Future<void> _undo(ActivityEntry e) async {
    if (_undoing != null) return;
    setState(() => _undoing = e.id);
    final said = await Activity.undo(e);
    if (!mounted) return;
    setState(() => _undoing = null);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(said)));
  }

  static String _when(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'just now';
    if (d.inHours < 1) return '${d.inMinutes} min ago';
    if (d.inDays < 1) return '${d.inHours} h ago';
    if (d.inDays < 7) return '${d.inDays} day${d.inDays == 1 ? '' : 's'} ago';
    return '${t.day}/${t.month}/${t.year}';
  }

  static IconData _icon(String kind) => switch (kind) {
        'bin' => Icons.delete_outline_rounded,
        'expire' => Icons.timer_outlined,
        'rename' || 'names' => Icons.drive_file_rename_outline,
        'folder' => Icons.folder_outlined,
        _ => Icons.history_rounded,
      };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Activity')),
      body: _loading
          ? const SizedBox.shrink()
          : _entries.isEmpty
              ? const EmptyNote('Nothing yet. When something is moved to the bin, renamed or tidied, it shows here with an Undo.')
              : ListView(
                  padding: const EdgeInsets.only(bottom: 40),
                  children: [
                    ByteList(
                      wave: false,
                      children: [
                        for (final e in _entries)
                          ByteRow(
                            icon: _icon(e.kind),
                            title: e.summary,
                            subtitle: e.undone ? '${_when(e.at)} · undone' : _when(e.at),
                            titleWeight: FontWeight.w600,
                            trailing: !e.canUndo
                                ? null
                                : _undoing == e.id
                                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                                    : TextButton(style: inlineButton, onPressed: _undoing != null ? null : () => _undo(e), child: const Text('Undo')),
                          ),
                      ],
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(ByteSpace.page, 16, ByteSpace.page, 0),
                      child: Text(
                        'The last 500 things are kept. Nothing about the private space is listed here.',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(color: ByteColors.textFaint),
                      ),
                    ),
                  ],
                ),
    );
  }
}
