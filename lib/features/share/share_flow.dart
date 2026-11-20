import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/cloud_sync.dart';
import '../../core/friends.dart';
import '../../core/shares.dart';
import '../../shared/theme.dart';
import '../friends/friend_share.dart';

/// "Share with a link": asks what the other person may do and for how long,
/// makes the share, and hands you the link to send.
class ShareFlow {
  ShareFlow._();

  static String _defaultName() {
    final n = DateTime.now();
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return 'Shared on ${n.day} ${months[n.month - 1]} ${n.year}';
  }

  /// Shares [itemIds]. [name]: what the shared folder is called (a folder's
  /// own name when a whole folder is shared).
  /// True when a link was made.
  static Future<bool> start(BuildContext context, List<String> itemIds, {String? name}) async {
    if (itemIds.isEmpty) return false;
    final messenger = ScaffoldMessenger.of(context);
    if (!await CloudSync.connected()) {
      messenger.showSnackBar(const SnackBar(content: Text('Sharing uses your Google Drive. Connect it first (the Drive pill at the top of the Library).')));
      return false;
    }
    if (!context.mounted) return false;
    // With friends on BYTE there are two ways: a link anyone can open, or an
    // album inside BYTE that you and one friend both see.
    final friends = await Friends.list();
    if (!context.mounted) return false;
    if (friends.isNotEmpty) {
      final how = await showModalBottomSheet<String>(
        context: context,
        builder: (ctx) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: Icon(Icons.link_rounded, color: ByteColors.accentDim),
                title: const Text('With a link'),
                subtitle: const Text('Anyone you send it to can open it'),
                onTap: () => Navigator.pop(ctx, 'link'),
              ),
              for (final f in friends)
                ListTile(
                  leading: Icon(Icons.person_outline_rounded, color: ByteColors.accentDim),
                  title: Text('With ${f.name}'),
                  subtitle: const Text('Photos and videos go into an album you both see in BYTE'),
                  onTap: () => Navigator.pop(ctx, f.id),
                ),
            ],
          ),
        ),
      );
      if (how == null || !context.mounted) return false;
      if (how != 'link') return FriendShare.run(context, friends.firstWhere((f) => f.id == how), itemIds);
    }
    final choice = await showModalBottomSheet<_Choice>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => _OptionsSheet(count: itemIds.length, name: name ?? _defaultName()),
    );
    if (choice == null || !context.mounted) return false;

    final progress = ValueNotifier<String>('Getting ready…');
    var stop = false;
    final nav = Navigator.of(context, rootNavigator: true);
    // A small "working" box that cannot be tapped away while copies are made.
    // A route of its own, so exactly this box is taken away afterwards.
    final working = DialogRoute<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => PopScope(
        canPop: false,
        child: AlertDialog(
          content: Row(
            children: [
              const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4)),
              const SizedBox(width: 16),
              Expanded(child: ValueListenableBuilder<String>(valueListenable: progress, builder: (_, s, _) => Text(s))),
            ],
          ),
          actions: [
            TextButton(
              style: inlineButton,
              onPressed: () {
                stop = true;
                progress.value = 'Stopping…';
              },
              child: const Text('Stop'),
            ),
          ],
        ),
      ),
    );
    nav.push(working);
    ShareOutcome? done;
    String? problem;
    try {
      done = await Shares.create(
        name: choice.name,
        itemIds: itemIds,
        canAdd: choice.canAdd,
        days: choice.days,
        shouldStop: () => stop,
        onProgress: (i, total) {
          if (!stop) progress.value = i >= total ? 'Making the link…' : 'Putting in ${i + 1} of $total…';
        },
      );
    } on CloudNeedsSignIn {
      problem = 'Sign in to Google Drive again (the Drive pill), then share.';
    } catch (e) {
      problem = stop ? 'Sharing stopped. Nothing was shared.' : 'Could not share now. It needs the internet. ($e)';
    }
    if (working.isActive) nav.removeRoute(working); // the "working" box, and only it
    if (problem != null) {
      messenger.showSnackBar(SnackBar(content: Text(problem)));
      return false;
    }
    if (done == null) return false;
    if (!context.mounted) {
      messenger.showSnackBar(const SnackBar(content: Text('Shared. The link is in Folders → Friends and sharing → Links you made.')));
      return true;
    }
    await showLink(context, done.link, skipped: done.skipped);
    return true;
  }

  /// The link of a share with "Send" and "Copy".
  static Future<void> showLink(BuildContext context, SharedLink s, {int skipped = 0}) {
    return showModalBottomSheet<void>(
      context: context,
      builder: (ctx) {
        final tt = Theme.of(ctx).textTheme;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(ByteSpace.page, 4, ByteSpace.page, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(s.name, style: tt.titleLarge),
                const SizedBox(height: 6),
                Text(describe(s), style: tt.bodySmall),
                if (skipped > 0) ...[
                  const SizedBox(height: 6),
                  Text('$skipped could not be put in (private, or not on the phone and not in Drive right now).', style: tt.bodySmall?.copyWith(color: ByteColors.heyInk)),
                ],
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: ByteColors.surface2, borderRadius: BorderRadius.circular(ByteSpace.rs)),
                  child: SelectableText(s.link, style: tt.bodySmall?.copyWith(color: ByteColors.text)),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    FilledButton.icon(
                      style: inlineButton,
                      onPressed: () => SharePlus.instance.share(ShareParams(text: s.link)),
                      icon: const Icon(Icons.send_rounded, size: 18),
                      label: const Text('Send the link'),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton(
                      style: inlineButton,
                      onPressed: () async {
                        await Clipboard.setData(ClipboardData(text: s.link));
                        if (ctx.mounted) Navigator.pop(ctx);
                      },
                      child: const Text('Copy'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// "12 things. Anyone with the link can view. Stops by itself on 26/11/2026."
  static String describe(SharedLink s) {
    final what = '${s.count} ${s.count == 1 ? 'thing' : 'things'}. Anyone with the link can ${s.canAdd ? 'view and add files' : 'view'}.';
    final e = s.expiresAt;
    return e == null ? '$what Shared until you stop it.' : '$what Stops by itself on ${e.day}/${e.month}/${e.year}.';
  }
}

class _Choice {
  const _Choice(this.name, this.canAdd, this.days);
  final String name;
  final bool canAdd;
  final int? days;
}

class _OptionsSheet extends StatefulWidget {
  const _OptionsSheet({required this.count, required this.name});
  final int count;
  final String name;

  @override
  State<_OptionsSheet> createState() => _OptionsSheetState();
}

class _OptionsSheetState extends State<_OptionsSheet> {
  late final TextEditingController _name = TextEditingController(text: widget.name);
  bool _canAdd = false;
  int? _days = 7;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Widget _pick<T>(String label, T value, T group, ValueChanged<T> onPick) {
    final on = value == group;
    return Padding(
      padding: const EdgeInsets.only(right: 8, bottom: 8),
      child: ChoiceChip(label: Text(label), selected: on, onSelected: (_) => onPick(value)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(ByteSpace.page, 4, ByteSpace.page, 16 + MediaQuery.viewInsetsOf(context).bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Share ${widget.count} ${widget.count == 1 ? 'thing' : 'things'} with a link', style: tt.titleLarge),
            const SizedBox(height: 6),
            Text(
              'BYTE puts copies into one folder in your Google Drive and gives you a link to it. Only that folder can be seen through the link.',
              style: tt.bodySmall,
            ),
            const SizedBox(height: 14),
            TextField(controller: _name, textCapitalization: TextCapitalization.sentences, decoration: const InputDecoration(labelText: 'Name of the shared folder')),
            const SizedBox(height: 16),
            Text('People with the link can', style: tt.labelMedium),
            const SizedBox(height: 8),
            Wrap(
              children: [
                _pick<bool>('View only', false, _canAdd, (v) => setState(() => _canAdd = v)),
                _pick<bool>('View and add files', true, _canAdd, (v) => setState(() => _canAdd = v)),
              ],
            ),
            const SizedBox(height: 8),
            Text('Stop sharing by itself', style: tt.labelMedium),
            const SizedBox(height: 8),
            Wrap(
              children: [
                _pick<int?>('After a day', 1, _days, (v) => setState(() => _days = v)),
                _pick<int?>('After a week', 7, _days, (v) => setState(() => _days = v)),
                _pick<int?>('After a month', 30, _days, (v) => setState(() => _days = v)),
                _pick<int?>('Never', null, _days, (v) => setState(() => _days = v)),
              ],
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () {
                final name = _name.text.trim();
                Navigator.pop(context, _Choice(name.isEmpty ? widget.name : name, _canAdd, _days));
              },
              child: const Text('Make the link'),
            ),
          ],
        ),
      ),
    );
  }
}
