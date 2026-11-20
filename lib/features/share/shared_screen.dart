import 'package:flutter/material.dart';

import '../../core/shares.dart';
import '../../shared/theme.dart';
import '../../shared/ui.dart';
import 'share_flow.dart';

/// "Links you made": every link you made, what it shows, when it stops — and
/// "Stop sharing" to take it back at once.
class SharedScreen extends StatefulWidget {
  const SharedScreen({super.key});

  @override
  State<SharedScreen> createState() => _SharedScreenState();
}

class _SharedScreenState extends State<SharedScreen> {
  List<SharedLink> _links = const [];
  bool _loaded = false;
  String _stopping = '';

  @override
  void initState() {
    super.initState();
    Shares.changed.addListener(_load);
    _load();
    // Anything whose time is up is stopped now (the list follows by itself).
    Shares.runDue();
  }

  @override
  void dispose() {
    Shares.changed.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final links = await Shares.list();
    if (!mounted) return;
    setState(() {
      _links = links;
      _loaded = true;
    });
  }

  Future<void> _stop(SharedLink s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Stop sharing this?'),
        content: const Text('The link is closed for everyone and the shared folder goes to your Drive\'s Trash. Your own photos and files are not touched — the folder only held copies.'),
        actions: [
          TextButton(style: inlineButton, onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(style: inlineButton, onPressed: () => Navigator.pop(ctx, true), child: Text('Stop sharing', style: TextStyle(color: ByteColors.danger))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _stopping = s.id);
    try {
      await Shares.stop(s);
      messenger.showSnackBar(const SnackBar(content: Text('Not shared any more.')));
    } catch (_) {
      messenger.showSnackBar(const SnackBar(content: Text('Could not stop it now. It needs the internet and Google Drive. Try again.')));
    }
    if (mounted) setState(() => _stopping = '');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Links you made')),
      body: !_loaded
          ? const SizedBox.shrink()
          : _links.isEmpty
              ? const EmptyNote('Nothing is shared. Select photos, files or notes in the Library and tap the share button to make a link.')
              : ListView(
                  padding: const EdgeInsets.only(bottom: 32),
                  children: [
                    for (final s in _links)
                      ByteRow(
                        icon: s.canAdd ? Icons.group_add_outlined : Icons.link_rounded,
                        title: s.name,
                        subtitle: ShareFlow.describe(s),
                        titleWeight: FontWeight.w600,
                        onTap: () => ShareFlow.showLink(context, s),
                        trailing: _stopping == s.id
                            ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                            : TextButton(style: inlineButton, onPressed: () => _stop(s), child: Text('Stop', style: TextStyle(color: ByteColors.danger))),
                      ),
                  ],
                ),
    );
  }
}
