import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'db.dart';

/// Builds a ZIP of everything in open formats: Markdown notes, WAV audio,
/// a CSV index and a full JSON dump. Readable without BYTE, forever.
class Exporter {
  Exporter._();

  static Future<File> exportAll({void Function(String)? onStatus}) async {
    final db = AppDb.instance.db;
    // Private things are left out: this ZIP can be read by anyone.
    final items = await db.query('items', where: 'deleted_at IS NULL AND private = 0');
    final audio = await db.rawQuery('SELECT a.* FROM audio a JOIN items i ON i.id = a.item_id WHERE i.private = 0');
    final audioById = {for (final a in audio) a['item_id'] as String: a};

    final stamp = _stamp(DateTime.now());
    final outDir = await _exportDir();
    final zipPath = p.join(outDir.path, 'byte-export-$stamp.zip');

    final archive = Archive();
    {
      final csv = StringBuffer('id,type,title,created,updated,tags,file\n');
      var n = 0;
      for (final it in items) {
        n++;
        onStatus?.call('Packing $n of ${items.length}…');
        final id = it['id'] as String;
        final type = it['type'] as String;
        final title = (it['title'] as String? ?? '').trim();
        final created = DateTime.fromMillisecondsSinceEpoch(it['created_at'] as int);
        final updated = DateTime.fromMillisecondsSinceEpoch(it['updated_at'] as int);
        final tags = it['tags'] as String? ?? '';
        String fileInZip = '';

        if (type == 'note') {
          fileInZip = 'notes/${_slug(created, title.isEmpty ? id : title)}.md';
          final body = it['body'] as String? ?? '';
          final md = StringBuffer()
            ..writeln('# ${title.isEmpty ? 'Untitled' : title}')
            ..writeln()
            ..writeln('- created: ${created.toIso8601String()}')
            ..writeln('- updated: ${updated.toIso8601String()}')
            ..writeln('- tags: $tags')
            ..writeln()
            ..writeln(body);
          archive.addFile(ArchiveFile.string(fileInZip, md.toString()));
        } else if (type == 'audio') {
          final a = audioById[id];
          final src = a == null ? null : File(a['path'] as String);
          if (src != null && await src.exists()) {
            fileInZip = 'audio/${_slug(created, title.isEmpty ? id : title)}${p.extension(src.path)}';
            archive.addFile(ArchiveFile.bytes(fileInZip, await src.readAsBytes()));
          }
          final transcript = (a?['clean_text'] as String? ?? '').trim();
          if (transcript.isNotEmpty) {
            final mdPath = 'audio/${_slug(created, title.isEmpty ? id : title)}.md';
            archive.addFile(ArchiveFile.string(mdPath, '# $title\n\n$transcript\n'));
          }
        }

        csv.writeln([
          id,
          type,
          _csv(title),
          created.toIso8601String(),
          updated.toIso8601String(),
          _csv(tags),
          fileInZip,
        ].join(','));
      }

      archive.addFile(ArchiveFile.string('index.csv', csv.toString()));

      final dump = const JsonEncoder.withIndent('  ').convert({
        'exported_at': DateTime.now().toIso8601String(),
        'app': 'BYTE',
        'items': items,
        'audio': audio,
      });
      archive.addFile(ArchiveFile.string('byte.json', dump));

      const readme = '''
BYTE export
===========
notes/   one Markdown file per note (title, dates, tags, body)
audio/   voice notes as WAV (16 kHz mono) + .md transcript where one exists
index.csv  one row per item
byte.json  full raw dump of the database rows

Everything here is in open formats. No app is needed to read it.
''';
      archive.addFile(ArchiveFile.string('README.txt', readme));
    }

    onStatus?.call('Compressing…');
    final bytes = ZipEncoder().encode(archive);
    final out = File(zipPath);
    await out.writeAsBytes(bytes, flush: true);
    return out;
  }

  static Future<Directory> _exportDir() async {
    Directory base;
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      base = await getDownloadsDirectory() ?? await getApplicationSupportDirectory();
    } else {
      // Cache, not app data: the share sheet reads it, then the storage
      // cleaner drops it (an export holds every recording — hundreds of MB).
      base = await getTemporaryDirectory();
      base = Directory(p.join(base.path, 'exports'));
    }
    if (!await base.exists()) await base.create(recursive: true);
    return base;
  }

  static String _stamp(DateTime t) =>
      '${t.year}${two(t.month)}${two(t.day)}-${two(t.hour)}${two(t.minute)}';
  static String two(int v) => v.toString().padLeft(2, '0');

  static String _slug(DateTime created, String title) {
    final t = title
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9஀-௿]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    final short = t.length > 40 ? t.substring(0, 40) : t;
    return '${created.year}-${two(created.month)}-${two(created.day)}-${short.isEmpty ? 'item' : short}';
  }

  static String _csv(String s) =>
      '"${s.replaceAll('"', '""').replaceAll('\n', ' ')}"';
}
