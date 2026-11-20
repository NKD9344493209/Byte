class AudioItem {
  const AudioItem({
    required this.id,
    required this.title,
    required this.path,
    required this.durationMs,
    required this.rawTranscript,
    required this.cleanText,
    required this.transcriptStatus,
    required this.tags,
    required this.createdAt,
    this.note = '',
  });

  final String id;
  final String title;
  final String path;
  final int durationMs;
  final String rawTranscript;
  final String cleanText;

  /// pending | running | done | failed
  final String transcriptStatus;
  final List<String> tags;
  final DateTime createdAt;

  /// Sticky note: a line you attach to the recording ("app idea", "for exam").
  final String note;

  /// Still carrying the automatic "Voice note · …" title.
  bool get isUnnamed => title.startsWith('Voice note ·') || title.trim().isEmpty;

  Duration get duration => Duration(milliseconds: durationMs);

  bool get hasTranscript =>
      cleanText.trim().isNotEmpty || rawTranscript.trim().isNotEmpty;

  /// Joined row from items + audio tables.
  factory AudioItem.fromRow(Map<String, Object?> r) => AudioItem(
        id: r['id'] as String,
        title: r['title'] as String? ?? '',
        path: r['path'] as String,
        durationMs: (r['duration_ms'] as int?) ?? 0,
        rawTranscript: r['raw_transcript'] as String? ?? '',
        cleanText: r['clean_text'] as String? ?? '',
        transcriptStatus: r['transcript_status'] as String? ?? 'pending',
        tags: (r['tags'] as String? ?? '')
            .split(',')
            .map((t) => t.trim())
            .where((t) => t.isNotEmpty)
            .toList(),
        createdAt: DateTime.fromMillisecondsSinceEpoch(r['created_at'] as int),
        note: r['body'] as String? ?? '',
      );

  /// What to show in a list: transcript if we have one, else the title.
  String get displayText {
    if (cleanText.trim().isNotEmpty) return cleanText.trim();
    if (rawTranscript.trim().isNotEmpty) return rawTranscript.trim();
    return title;
  }

  static String formatDuration(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return d.inHours > 0 ? '${d.inHours}:$m:$s' : '$m:$s';
  }
}
