import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../shared/motion.dart';
import '../../shared/theme.dart';
import '../../shared/ui.dart';
import 'notes_repo.dart';

/// Bring notes from another app into BYTE — with permission, and reversible.
///
/// Android never lets one app read another app's notes, so the path is the one
/// every notes app offers: export (Google Keep → Takeout zip, Samsung Notes →
/// text, OneNote / Notion / Apple Notes → text, Markdown or HTML), then pick
/// those files here. Every imported note is tagged "imported" and the whole
/// batch can be undone in one tap (notes go to the 30-day bin, nothing is
/// destroyed). Parsing is pure and static so it can be unit-tested.
class ImportedNote {
  const ImportedNote({required this.title, required this.body, this.tags = const []});
  final String title;
  final String body;
  final List<String> tags;

  bool get isEmpty => title.trim().isEmpty && body.trim().isEmpty;
}

class ImportBatch {
  const ImportBatch({required this.at, required this.ids, required this.source});
  final DateTime at;
  final List<String> ids;
  final String source;

  Map<String, dynamic> toJson() => {'at': at.millisecondsSinceEpoch, 'ids': ids, 'source': source};
  static ImportBatch? fromJson(String? s) {
    if (s == null || s.isEmpty) return null;
    try {
      final j = jsonDecode(s) as Map<String, dynamic>;
      return ImportBatch(
        at: DateTime.fromMillisecondsSinceEpoch(j['at'] as int),
        ids: [for (final x in j['ids'] as List) '$x'],
        source: (j['source'] as String?) ?? '',
      );
    } catch (_) {
      return null;
    }
  }
}

class NotesImport {
  NotesImport._();

  static const tag = 'imported';
  static const _kLast = 'notes_import_last';
  static const textExt = {'txt', 'md', 'markdown', 'text'};
  static const htmlExt = {'html', 'htm'};
  static const jsonExt = {'json'};
  static const zipExt = {'zip'};

  static bool supported(String name) {
    final e = _ext(name);
    return textExt.contains(e) || htmlExt.contains(e) || jsonExt.contains(e) || zipExt.contains(e);
  }

  // ───────────── parsing (pure) ─────────────

  /// Notes inside one picked file. A zip (Google Takeout) is opened and every
  /// note file inside is parsed; anything unknown is skipped quietly.
  static List<ImportedNote> parseFile(String name, Uint8List bytes, {int depth = 0}) {
    final e = _ext(name);
    if (!supported(name)) return const [];
    if (zipExt.contains(e)) {
      if (depth > 1) return const [];
      final out = <ImportedNote>[];
      try {
        final archive = ZipDecoder().decodeBytes(bytes);
        for (final f in archive.files) {
          if (!f.isFile || !supported(f.name) || f.name.contains('__MACOSX')) continue;
          out.addAll(parseFile(f.name, Uint8List.fromList(f.content), depth: depth + 1));
        }
      } catch (_) {}
      return out;
    }
    final text = utf8.decode(bytes, allowMalformed: true);
    final n = jsonExt.contains(e)
        ? parseKeepJson(name, text)
        : htmlExt.contains(e)
            ? parseHtml(name, text)
            : parseText(name, text);
    return n == null || n.isEmpty ? const [] : [n];
  }

  /// Plain text / Markdown: a short first line becomes the title (a "# " is
  /// dropped); otherwise the file name is the title and everything is body.
  static ImportedNote? parseText(String name, String text) {
    final clean = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n').trim();
    if (clean.isEmpty) return null;
    final lines = clean.split('\n');
    final first = lines.first.trim().replaceFirst(RegExp(r'^#+\s*'), '');
    final restLines = lines.skip(1).skipWhile((l) => l.trim().isEmpty).toList();
    // A short first line is the title (a one-liner is all title); a long
    // first line means the file has no title, so the file name is used.
    if (first.length <= 80) return ImportedNote(title: first, body: restLines.join('\n').trimRight());
    return ImportedNote(title: _baseName(name), body: clean);
  }

  /// HTML (Google Keep / Takeout per-note pages, Evernote single notes, any
  /// "save as HTML"): <title> or first heading becomes the title, the visible
  /// text the body. Keep's own header line (date) and label chips are dropped.
  static ImportedNote? parseHtml(String name, String html) {
    String title = RegExp(r'<title[^>]*>([\s\S]*?)</title>', caseSensitive: false).firstMatch(html)?.group(1)?.trim() ?? '';
    final h1 = RegExp(r'<h[12][^>]*>([\s\S]*?)</h[12]>', caseSensitive: false).firstMatch(html)?.group(1);
    if (title.isEmpty && h1 != null) title = _plain(h1);
    final tags = <String>[];
    // Google Keep: <span class="label-name">Shopping</span>
    for (final m in RegExp(r'class="label-name"[^>]*>([^<]*)<', caseSensitive: false).allMatches(html)) {
      final t = _plain(m.group(1)!).trim();
      if (t.isNotEmpty) tags.add(t);
    }
    var body = html;
    final bodyTag = RegExp(r'<body[^>]*>([\s\S]*?)</body>', caseSensitive: false).firstMatch(html);
    if (bodyTag != null) body = bodyTag.group(1)!;
    body = body
        .replaceAll(RegExp(r'<(script|style)[^>]*>[\s\S]*?</\1>', caseSensitive: false), '')
        .replaceAll(RegExp(r'<div class="heading">[\s\S]*?</div>', caseSensitive: false), '') // Keep's date line
        .replaceAll(RegExp(r'<div class="(?:labels|chips)">[\s\S]*?</div>', caseSensitive: false), '')
        .replaceAll(RegExp(r'<(?:h[1-6]|title)[^>]*>[\s\S]*?</(?:h[1-6]|title)>', caseSensitive: false), '')
        .replaceAll(RegExp(r'<input[^>]*type="checkbox"[^>]*checked[^>]*>', caseSensitive: false), '☑ ')
        .replaceAll(RegExp(r'<input[^>]*type="checkbox"[^>]*>', caseSensitive: false), '☐ ')
        .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'</(?:p|div|li|tr|h[1-6])>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'<li[^>]*>', caseSensitive: false), '• ');
    final text = _plain(body).split('\n').map((l) => l.trimRight()).join('\n').replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
    if (title.isEmpty && text.isEmpty) return null;
    if (title.isEmpty) {
      final n = parseText(name, text);
      return n == null ? null : ImportedNote(title: n.title, body: n.body, tags: tags);
    }
    return ImportedNote(title: _plain(title), body: text, tags: tags);
  }

  /// Google Keep's Takeout JSON: {title, textContent | listContent[{text,
  /// isChecked}], labels[{name}], isTrashed, isArchived}. Other JSON with a
  /// "title"/"body" or "text" pair is accepted too.
  static ImportedNote? parseKeepJson(String name, String text) {
    Map<String, dynamic> j;
    try {
      final d = jsonDecode(text);
      if (d is! Map<String, dynamic>) return null;
      j = d;
    } catch (_) {
      return null;
    }
    if (j['isTrashed'] == true) return null;
    final title = (j['title'] ?? '').toString().trim();
    var body = (j['textContent'] ?? j['body'] ?? j['text'] ?? j['content'] ?? '').toString();
    final list = j['listContent'];
    if (list is List) {
      body = [
        for (final e in list.whereType<Map>()) '${e['isChecked'] == true ? '☑' : '☐'} ${e['text'] ?? ''}',
      ].join('\n');
    }
    final tags = <String>[];
    final labels = j['labels'];
    if (labels is List) {
      for (final l in labels.whereType<Map>()) {
        final n = (l['name'] ?? '').toString().trim();
        if (n.isNotEmpty) tags.add(n);
      }
    }
    if (title.isEmpty && body.trim().isEmpty) return null;
    if (title.isEmpty) {
      final n = parseText(name, body);
      return n == null ? null : ImportedNote(title: n.title, body: n.body, tags: tags);
    }
    return ImportedNote(title: title, body: body.trim(), tags: tags);
  }

  static String _plain(String html) {
    var s = html.replaceAll(RegExp(r'<[^>]+>'), '');
    s = s
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&apos;', "'")
        .replaceAllMapped(RegExp(r'&#(\d+);'), (m) => String.fromCharCode(int.parse(m.group(1)!)))
        .replaceAllMapped(RegExp(r'&#x([0-9a-fA-F]+);'), (m) => String.fromCharCode(int.parse(m.group(1)!, radix: 16)));
    return s;
  }

  static String _ext(String name) {
    final i = name.lastIndexOf('.');
    return i < 0 ? '' : name.substring(i + 1).toLowerCase();
  }

  static String _baseName(String name) {
    var s = name.replaceAll('\\', '/');
    s = s.substring(s.lastIndexOf('/') + 1);
    final i = s.lastIndexOf('.');
    return (i > 0 ? s.substring(0, i) : s).replaceAll('_', ' ').trim();
  }

  static String _key(String title, String body) => '${title.trim().toLowerCase()}\u0000${body.trim().toLowerCase()}';

  // ───────────── importing ─────────────

  static Future<ImportBatch?> lastBatch() async {
    final p = await SharedPreferences.getInstance();
    return ImportBatch.fromJson(p.getString(_kLast));
  }

  /// Saves every note (skipping ones BYTE already has word for word) and
  /// remembers the batch so it can be undone. Returns (added, skipped).
  static Future<(int, int)> import(List<ImportedNote> notes, {required String source}) async {
    final repo = NotesRepo.instance;
    final existing = {for (final n in await repo.list()) _key(n.title, n.body)};
    final ids = <String>[];
    var skipped = 0;
    for (final n in notes) {
      if (n.isEmpty) continue;
      final k = _key(n.title, n.body);
      if (existing.contains(k)) {
        skipped++;
        continue;
      }
      existing.add(k);
      final tags = <String>{tag, ...n.tags.map((t) => t.trim()).where((t) => t.isNotEmpty)}.toList();
      final saved = await repo.create(title: n.title.trim(), body: n.body.trim(), tags: tags);
      ids.add(saved.id);
    }
    if (ids.isNotEmpty) {
      final p = await SharedPreferences.getInstance();
      await p.setString(_kLast, jsonEncode(ImportBatch(at: DateTime.now(), ids: ids, source: source).toJson()));
    }
    return (ids.length, skipped);
  }

  /// Puts the last batch in the bin (recoverable for 30 days). Returns how many.
  static Future<int> undoLast() async {
    final b = await lastBatch();
    if (b == null) return 0;
    final repo = NotesRepo.instance;
    for (final id in b.ids) {
      await repo.delete(id);
    }
    final p = await SharedPreferences.getInstance();
    await p.remove(_kLast);
    return b.ids.length;
  }

  /// Bring the last undone batch back (the "oops" after an undo).
  static Future<int> redoLast(ImportBatch b) async {
    final repo = NotesRepo.instance;
    for (final id in b.ids) {
      await repo.restore(id);
    }
    final p = await SharedPreferences.getInstance();
    await p.setString(_kLast, jsonEncode(b.toJson()));
    return b.ids.length;
  }

  // ───────────── UI ─────────────

  /// The whole flow from a tap: explain → pick files → preview → import → Undo.
  static Future<void> start(BuildContext context) async {
    final last = await lastBatch();
    if (!context.mounted) return;
    final choice = await showGlassSheet<String>(
      context,
      builder: (ctx) => _ImportSheet(last: last),
    );
    if (!context.mounted || choice == null) return;
    if (choice == 'undo') {
      final b = last;
      final n = await undoLast();
      if (!context.mounted) return;
      Haptics.confirm();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Moved $n imported notes to the bin.'),
        persist: false, // goes away by itself, Undo or not
        action: b == null ? null : SnackBarAction(label: 'Undo', onPressed: () => redoLast(b)),
      ));
      return;
    }
    if (choice != 'pick') return;
    List<PlatformFile> files;
    try {
      files = await FilePicker.pickFiles(type: FileType.any);
    } catch (e) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Couldn\'t open the picker: $e')));
      return;
    }
    if (!context.mounted || files.isEmpty) return;
    final notes = <ImportedNote>[];
    var unsupported = 0;
    for (final f in files) {
      if (!supported(f.name)) {
        unsupported++;
        continue;
      }
      try {
        notes.addAll(parseFile(f.name, await f.readAsBytes()));
      } catch (_) {
        unsupported++;
      }
    }
    if (!context.mounted) return;
    if (notes.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(unsupported > 0
            ? 'Those files aren\'t notes BYTE can read. Export as text, Markdown, HTML, Keep JSON or a Takeout zip.'
            : 'No notes found in those files.'),
      ));
      return;
    }
    final go = await showGlassSheet<bool>(context, builder: (ctx) => _PreviewSheet(notes: notes, files: files.length));
    if (!context.mounted || go != true) return;
    final source = files.length == 1 ? files.first.name : '${files.length} files';
    final (added, skipped) = await import(notes, source: source);
    if (!context.mounted) return;
    Haptics.confirm();
    final msg = StringBuffer('Imported $added ${added == 1 ? 'note' : 'notes'}');
    if (skipped > 0) msg.write(' · $skipped already in BYTE');
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg.toString()),
      duration: const Duration(seconds: 6),
      persist: false, // goes away by itself, Undo or not
      action: added == 0 ? null : SnackBarAction(label: 'Undo', onPressed: () => undoLast()),
    ));
  }
}

class _ImportSheet extends StatelessWidget {
  const _ImportSheet({required this.last});
  final ImportBatch? last;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final b = last;
    return Padding(
      padding: const EdgeInsets.fromLTRB(ByteSpace.page, 8, ByteSpace.page, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Import notes', style: tt.titleLarge),
          const SizedBox(height: 8),
          Text(
            'Android doesn\'t let one app read another app\'s notes, so export them first, then pick the files here. '
            'Each one becomes a BYTE note tagged "imported". Nothing is changed in the other app, and you can undo the whole import in one tap.',
            style: tt.bodyMedium?.copyWith(color: ByteColors.textDim),
          ),
          const SizedBox(height: 14),
          _how('Google Keep', 'takeout.google.com → Keep only → download the zip → pick the zip here'),
          _how('Samsung Notes', 'open a note → ⋮ → Save as file → Text file'),
          _how('OneNote / Notion / Evernote', 'Export → Markdown, HTML or Text'),
          _how('Apple Notes', 'Share → Save to Files as text'),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: Pressable(
                  onTap: () => Navigator.of(context).pop('pick'),
                  child: Container(
                    height: 48,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(color: ByteColors.accent, borderRadius: BorderRadius.circular(16)),
                    child: Text('Choose files', style: tt.titleMedium?.copyWith(color: ByteColors.onAccent, fontWeight: FontWeight.w700)),
                  ),
                ),
              ),
            ],
          ),
          if (b != null && b.ids.isNotEmpty) ...[
            const SizedBox(height: 10),
            Center(
              child: TextButton(
                onPressed: () => Navigator.of(context).pop('undo'),
                child: Text('Undo last import · ${b.ids.length} ${b.ids.length == 1 ? 'note' : 'notes'} from ${b.source}'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _how(String app, String steps) => Builder(
        builder: (context) {
          final tt = Theme.of(context).textTheme;
          return Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: RichText(
              text: TextSpan(
                style: tt.bodySmall?.copyWith(color: ByteColors.textDim),
                children: [
                  TextSpan(text: '$app  ', style: TextStyle(color: ByteColors.text, fontWeight: FontWeight.w700)),
                  TextSpan(text: steps),
                ],
              ),
            ),
          );
        },
      );
}

class _PreviewSheet extends StatelessWidget {
  const _PreviewSheet({required this.notes, required this.files});
  final List<ImportedNote> notes;
  final int files;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final shown = notes.take(6).toList();
    return Padding(
      padding: const EdgeInsets.fromLTRB(ByteSpace.page, 8, ByteSpace.page, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('${notes.length} ${notes.length == 1 ? 'note' : 'notes'} found', style: tt.titleLarge),
          const SizedBox(height: 4),
          Text('in $files ${files == 1 ? 'file' : 'files'} · notes BYTE already has are skipped', style: tt.bodySmall?.copyWith(color: ByteColors.textDim)),
          const SizedBox(height: 12),
          for (final n in shown)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(width: 6, height: 6, margin: const EdgeInsets.only(top: 7, right: 10), decoration: BoxDecoration(color: ByteColors.accent, shape: BoxShape.circle)),
                  Expanded(
                    child: Text(
                      n.title.trim().isEmpty ? n.body.split('\n').first : n.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: tt.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            ),
          if (notes.length > shown.length) Text('and ${notes.length - shown.length} more', style: tt.bodySmall?.copyWith(color: ByteColors.textDim)),
          const SizedBox(height: 12),
          YesNo(yes: 'Import', no: 'Cancel', onYes: () => Navigator.of(context).pop(true), onNo: () => Navigator.of(context).pop(false)),
        ],
      ),
    );
  }
}
