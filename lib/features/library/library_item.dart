import 'package:path/path.dart' as p;

import '../../core/private_names.dart';
import '../notes/checklist.dart';

/// What kind of thing an item is. Notes and voice recordings have their own
/// modules; the Library shows everything together.
enum LibraryKind { photo, video, doc, link, audio, note }

extension LibraryKindX on LibraryKind {
  String get label => switch (this) {
        LibraryKind.photo => 'Photos',
        LibraryKind.video => 'Videos',
        LibraryKind.doc => 'Docs',
        LibraryKind.link => 'Links',
        LibraryKind.audio => 'Audio',
        LibraryKind.note => 'Notes',
      };

  static LibraryKind? parse(String? s) {
    for (final k in LibraryKind.values) {
      if (k.name == s) return k;
    }
    return null;
  }

  /// Guess from a file name.
  static LibraryKind forPath(String path) {
    final ext = p.extension(path).toLowerCase().replaceFirst('.', '');
    if (const {'jpg', 'jpeg', 'png', 'webp', 'heic', 'heif', 'gif', 'bmp'}.contains(ext)) {
      return LibraryKind.photo;
    }
    if (const {'mp4', 'mkv', 'mov', 'webm', '3gp', 'avi', 'm4v'}.contains(ext)) {
      return LibraryKind.video;
    }
    if (const {'wav', 'mp3', 'm4a', 'aac', 'ogg', 'opus', 'flac'}.contains(ext)) {
      return LibraryKind.audio;
    }
    return LibraryKind.doc;
  }
}

/// One row of the Library (a file, a link, a note or a recording).
class LibraryItem {
  const LibraryItem({
    required this.id,
    required this.kind,
    required this.title,
    required this.tags,
    required this.createdAt,
    this.path = '',
    this.url = '',
    this.mime = '',
    this.size = 0,
    this.thumb = '',
    this.text = '',
    this.labels = const [],
    this.indexStatus = 'done',
    this.body = '',
    this.durationMs = 0,
    this.pinned = false,
    this.mediaKey = '',
    this.private = false,
  });

  final String id;
  final LibraryKind kind;
  final String title;
  final List<String> tags;
  final DateTime createdAt;

  /// Local copy (files, recordings). Empty for links/notes.
  final String path;
  final String url;
  final String mime;
  final int size;
  final String thumb;

  /// Everything searchable that was pulled out: OCR, doc text, page title…
  final String text;

  /// AI labels (dog, cat, document, …) — filled in the vision step.
  final List<String> labels;

  /// pending | working | done | failed | unsupported
  final String indexStatus;

  /// Note content (notes) or the sticky note (everything else).
  final String body;
  final int durationMs;

  /// On the sticky board (home-screen widget / shade / Today).
  final bool pinned;

  /// "image:123" when this is a photo / video that lives in the phone's own
  /// gallery (BYTE only lists it); '' for everything BYTE keeps itself.
  final String mediaKey;

  bool get fromGallery => mediaKey.isNotEmpty;

  /// In the private space: shown only there, behind its own PIN.
  final bool private;

  /// The file on the phone is locked (encrypted). It opens only inside the
  /// private space, with the PIN.
  bool get sealed => isSealedPath(path);

  /// The preview picture is locked too.
  bool get thumbSealed => isSealedPath(thumb);

  /// Sticky note text — notes are their own sticky.
  String get sticky => kind == LibraryKind.note ? '' : body.trim();

  String get displayTitle {
    if (title.trim().isNotEmpty) return title.trim();
    if (kind == LibraryKind.note) {
      final first = body.split('\n').map(plainLine).firstWhere((l) => l.isNotEmpty, orElse: () => '');
      if (first.isNotEmpty) return first;
      return 'Untitled note';
    }
    if (kind == LibraryKind.link) return url;
    if (path.isNotEmpty) return p.basename(plainPath(path));
    return 'Untitled';
  }

  /// "pdf", "jpg"… (a locked file still says what it was).
  String get ext => p.extension(plainPath(path)).toLowerCase().replaceFirst('.', '');

  bool get hasFile => path.isNotEmpty;

  static LibraryItem fromRow(Map<String, Object?> r) {
    final type = r['type'] as String? ?? 'doc';
    final kind = LibraryKindX.parse(type) ?? LibraryKind.doc;
    final tagsRaw = r['tags'] as String? ?? '';
    final labelsRaw = r['labels'] as String? ?? '';
    return LibraryItem(
      id: r['id'] as String,
      kind: kind,
      title: r['title'] as String? ?? '',
      tags: tagsRaw.isEmpty ? const [] : tagsRaw.split(',').map((t) => t.trim()).where((t) => t.isNotEmpty).toList(),
      createdAt: DateTime.fromMillisecondsSinceEpoch(r['created_at'] as int),
      path: (r['path'] as String?) ?? '',
      url: (r['url'] as String?) ?? '',
      mime: (r['mime'] as String?) ?? '',
      size: (r['size'] as int?) ?? 0,
      thumb: (r['thumb'] as String?) ?? '',
      text: (r['text'] as String?) ?? '',
      labels: labelsRaw.isEmpty ? const [] : labelsRaw.split(',').map((t) => t.trim()).where((t) => t.isNotEmpty).toList(),
      indexStatus: (r['index_status'] as String?) ?? 'done',
      body: (r['body'] as String?) ?? '',
      durationMs: (r['duration_ms'] as int?) ?? 0,
      pinned: ((r['pinned'] as int?) ?? 0) == 1,
      mediaKey: (r['media_key'] as String?) ?? '',
      private: ((r['private'] as int?) ?? 0) == 1,
    );
  }
}

String humanSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

/// Words people search with → words that may appear in labels/text.
/// Grows in the vision step; kept here so search and tests share it.
const searchSynonyms = <String, List<String>>{
  'animal': ['dog', 'cat', 'cow', 'bird', 'horse', 'goat', 'sheep', 'elephant', 'monkey', 'fish', 'lion', 'tiger', 'puppy', 'kitten', 'pet', 'wildlife', 'animal'],
  'animals': ['animal'],
  'aadhar': ['aadhaar', 'aadhar', 'uidai', 'unique identification', 'government of india', 'आधार'],
  'aadhaar': ['aadhar'],
  'pan': ['permanent account number', 'income tax', 'pan card'],
  'passport': ['passport', 'republic of india', 'p<ind'],
  'license': ['licence', 'driving licence', 'driving license', 'dl no'],
  'licence': ['license'],
  'bill': ['invoice', 'receipt', 'total', 'amount due', 'gst'],
  'receipt': ['bill'],
  'marks': ['marksheet', 'grade', 'cgpa', 'sgpa', 'result', 'score'],
  'marksheet': ['marks'],
  'food': ['pizza', 'burger', 'biryani', 'dosa', 'meal', 'dish', 'cuisine', 'snack', 'dessert', 'drink'],
  'car': ['vehicle', 'automobile', 'bike', 'motorcycle', 'scooter'],
  'bike': ['motorcycle', 'bicycle', 'scooter', 'vehicle'],
  'people': ['person', 'man', 'woman', 'selfie', 'face', 'crowd', 'smile'],
  'person': ['people'],
  'screenshot': ['screen', 'screenshot', 'app', 'text', 'website'],
  'nature': ['tree', 'flower', 'plant', 'mountain', 'beach', 'sky', 'sunset', 'forest', 'river', 'sea'],
};

/// Expand a query word into itself + synonyms (one level deep).
List<String> expandQueryWord(String w) {
  final word = w.toLowerCase().trim();
  if (word.isEmpty) return const [];
  final out = <String>{word};
  final direct = searchSynonyms[word];
  if (direct != null) {
    for (final s in direct) {
      out.add(s);
      final nested = searchSynonyms[s];
      if (nested != null) out.addAll(nested);
    }
  }
  return out.toList();
}
