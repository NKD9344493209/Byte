import 'package:flutter/material.dart';

import '../../shared/theme.dart';
import '../../shared/ui.dart';
import '../voice/heard_fixes.dart';

/// The words BYTE learned from your corrections: what it heard, and what you
/// meant. Remove one and BYTE stops changing it.
class HeardWordsScreen extends StatefulWidget {
  const HeardWordsScreen({super.key});

  @override
  State<HeardWordsScreen> createState() => _HeardWordsScreenState();
}

class _HeardWordsScreenState extends State<HeardWordsScreen> {
  Map<String, String> _fixes = const {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final f = await HeardFixes.all();
    if (!mounted) return;
    setState(() {
      _fixes = f;
      _loading = false;
    });
  }

  Future<void> _forget(String heard) async {
    await HeardFixes.forget(heard);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final keys = _fixes.keys.toList()..sort();
    return Scaffold(
      appBar: AppBar(title: const Text('Words BYTE learned')),
      body: _loading
          ? const SizedBox.shrink()
          : keys.isEmpty
              ? const EmptyNote('Nothing yet. Open a voice note, fix a word BYTE heard wrong, and it is remembered here. The next voice notes are corrected the same way.')
              : ListView(
                  padding: const EdgeInsets.only(bottom: 32),
                  children: [
                    const SectionLabel('Heard, and what you meant', top: 8),
                    ByteList(
                      wave: false,
                      children: [
                        for (final k in keys)
                          ByteRow(
                            title: _fixes[k] ?? '',
                            subtitle: 'when BYTE hears "$k"',
                            titleWeight: FontWeight.w600,
                            trailing: IconButton(
                              tooltip: 'Forget this one',
                              icon: Icon(Icons.close_rounded, color: ByteColors.textFaint),
                              onPressed: () => _forget(k),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
    );
  }
}
