import 'package:flutter/material.dart';

import '../../shared/motion.dart';
import '../../shared/theme.dart';
import '../../shared/ui.dart';
import '../notes/checklist_view.dart';
import 'activity_screen.dart';
import 'librarian.dart';

/// The small card in the Library: "BYTE has 3 ideas to tidy up". At most
/// once a week; "Later" hides it for a week.
class TidyCard extends StatefulWidget {
  const TidyCard({super.key});

  @override
  State<TidyCard> createState() => _TidyCardState();
}

class _TidyCardState extends State<TidyCard> {
  bool _hidden = false;

  @override
  void initState() {
    super.initState();
    // Looked at a little after the Library is up; never in the way of opening BYTE.
    Future<void>.delayed(const Duration(seconds: 9), () {
      if (mounted && Librarian.waiting.value == 0) Librarian.ideas();
    });
  }

  Future<void> _later() async {
    await Librarian.snoozeCard();
    if (mounted) setState(() => _hidden = true);
  }

  Future<void> _open() async {
    await Librarian.snoozeCard();
    if (!mounted) return;
    setState(() => _hidden = true);
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const TidyScreen()));
  }

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return ValueListenableBuilder<int>(
      valueListenable: Librarian.waiting,
      builder: (_, n, _) {
        if (_hidden || n == 0 || !Librarian.cardDue) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Well(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(n == 1 ? 'BYTE has an idea to tidy up' : 'BYTE has $n ideas to tidy up', style: tt.titleSmall),
                const SizedBox(height: 6),
                Text('Folders for files that belong together, real names for "IMG_1234", old screenshots. You decide on each one.', style: tt.bodySmall),
                const SizedBox(height: 10),
                Row(
                  children: [
                    FilledButton(style: inlineButton, onPressed: _open, child: const Text('Show me')),
                    const SizedBox(width: 8),
                    TextButton(style: inlineButton, onPressed: _later, child: const Text('Later')),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Every idea, one under the other, each with "Do it" and "Not this".
class TidyScreen extends StatefulWidget {
  const TidyScreen({super.key});

  @override
  State<TidyScreen> createState() => _TidyScreenState();
}

class _TidyScreenState extends State<TidyScreen> {
  List<TidyIdea> _ideas = const [];
  bool _loading = true;
  String? _working; // the key of the idea being done

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final ideas = await Librarian.ideas();
    if (!mounted) return;
    setState(() {
      _ideas = ideas;
      _loading = false;
    });
  }

  void _snack(String m, {bool undo = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(m),
      duration: const Duration(seconds: 6),
      persist: false,
      action: undo ? SnackBarAction(label: 'Activity', onPressed: _activity) : null,
    ));
  }

  void _activity() {
    if (!mounted) return; // the snack bar can outlive this screen
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const ActivityScreen()));
  }

  Future<void> _do(TidyIdea idea) async {
    if (_working != null) return;
    String? name;
    if (idea.kind == 'folder' || idea.kind == 'trip') {
      // The folder's name is yours to choose.
      name = await ChecklistView.askLine(context, title: 'Name of the folder', initial: idea.folderName, action: 'Make it');
      if (name == null || !mounted) return;
    }
    setState(() => _working = idea.key);
    String said;
    var done = false;
    try {
      said = await Librarian.apply(idea, folderName: name);
      done = said != Librarian.nothingDone;
      if (done) Haptics.confirm();
    } catch (e) {
      said = 'That did not work: $e';
    }
    if (!mounted) return;
    setState(() {
      _working = null;
      // The idea leaves the list only when it was carried out.
      if (done) {
        _ideas = [
          for (final i in _ideas)
            if (i.key != idea.key) i,
        ];
      }
    });
    _snack(done ? '$said You can undo it in Activity.' : said, undo: done);
  }

  Future<void> _skip(TidyIdea idea) async {
    await Librarian.dismiss(idea);
    if (!mounted) return;
    setState(() {
      _ideas = [
        for (final i in _ideas)
          if (i.key != idea.key) i,
      ];
    });
  }

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Tidy up'),
        actions: [IconButton(tooltip: 'Activity', icon: const Icon(Icons.history_rounded), onPressed: _activity)],
      ),
      body: _loading
          ? const Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4)))
          : ListView(
              padding: const EdgeInsets.only(bottom: 40),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(ByteSpace.page, 8, ByteSpace.page, 4),
                  child: Text(
                    'BYTE looked at the names, the words inside your files and what your photos show. Everything here is worked out on the phone. Nothing happens until you say so.',
                    style: tt.bodyMedium?.copyWith(color: ByteColors.textDim),
                  ),
                ),
                if (_ideas.isEmpty)
                  const EmptyNote('Nothing to tidy right now. BYTE looks again as you add things.')
                else
                  for (final idea in _ideas)
                    Padding(
                      padding: const EdgeInsets.only(top: 14),
                      child: Well(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(idea.title, style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                            const SizedBox(height: 6),
                            Text(idea.detail, style: tt.bodySmall),
                            if (idea.examples.isNotEmpty) ...[
                              const SizedBox(height: 8),
                              for (final e in idea.examples)
                                Padding(
                                  padding: const EdgeInsets.only(top: 2),
                                  child: Text('· $e', maxLines: 1, overflow: TextOverflow.ellipsis, style: tt.bodySmall?.copyWith(color: ByteColors.textFaint)),
                                ),
                            ],
                            const SizedBox(height: 12),
                            Row(
                              children: [
                                FilledButton(
                                  style: inlineButton,
                                  onPressed: _working != null ? null : () => _do(idea),
                                  child: _working == idea.key
                                      ? SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: ByteColors.onAccent))
                                      : const Text('Do it'),
                                ),
                                const SizedBox(width: 8),
                                TextButton(style: inlineButton, onPressed: _working != null ? null : () => _skip(idea), child: const Text('Not this')),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
              ],
            ),
    );
  }
}
