import 'package:path/path.dart' as p;

/// Pure decisions about the files inside BYTE's private folder: what each one
/// is, and whether the cleaner may remove it. No IO here, so it is unit-tested
/// (test/storage_audit_test.dart); [StorageAudit] / [StorageCleaner] in
/// storage_audit.dart do the walking and deleting.

/// What a file is (for the Storage screen bars and the cleaner).
enum StorageCat {
  wav('Recordings · WAV (not shrunk yet)', 'WAV recordings'),
  aac('Recordings · shrunk', 'Shrunk recordings'),
  photo('Photos', 'Photos'),
  video('Videos', 'Videos'),
  doc('Documents', 'Documents'),
  file('Other library files', 'Files'),
  thumbs('Thumbnails', 'Thumbnails'),
  db('Vault database', 'Vault'),
  backup('Backups & exports kept inside the app', 'Backup copies'),
  model('Offline speech model (Whisper)', 'Speech model'),
  picker('Leftover copies from the picker', 'Picker leftovers'),
  cache('Cache', 'Cache'),
  temp('Temporary / half-finished files', 'Temp files'),
  other('Other app data', 'Other');

  const StorageCat(this.label, this.short);
  final String label;
  final String short;

  /// Categories the user can do something about from the Storage screen.
  bool get cleanable => switch (this) {
        StorageCat.picker || StorageCat.cache || StorageCat.temp || StorageCat.backup => true,
        _ => false,
      };
}

/// The folders path_provider hands out, with '/' separators.
class StorageRoots {
  StorageRoots({required String support, required String cache, String docs = '', String external = ''})
      : support = _norm(support),
        cache = _norm(cache),
        docs = _norm(docs),
        external = _norm(external);
  final String support;
  final String cache;
  final String docs;

  /// `Android/data/<pkg>/files` — image_picker's camera shots land in Pictures/ here.
  final String external;

  static String _norm(String s) {
    var n = s.replaceAll('\\', '/');
    while (n.endsWith('/')) {
      n = n.substring(0, n.length - 1);
    }
    return n;
  }
}

/// One file on disk, as the audit saw it.
class AuditFile {
  const AuditFile({required this.path, required this.size, required this.modified, required this.cat});
  final String path;
  final int size;
  final DateTime modified;
  final StorageCat cat;

  String get name => p.basename(path);
}

String normPath(String s) => s.replaceAll('\\', '/');

final _uuidRe = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$', caseSensitive: false);

String? _relTo(String path, String root) {
  if (root.isEmpty) return null;
  final prefix = '$root/';
  return path.startsWith(prefix) ? path.substring(prefix.length) : null;
}

/// Which bucket a file belongs to, from its path alone.
StorageCat classify(String rawPath, StorageRoots roots) {
  final path = normPath(rawPath);
  final lower = p.basename(path).toLowerCase();
  final isTmp = lower.endsWith('.tmp') || lower.endsWith('.part');

  final inCache = _relTo(path, roots.cache);
  if (inCache != null) {
    final top = inCache.contains('/') ? inCache.substring(0, inCache.indexOf('/')) : '';
    // file_picker → cache/file_picker/…; image_picker → cache/<uuid>/<name> or
    // cache/scaled_<name>; our own share intents → cache/shared/… (also a copy).
    if (top == 'file_picker' || top == 'image_picker' || top == 'shared' || _uuidRe.hasMatch(top) || lower.startsWith('scaled_') || lower.startsWith('image_picker')) {
      return StorageCat.picker;
    }
    if (isTmp) return StorageCat.temp;
    return StorageCat.cache;
  }

  final inExternal = _relTo(path, roots.external);
  if (inExternal != null) {
    // image_picker saves the camera original here, then hands us a scaled copy.
    return inExternal.startsWith('Pictures/') || inExternal.startsWith('Movies/') ? StorageCat.picker : StorageCat.other;
  }

  final inSupport = _relTo(path, roots.support);
  if (inSupport != null) {
    if (isTmp) return StorageCat.temp;
    final top = inSupport.contains('/') ? inSupport.substring(0, inSupport.indexOf('/')) : '';
    switch (top) {
      case 'audio':
        if (lower.endsWith('.wav')) return StorageCat.wav;
        if (lower.endsWith('.m4a')) return StorageCat.aac;
        return StorageCat.file;
      case 'files':
        if (lower.startsWith('fix-')) return StorageCat.temp; // Fix-photo scratch file
        return _fileKind(lower);
      case 'thumbs':
        return lower.startsWith('frame-') ? StorageCat.temp : StorageCat.thumbs;
      case 'models':
        return StorageCat.model;
      case 'exports':
        return StorageCat.backup;
      case '':
        if (lower.endsWith('.zip')) return StorageCat.backup;
        if (lower.startsWith('cloud-')) return StorageCat.temp; // cloud-snapshot / cloud-restore
        if (lower.endsWith('.migrated') || lower.endsWith('.pre-restore')) return StorageCat.temp;
        if (lower.contains('byte_vault')) return StorageCat.db;
    }
    return StorageCat.other;
  }
  return StorageCat.other;
}

StorageCat _fileKind(String lower) {
  final ext = p.extension(lower).replaceFirst('.', '');
  if (const {'jpg', 'jpeg', 'png', 'webp', 'heic', 'heif', 'gif', 'bmp'}.contains(ext)) return StorageCat.photo;
  if (const {'mp4', 'mkv', 'mov', 'webm', '3gp', 'avi', 'm4v'}.contains(ext)) return StorageCat.video;
  if (const {'pdf', 'doc', 'docx', 'ppt', 'pptx', 'xls', 'xlsx', 'csv', 'txt', 'md', 'json'}.contains(ext)) return StorageCat.doc;
  return StorageCat.file;
}

/// Why the cleaner may delete [f] — or null to keep it.
///
/// [referenced] = every path the vault points at (audio.path, files.path,
/// files.thumb — deleted rows included; the 30-day purge handles those).
/// [existing] = every path the audit found (for the WAV/M4A twin rule).
/// Conservative on purpose: vault media is only removed when no row names
/// it AND it is older than a day; the database and the model are never touched.
String? cleanReason(
  AuditFile f, {
  required DateTime now,
  required Set<String> referenced,
  required Set<String> existing,
}) {
  final path = normPath(f.path);
  final age = now.difference(f.modified);
  final lower = f.name.toLowerCase();
  const hour = Duration(hours: 1);
  const day = Duration(hours: 24);

  switch (f.cat) {
    case StorageCat.temp:
      return age > hour ? 'half-finished or temporary file' : null;
    case StorageCat.picker:
      return age > hour ? 'copy left behind by the picker' : null;
    case StorageCat.cache:
      // Backup/export ZIPs built for the share sheet sit here; give them longer.
      if (lower.endsWith('.zip')) return age > const Duration(hours: 6) ? 'old backup/export ZIP in cache' : null;
      return age > hour ? 'cache' : null;
    case StorageCat.backup:
      if (age <= hour) return null; // may still be uploading / sharing
      if (lower == 'latest-backup.zip') return 'duplicate of the backup already in Downloads/BYTE';
      if (lower.startsWith('byte-export-')) return 'old export ZIP';
      return 'unfinished backup ZIP';
    case StorageCat.wav:
    case StorageCat.aac:
      if (referenced.contains(path)) return null;
      final twin = p.setExtension(path, f.cat == StorageCat.wav ? '.m4a' : '.wav');
      if (existing.contains(twin) && referenced.contains(twin)) return 'leftover copy of a shrunk/expanded recording';
      return age > day ? 'recording file no row in the vault points to' : null;
    case StorageCat.photo:
    case StorageCat.video:
    case StorageCat.doc:
    case StorageCat.file:
      if (referenced.contains(path)) return null;
      return age > day ? 'library file no row in the vault points to' : null;
    case StorageCat.thumbs:
      if (referenced.contains(path)) return null;
      return age > day ? 'thumbnail of something no longer in the vault' : null;
    case StorageCat.db:
    case StorageCat.model:
    case StorageCat.other:
      return null;
  }
}

/// The numbers behind the Storage screen and the Home suggestion.
class AuditReport {
  AuditReport({required this.at, required this.bytes, required this.counts, required this.biggest, this.rootsNote = ''});
  final DateTime at;
  final Map<StorageCat, int> bytes;
  final Map<StorageCat, int> counts;
  final List<AuditFile> biggest;
  final String rootsNote;

  int get total => bytes.values.fold(0, (a, b) => a + b);
  int of(StorageCat c) => bytes[c] ?? 0;
  int countOf(StorageCat c) => counts[c] ?? 0;

  /// Categories with something in them, biggest first.
  List<StorageCat> get ranked => [for (final c in StorageCat.values) if (of(c) > 0) c]..sort((a, b) => of(b).compareTo(of(a)));

  /// Build from a file list (pure, so tests can check the maths).
  static AuditReport fromFiles(List<AuditFile> files, {DateTime? at, int top = 15, String rootsNote = ''}) {
    final bytes = <StorageCat, int>{};
    final counts = <StorageCat, int>{};
    for (final f in files) {
      bytes[f.cat] = (bytes[f.cat] ?? 0) + f.size;
      counts[f.cat] = (counts[f.cat] ?? 0) + 1;
    }
    final sorted = [...files]..sort((a, b) => b.size.compareTo(a.size));
    return AuditReport(at: at ?? DateTime.now(), bytes: bytes, counts: counts, biggest: sorted.take(top).toList(), rootsNote: rootsNote);
  }

  /// Plain text the user can paste into a chat.
  String reportText({String appNote = ''}) {
    final b = StringBuffer()
      ..writeln('BYTE storage report · ${at.toIso8601String().substring(0, 16).replaceFirst('T', ' ')}')
      ..writeln('App data total: ${fmtBytes(total)}${appNote.isEmpty ? '' : ' ($appNote)'}')
      ..writeln();
    for (final c in ranked) {
      b.writeln('${fmtBytes(of(c)).padLeft(9)}  ${c.label} (${countOf(c)} file${countOf(c) == 1 ? '' : 's'})');
    }
    if (biggest.isNotEmpty) {
      b
        ..writeln()
        ..writeln('Biggest files:');
      for (final f in biggest) {
        b.writeln('${fmtBytes(f.size).padLeft(9)}  ${f.name}  [${f.cat.name}]  ${f.modified.toIso8601String().substring(0, 10)}');
      }
    }
    if (rootsNote.isNotEmpty) {
      b
        ..writeln()
        ..writeln(rootsNote);
    }
    return b.toString();
  }
}

String fmtBytes(int bytes) {
  if (bytes >= 1 << 30) return '${(bytes / (1 << 30)).toStringAsFixed(2)} GB';
  if (bytes >= 1 << 20) return '${(bytes / (1 << 20)).toStringAsFixed(bytes >= (100 << 20) ? 0 : 1)} MB';
  if (bytes >= 1 << 10) return '${(bytes / (1 << 10)).toStringAsFixed(0)} KB';
  return '$bytes B';
}

/// The one-line Home suggestion ("BYTE is using 862 MB — 610 MB is old
/// recordings. Shrink now?"), or null when the app is small enough.
({String title, String subtitle})? storageNag(AuditReport a, {int threshold = 250 << 20}) {
  if (a.total <= threshold) return null;
  final ranked = a.ranked;
  if (ranked.isEmpty) return null;
  final top = ranked.first;
  final what = switch (top) {
    StorageCat.wav => 'old recordings not shrunk yet',
    StorageCat.aac => 'shrunk recordings',
    StorageCat.photo => 'photos',
    StorageCat.video => 'videos',
    StorageCat.doc => 'documents',
    StorageCat.file => 'library files',
    StorageCat.thumbs => 'thumbnails',
    StorageCat.db => 'the vault database',
    StorageCat.backup => 'backup copies kept inside the app',
    StorageCat.model => 'the offline speech model',
    StorageCat.picker => 'leftover picker copies',
    StorageCat.cache => 'cache',
    StorageCat.temp => 'temporary files',
    StorageCat.other => 'other app data',
  };
  final ask = switch (top) {
    StorageCat.wav => 'Shrink now?',
    StorageCat.picker || StorageCat.cache || StorageCat.temp || StorageCat.backup || StorageCat.thumbs => 'Clean up now?',
    _ => 'See what can go?',
  };
  final parts = [for (final c in ranked.take(3)) '${c.short} ${fmtBytes(a.of(c))}'];
  return (
    title: 'BYTE is using ${fmtBytes(a.total)} — ${fmtBytes(a.of(top))} is $what. $ask',
    subtitle: '${parts.join(' · ')}. Opens Storage.',
  );
}
