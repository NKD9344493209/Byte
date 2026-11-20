import 'checklist.dart';

class Note {
  const Note({
    required this.id,
    required this.title,
    required this.body,
    required this.tags,
    required this.createdAt,
    required this.updatedAt,
    this.private = false,
  });

  final String id;
  final String title;
  final String body;
  final List<String> tags;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// In the private space.
  final bool private;

  Note copyWith({String? title, String? body, List<String>? tags}) => Note(
        id: id,
        title: title ?? this.title,
        body: body ?? this.body,
        tags: tags ?? this.tags,
        createdAt: createdAt,
        updatedAt: DateTime.now(),
        private: private,
      );

  factory Note.fromRow(Map<String, Object?> r) => Note(
        id: r['id'] as String,
        title: r['title'] as String? ?? '',
        body: r['body'] as String? ?? '',
        tags: _splitTags(r['tags'] as String? ?? ''),
        createdAt: DateTime.fromMillisecondsSinceEpoch(r['created_at'] as int),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(r['updated_at'] as int),
        private: ((r['private'] as int?) ?? 0) == 1,
      );

  Map<String, Object?> toRow() => {
        'id': id,
        'type': 'note',
        'title': title,
        'body': body,
        'tags': tags.join(','),
        'created_at': createdAt.millisecondsSinceEpoch,
        'updated_at': updatedAt.millisecondsSinceEpoch,
        'private': private ? 1 : 0,
      };

  static List<String> _splitTags(String s) =>
      s.split(',').map((t) => t.trim()).where((t) => t.isNotEmpty).toList();

  /// First non-empty line of the body, used when title is blank.
  String get displayTitle {
    if (title.trim().isNotEmpty) return title.trim();
    // A checklist's first line is shown without its "- [ ]" mark.
    final firstLine = body
        .split('\n')
        .map(plainLine)
        .firstWhere((l) => l.isNotEmpty, orElse: () => '');
    return firstLine.isEmpty ? 'Untitled' : firstLine;
  }
}
