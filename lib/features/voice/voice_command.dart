/// What you meant when you spoke to BYTE's Search — pure functions (no
/// Flutter), so they are unit-tested.
///
/// "find my Aadhaar"            → look for "aadhaar"
/// "show me the hall ticket"    → look for "hall ticket"
/// "note buy milk tomorrow"     → save a note "Buy milk tomorrow"
/// "remember the locker is 214" → save a note "The locker is 214"
/// anything else                → look for those words
library;

enum VoiceKind { find, note, none }

class VoiceCommand {
  const VoiceCommand(this.kind, this.text);
  final VoiceKind kind;

  /// The words to look for, or the text of the note.
  final String text;

  @override
  bool operator ==(Object other) => other is VoiceCommand && other.kind == kind && other.text == text;

  @override
  int get hashCode => Object.hash(kind, text);

  @override
  String toString() => 'VoiceCommand(${kind.name}, "$text")';
}

final RegExp _noteStart = RegExp(
  r'^(?:please\s+)?(?:(?:take|make|add|save|write|create)\s+(?:a\s+)?(?:new\s+)?note(?:\s+(?:that|saying|about|of))?|note\s+down|note\s+that|note(?![\s\-]+(?:books?|pads?)\b)|remember\s+that|remember|write\s+(?:this\s+)?down|save\s+this\s+as\s+a\s+note)[\s:,\-]+(.+)$',
  caseSensitive: false,
);

final RegExp _findStart = RegExp(
  r"^(?:please\s+)?(?:find|search\s+for|search|show\s+me|show|open|get\s+me|get|look\s+for|where\s+is|where's|where\s+are)\s+(?:(?:my|the|a|an|me)\s+)*(.+)$",
  caseSensitive: false,
);

/// Words at the end of a spoken search that are not in the thing itself
/// ("find my Aadhaar card photo" → "aadhaar").
const _tails = {'photo', 'photos', 'picture', 'pictures', 'pic', 'pics', 'image', 'images', 'file', 'files', 'document', 'documents', 'doc', 'card', 'please'};

String _tidy(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim().replaceAll(RegExp(r'[.?!,;:]+$'), '').trim();

String _capital(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

/// Reads what was said into Search.
VoiceCommand parseVoice(String said) {
  final s = _tidy(said);
  if (s.isEmpty) return const VoiceCommand(VoiceKind.none, '');
  final note = _noteStart.firstMatch(s);
  if (note != null) {
    final text = _tidy(note.group(1) ?? '');
    if (text.isNotEmpty) return VoiceCommand(VoiceKind.note, _capital(text));
  }
  final find = _findStart.firstMatch(s);
  var words = (find == null ? s : _tidy(find.group(1) ?? '')).split(' ').where((w) => w.isNotEmpty).toList();
  // "…card photo please": drop such words from the end, but never the last word.
  while (words.length > 1 && _tails.contains(words.last.toLowerCase())) {
    words = words.sublist(0, words.length - 1);
  }
  final q = words.join(' ');
  return q.isEmpty ? const VoiceCommand(VoiceKind.none, '') : VoiceCommand(VoiceKind.find, q);
}

final RegExp _nameStart = RegExp(r'^(?:please\s+)?(?:save\s+(?:this|it)\s+as|name\s+(?:this|it)(?:\s+as)?|call\s+(?:this|it)|rename\s+(?:this|it)?\s*(?:to|as)?|name)\s+(.+)$', caseSensitive: false);

/// The name out of "save this as hostel fee receipt" (or just the words, when
/// you only said the name).
String voiceName(String said) {
  final s = _tidy(said);
  final m = _nameStart.firstMatch(s);
  return _capital(_tidy(m == null ? s : (m.group(1) ?? s)));
}
