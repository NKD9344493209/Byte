import 'package:flutter/material.dart';

import 'theme.dart';

/// The little yellow note you can stick on anything (recording, photo, link…).
class StickyNote extends StatelessWidget {
  const StickyNote({super.key, required this.text, required this.onTap, this.compact = false});

  final String text;
  final VoidCallback onTap;
  final bool compact;

  static const Color paper = Color(0xFFFFF3B0);
  static const Color ink = Color(0xFF5A4A00);

  @override
  Widget build(BuildContext context) {
    final has = text.trim().isNotEmpty;
    if (!has && compact) {
      return InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.sticky_note_2_outlined, size: 14, color: ByteColors.textDim),
              const SizedBox(width: 4),
              Text('Add sticky note', style: TextStyle(fontSize: 12, color: ByteColors.textDim)),
            ],
          ),
        ),
      );
    }
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: EdgeInsets.symmetric(horizontal: 10, vertical: compact ? 6 : 10),
        decoration: BoxDecoration(
          color: ByteColors.dark ? const Color(0xFF4A4210) : paper,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: ByteColors.dark ? const Color(0xFF6E6220) : const Color(0xFFF2DF7A)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.sticky_note_2_rounded, size: 16, color: ByteColors.dark ? const Color(0xFFF2DF7A) : ink),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                has ? text.trim() : 'Add a sticky note',
                maxLines: compact ? 2 : null,
                overflow: compact ? TextOverflow.ellipsis : null,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.35,
                  color: ByteColors.dark ? const Color(0xFFF7EDB0) : ink,
                  fontStyle: has ? FontStyle.normal : FontStyle.italic,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Edit dialog shared by every place a sticky note can live.
Future<String?> editStickyNote(BuildContext context, String current) async {
  final ctl = TextEditingController(text: current);
  final v = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Sticky note'),
      content: TextField(
        controller: ctl,
        autofocus: true,
        minLines: 2,
        maxLines: 5,
        textCapitalization: TextCapitalization.sentences,
        decoration: const InputDecoration(hintText: 'Why this matters, what to do with it…'),
      ),
      actions: [
        if (current.trim().isNotEmpty)
          TextButton(
            onPressed: () => Navigator.pop(ctx, ''),
            child: Text('Remove', style: TextStyle(color: ByteColors.danger)),
          ),
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size(96, 44)),
          onPressed: () => Navigator.pop(ctx, ctl.text),
          child: const Text('Save'),
        ),
      ],
    ),
  );
  Future<void>.delayed(const Duration(seconds: 1), ctl.dispose);
  return v;
}
