import 'package:flutter/material.dart';

import '../../core/prefs.dart';
import '../../shared/theme.dart';
import '../capture/recorder_service.dart';
import 'voice_bridge.dart';

/// Speak-to-type for any text field. Tap → BYTE listens in rounds (patient
/// listening, same pause setting as commands) and types what you say at the
/// cursor; keeps going until you tap again or say "stop dictation".
/// Spoken punctuation works: "full stop", "comma", "new line", "question mark".
class DictationButton extends StatefulWidget {
  const DictationButton({super.key, required this.controller, this.focusNode, this.compact = false});
  final TextEditingController controller;
  final FocusNode? focusNode;
  final bool compact;

  /// Pure: spoken text → text to insert ("new line" → "\n", "full stop" → ".").
  static String clean(String heard) {
    var t = heard.trim();
    if (t.isEmpty) return '';
    t = t.replaceAll(RegExp(r'\b(?:new line|newline|next line|new paragraph)\b', caseSensitive: false), '\n');
    t = t.replaceAll(RegExp(r'\s*\b(?:full stop|fullstop|period)\b', caseSensitive: false), '.');
    t = t.replaceAll(RegExp(r'\s*\bcomma\b', caseSensitive: false), ',');
    t = t.replaceAll(RegExp(r'\s*\b(?:question mark)\b', caseSensitive: false), '?');
    t = t.replaceAll(RegExp(r'\s*\b(?:exclamation mark|exclamation)\b', caseSensitive: false), '!');
    t = t.replaceAll(RegExp(r'\s*\bcolon\b', caseSensitive: false), ':');
    t = t.replaceAll(RegExp(r'[ \t]+'), ' ').replaceAll(RegExp(r' *\n *'), '\n').trim();
    return t;
  }

  static bool isStop(String heard) => RegExp(r'^(?:stop|stop dictation|stop dictating|stop listening|that\x27s all|thats all|done|finish|enough)\.?$', caseSensitive: false).hasMatch(heard.trim());

  /// Pure: inserts [piece] at the selection with sensible spacing/capitals.
  static TextEditingValue insert(TextEditingValue v, String piece) {
    if (piece.isEmpty) return v;
    final text = v.text;
    final sel = v.selection.isValid ? v.selection : TextSelection.collapsed(offset: text.length);
    final start = sel.start.clamp(0, text.length);
    final end = sel.end.clamp(0, text.length);
    final before = text.substring(0, start);
    final after = text.substring(end);
    var p = piece;
    // Capitalize after a sentence end or at the very start.
    if (before.trim().isEmpty || before.endsWith('\n') || RegExp(r'[.!?]\s*$').hasMatch(before)) {
      p = p[0].toUpperCase() + p.substring(1);
    }
    var lead = '';
    if (before.isNotEmpty && !RegExp(r'[\s\n]$').hasMatch(before) && !p.startsWith('\n') && !RegExp(r'^[.,?!:]').hasMatch(p)) lead = ' ';
    var tail = '';
    if (after.isNotEmpty && !RegExp(r'^[\s\n.,?!:]').hasMatch(after) && !p.endsWith('\n')) tail = ' ';
    final out = '$before$lead$p$tail$after';
    final cursor = before.length + lead.length + p.length + tail.length;
    return TextEditingValue(text: out, selection: TextSelection.collapsed(offset: cursor));
  }

  @override
  State<DictationButton> createState() => _DictationButtonState();
}

class _DictationButtonState extends State<DictationButton> {
  bool _on = false;
  bool _busy = false;
  String _lastError = '';

  @override
  void dispose() {
    if (_on) VoiceBridge.cancelListen();
    super.dispose();
  }

  Future<void> _toggle() async {
    if (_on) {
      setState(() => _on = false);
      await VoiceBridge.cancelListen();
      return;
    }
    if (!VoiceBridge.supported) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Voice typing works on the phone.')));
      return;
    }
    // Android shows its "Allow BYTE to record audio?" question here the first time.
    final allowed = await RecorderService.instance.hasPermission();
    if (!mounted) return;
    if (!allowed) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Allow the microphone so BYTE can write what you say.')));
      return;
    }
    setState(() {
      _on = true;
      _lastError = '';
    });
    widget.focusNode?.requestFocus();
    await _loop();
  }

  Future<void> _loop() async {
    var emptyInARow = 0;
    while (mounted && _on) {
      _busy = true;
      final h = await VoiceBridge.listen(offline: false, locale: Prefs.voiceLocale, pauseMs: Prefs.listenPauseSec * 1000);
      _busy = false;
      if (!mounted || !_on) break;
      if (!h.ok || h.text.trim().isEmpty) {
        emptyInARow++;
        final err = h.error ?? '';
        if (err == 'cancelled') break;
        if (err == 'permission' || err == 'network' || err == 'unavailable') {
          _lastError = err == 'permission' ? 'Microphone permission is off.' : (err == 'network' ? 'Needs internet (or the offline English pack).' : 'No speech recognizer on this phone.');
          setState(() => _on = false);
          break;
        }
        // Three silent rounds in a row → stop by itself (no battery drain).
        if (emptyInARow >= 3) {
          setState(() => _on = false);
          break;
        }
        continue;
      }
      emptyInARow = 0;
      if (DictationButton.isStop(h.text)) {
        setState(() => _on = false);
        break;
      }
      final piece = DictationButton.clean(h.text);
      widget.controller.value = DictationButton.insert(widget.controller.value, piece);
      if (mounted) setState(() {});
    }
    VoiceBridge.partial.value = '';
  }

  @override
  Widget build(BuildContext context) {
    // Ink pill to start; amber (= BYTE is listening) while it writes.
    final fab = FilledButton.icon(
      style: inlineButton.copyWith(
        backgroundColor: WidgetStatePropertyAll(_on ? ByteColors.hey : ByteColors.accentBright),
        foregroundColor: WidgetStatePropertyAll(_on ? ByteColors.onHey : ByteColors.onAccent),
        minimumSize: const WidgetStatePropertyAll(Size(0, 44)),
        padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 18)),
      ),
      onPressed: _toggle,
      icon: Icon(_on ? Icons.stop_rounded : Icons.mic_rounded, size: 18),
      label: Text(_on ? 'Stop' : (widget.compact ? 'Speak' : 'Speak to write')),
    );
    if (!_on) return fab;
    // The bubble sits in a Row beside other widgets (the note editor's tags
    // field): cap it to part of the screen so it never squeezes them out.
    final w = MediaQuery.sizeOf(context).width * 0.6;
    final bubbleMax = w < 300 ? w : 300.0;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        ValueListenableBuilder<String>(
          valueListenable: VoiceBridge.partial,
          builder: (_, partial, _) => Container(
            constraints: BoxConstraints(maxWidth: bubbleMax),
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(color: ByteColors.heySoft, borderRadius: BorderRadius.circular(12)),
            child: Text(
              partial.isNotEmpty ? partial : (_busy ? 'Listening. Say "new line", "full stop", or "stop" when done.' : 'Writing…'),
              style: TextStyle(fontSize: 12, height: 1.35, color: partial.isNotEmpty ? ByteColors.text : ByteColors.heyInk),
            ),
          ),
        ),
        if (_lastError.isNotEmpty) Padding(padding: const EdgeInsets.only(bottom: 6), child: Text(_lastError, style: TextStyle(fontSize: 11, color: ByteColors.danger))),
        fab,
      ],
    );
  }
}
