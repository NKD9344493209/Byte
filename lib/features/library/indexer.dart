import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_image_labeling/google_mlkit_image_labeling.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

import '../../core/db.dart';
import '../../core/drive_media.dart';
import '../../core/gallery.dart';
import '../../core/private_space.dart';
import '../../core/user_busy.dart';
import '../albums/albums.dart';
import 'library_item.dart';
import 'library_repo.dart';
import '../search/search_text.dart';

/// Works through newly added files one by one and reads them, so one word
/// in Search finds them later: a preview picture, the words in a photo (OCR,
/// on the phone), every page of a PDF (also when the pages are only scans),
/// the text of Word / PowerPoint / Excel files, and the title of a link.
class LibraryIndexer {
  LibraryIndexer._();
  static final LibraryIndexer instance = LibraryIndexer._();

  /// A very long PDF is read up to this page.
  static const maxPdfPages = 300;

  /// At most this many scanned pages of one PDF go through OCR (each takes
  /// about half a second on the phone).
  static const maxOcrPages = 40;

  final ValueNotifier<String> status = ValueNotifier<String>('');
  bool _running = false;
  Timer? _debounce;

  void start() {
    LibraryRepo.instance.revision.addListener(_kick);
    _kick();
  }

  /// Something changed in the Library since the second look last checked.
  bool _woken = false;

  void _kick() {
    _woken = true;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), run);
  }

  Future<void> run() async {
    if (_running) return;
    _running = true;
    try {
      while (true) {
        final pending = await LibraryRepo.instance.pendingIndex();
        if (pending.isEmpty) {
          // Reading is done: what waited for it (uploads, locking private
          // files) goes ahead now, not after the second look.
          status.value = '';
          unawaited(DriveMedia.kick());
          unawaited(PrivateSpace.sealPending());
          // Older photos get the quick second look (it steps aside as soon
          // as something new comes in to be read).
          if (await _lookAgain()) continue;
          break;
        }
        var n = 0;
        for (final item in pending) {
          // (A private file is never named outside the private space.)
          // Reading a photo is heavy work for the phone. While your finger is
          // on the screen the gallery waits its turn, so scrolling stays smooth.
          if (item.fromGallery) await UserBusy.whenIdle();
          status.value = item.private ? 'Reading…' : 'Reading ${item.displayTitle}…';
          await _index(item);
          // The lists are told every few items, not after each one: with a
          // whole gallery to read, a reload per photo would make them stutter.
          if (++n % (item.fromGallery ? 40 : 5) == 0) LibraryRepo.instance.touch();
          // A breath between gallery photos keeps scrolling smooth meanwhile.
          if (item.fromGallery) await Future<void>.delayed(const Duration(milliseconds: 40));
        }
        LibraryRepo.instance.touch();
      }
    } finally {
      _running = false;
      status.value = '';
      // Reading done → those photos/videos may now leave the phone.
      unawaited(DriveMedia.kick());
      // …and private files that were waiting to be read can be locked now
      // (only if the private space is open; otherwise at its next opening).
      unawaited(PrivateSpace.sealPending());
    }
  }

  Future<void> _index(LibraryItem item) async {
    final repo = LibraryRepo.instance;
    // Re-index of something that lives in Drive: bring the file back first.
    if ((item.kind == LibraryKind.photo || item.kind == LibraryKind.video) && item.path.isNotEmpty && !File(item.path).existsSync()) {
      if (await DriveMedia.ensureLocal(item) == null) {
        // Offline or signed out: don't index a missing file — that would wipe
        // the preview and the text BYTE already read. Keep them; try later.
        await repo.setIndexed(item.id, quiet: true, status: 'failed');
        return;
      }
    }
    // A gallery photo BYTE may not open (access was reduced to "selected
    // photos" or taken away): don't record it as read. It is tried again when
    // access comes back.
    if (item.fromGallery) {
      try {
        final raf = await File(item.path).open();
        await raf.close();
      } catch (_) {
        await repo.setIndexed(item.id, quiet: true, status: 'failed');
        return;
      }
    }
    try {
      await repo.setIndexed(item.id, quiet: true, status: 'working');
      switch (item.kind) {
        case LibraryKind.photo:
          final thumb = await _photoThumb(item);
          final seen = await _see([item.path]);
          await repo.setIndexed(
            item.id, quiet: true,
            thumb: thumb,
            text: seen.text,
            labels: seen.labels,
            seen: seen.seen,
            status: 'done',
          );
        case LibraryKind.video:
          final thumb = await _videoThumb(item);
          // Looking into the frames takes a second or two per video: done for
          // videos you add yourself, skipped for a whole gallery of them.
          final frames = item.fromGallery ? const <String>[] : await _videoFrames(item);
          final seen = await _see(frames, ocr: false);
          for (final f in frames) {
            try {
              await File(f).delete();
            } catch (_) {}
          }
          await repo.setIndexed(
            item.id, quiet: true,
            thumb: thumb,
            text: seen.text,
            labels: seen.labels,
            status: 'done',
          );
        case LibraryKind.doc:
          final text = await _docText(item);
          final cover = item.ext == 'pdf' ? await _pdfCover(item) : '';
          await repo.setIndexed(
            item.id, quiet: true,
            text: text ?? '',
            thumb: cover.isEmpty ? null : cover,
            status: text == null ? 'unsupported' : 'done',
          );
        case LibraryKind.link:
          final meta = await _linkMeta(item.url);
          await repo.setIndexed(
            item.id, quiet: true,
            text: meta.text,
            thumb: meta.thumb,
            title: meta.title,
            status: 'done',
          );
        case LibraryKind.audio:
        case LibraryKind.note:
          await repo.setIndexed(item.id, quiet: true, status: 'done');
      }
    } catch (e, st) {
      debugPrint('[index] ${item.id}: $e\n$st');
      await repo.setIndexed(item.id, quiet: true, status: 'failed');
    }
  }

  // ───────────── thumbnails ─────────────

  /// 480 px wide JPEG (~40 KB). PNG was 300–600 KB per photo.
  Future<String> _photoThumb(LibraryItem item) async {
    try {
      // A gallery photo: Android already has a small picture of it.
      final quick = await _galleryThumb(item);
      if (quick.isNotEmpty) return quick;
      final bytes = await File(item.path).readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes, targetWidth: 480);
      final frame = await codec.getNextFrame();
      final w = frame.image.width;
      final h = frame.image.height;
      final data = await frame.image.toByteData(format: ui.ImageByteFormat.rawRgba);
      frame.image.dispose();
      codec.dispose();
      if (data == null) return '';
      final jpg = await compute(_rgbaToJpg, (data.buffer.asUint8List(), w, h));
      final out = File(p.join((await LibraryRepo.instance.thumbsDir()).path, '${item.id}.jpg'));
      await out.writeAsBytes(jpg, flush: true);
      return out.path;
    } catch (e) {
      debugPrint('[index] photo thumb: $e');
      return '';
    }
  }

  /// Android's ready-made small picture of a gallery photo or video ('' when
  /// this is not a gallery item, or Android has none).
  Future<String> _galleryThumb(LibraryItem item) async {
    if (!item.fromGallery) return '';
    final out = p.join((await LibraryRepo.instance.thumbsDir()).path, '${item.id}.jpg');
    return await Gallery.thumb(item.mediaKey, out) ? out : '';
  }

  static const _files = MethodChannel('byte/files');

  /// A frame from ~1 s in, via Android's MediaMetadataRetriever (MainActivity).
  Future<String> _videoThumb(LibraryItem item) async {
    if (!Platform.isAndroid) return '';
    final quick = await _galleryThumb(item);
    if (quick.isNotEmpty) return quick;
    try {
      final dir = (await LibraryRepo.instance.thumbsDir()).path;
      final out = p.join(dir, '${item.id}.jpg');
      final ok = await _files.invokeMethod<bool>('videoThumb', {
        'path': item.path,
        'out': out,
        'maxWidth': 480,
      });
      return ok == true ? out : '';
    } catch (e) {
      debugPrint('[index] video thumb: $e');
      return '';
    }
  }

  // ───────────── vision (on-device ML Kit, Android) ─────────────

  /// Reads text (OCR) and labels what's in the pictures. Nothing leaves the
  /// phone. Labels are plain English words ("Dog", "Food", "Document").
  /// `seen` says how sure the phone was of each thing ("food=91;dish=74",
  /// or "-" when it saw nothing) — the albums sort by it.
  Future<({String text, List<String> labels, String seen})> _see(List<String> paths, {bool ocr = true}) async {
    if (!Platform.isAndroid || paths.isEmpty) return (text: '', labels: <String>[], seen: '');
    final labels = <String, double>{};
    final textBuf = StringBuffer();
    TextRecognizer? recognizer;
    ImageLabeler? labeler;
    try {
      labeler = ImageLabeler(options: ImageLabelerOptions(confidenceThreshold: 0.5));
      if (ocr) recognizer = TextRecognizer(script: TextRecognitionScript.latin);
      for (final path in paths) {
        final input = InputImage.fromFilePath(path);
        try {
          final found = await labeler.processImage(input);
          for (final l in found) {
            final k = l.label.toLowerCase();
            if ((labels[k] ?? 0) < l.confidence) labels[k] = l.confidence;
          }
        } catch (e) {
          debugPrint('[index] labels: $e');
        }
        if (recognizer != null) {
          try {
            final r = await recognizer.processImage(input);
            final t = r.text.trim();
            if (t.isNotEmpty) textBuf.writeln(t);
          } catch (e) {
            debugPrint('[index] ocr: $e');
          }
        }
      }
    } finally {
      await recognizer?.close();
      await labeler?.close();
    }
    final sorted = labels.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    // Search keeps the surer ones (as before); the albums get all, with how sure.
    final words = [
      for (final e in sorted.where((e) => e.value >= 0.55).take(12)) e.key,
    ];
    // Broad buckets so "animal", "food", "people" searches hit.
    final extra = <String>{};
    for (final w in words) {
      for (final kv in searchSynonyms.entries) {
        if (kv.value.contains(w) && kv.key != w) extra.add(kv.key);
      }
    }
    return (text: textBuf.toString().trim(), labels: [...words, ...extra], seen: _scores(labels));
  }

  /// {food: 0.91, dish: 0.74} → "food=91;dish=74" ("-" when nothing was seen).
  static String _scores(Map<String, double> labels) {
    if (labels.isEmpty) return '-';
    final sorted = labels.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    return [for (final e in sorted.take(24)) '${e.key.replaceAll(';', ' ').replaceAll('=', ' ')}=${(e.value * 100).round()}'].join(';');
  }

  /// A second, quick look at photos that were read before BYTE kept how sure
  /// it was of what it saw: only the small preview is looked at (a few
  /// hundredths of a second each), nothing is read again. The albums are
  /// sorted again from it. True when it stopped because something new came
  /// in to be read.
  Future<bool> _lookAgain() async {
    if (!Platform.isAndroid) return false;
    final db = AppDb.instance.db;
    ImageLabeler? labeler;
    try {
      // (A limit on the rounds, so nothing can spin this for ever.)
      for (var round = 0; round < 2000; round++) {
        if ((await LibraryRepo.instance.pendingIndex()).isNotEmpty) return true;
        final rows = await db.rawQuery(
          "SELECT f.item_id AS id, f.thumb AS thumb, f.path AS path FROM files f JOIN items i ON i.id = f.item_id "
          "WHERE i.type = 'photo' AND i.deleted_at IS NULL AND i.private = 0 AND f.index_status = 'done' AND f.seen = '' "
          "ORDER BY i.created_at DESC LIMIT 40",
        );
        if (rows.isEmpty) break;
        status.value = 'Sorting your photos…';
        labeler ??= ImageLabeler(options: ImageLabelerOptions(confidenceThreshold: 0.5));
        for (final r in rows) {
          await UserBusy.whenIdle(quietMs: 600, maxWaitMs: 5000);
          // Something was added meanwhile: it is read first.
          if (_woken) {
            _woken = false;
            if ((await LibraryRepo.instance.pendingIndex()).isNotEmpty) return true;
          }
          final id = '${r['id']}';
          final thumb = '${r['thumb'] ?? ''}';
          final path = '${r['path'] ?? ''}';
          final file = thumb.isNotEmpty && File(thumb).existsSync() ? thumb : (path.isNotEmpty && File(path).existsSync() ? path : '');
          var seen = '-';
          if (file.isNotEmpty) {
            try {
              final found = await labeler.processImage(InputImage.fromFilePath(file));
              final scores = <String, double>{};
              for (final l in found) {
                final k = l.label.toLowerCase();
                if ((scores[k] ?? 0) < l.confidence) scores[k] = l.confidence;
              }
              seen = _scores(scores);
            } catch (e) {
              debugPrint('[index] look again: $e');
            }
          }
          // Only when it is still as it was: a photo read again meanwhile keeps its new answer.
          await db.rawUpdate(
            "UPDATE files SET seen = ?, sorted = 0 WHERE item_id = ? AND seen = '' AND item_id IN (SELECT id FROM items WHERE private = 0)",
            [seen, id],
          );
        }
        // The albums are sorted again now and then, not after every handful
        // (each time makes the lists reload).
        if (round % 5 == 4) unawaited(Albums.sort());
      }
      unawaited(Albums.sort());
    } catch (e) {
      debugPrint('[index] look again: $e');
    } finally {
      await labeler?.close();
    }
    return false;
  }

  /// A few frames spread across the video, via MainActivity.
  Future<List<String>> _videoFrames(LibraryItem item) async {
    if (!Platform.isAndroid) return const [];
    try {
      final dir = (await LibraryRepo.instance.thumbsDir()).path;
      final out = await _files.invokeMethod<List<dynamic>>('videoFrames', {
        'path': item.path,
        'outDir': dir,
        'prefix': 'frame-${item.id}',
        'count': 4,
        'maxWidth': 640,
      });
      return [for (final f in out ?? const []) f.toString()];
    } catch (e) {
      debugPrint('[index] frames: $e');
      return const [];
    }
  }

  // ───────────── document text ─────────────

  /// null = we don't know how to read this type (yet).
  Future<String?> _docText(LibraryItem item) async {
    final ext = item.ext;
    final file = File(item.path);
    try {
      switch (ext) {
        case 'txt':
        case 'md':
        case 'csv':
        case 'json':
          return _clip(await file.readAsString());
        case 'pdf':
          return await _pdfPagesText(item, file);
        case 'docx':
          return _clip(await compute(_ooxmlText, _OoxmlJob(await file.readAsBytes(), ['word/document.xml'])));
        case 'pptx':
          return _clip(await compute(_ooxmlText, _OoxmlJob(await file.readAsBytes(), ['ppt/slides/'])));
        case 'xlsx':
          return _clip(await compute(_ooxmlText, _OoxmlJob(await file.readAsBytes(), ['xl/sharedStrings.xml', 'xl/worksheets/'])));
        default:
          return null;
      }
    } catch (e) {
      debugPrint('[index] doc text ($ext): $e');
      return '';
    }
  }

  static String _clip(String s) {
    final t = s.replaceAll(RegExp(r'[ \t]+'), ' ').replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
    return t.length > 200000 ? t.substring(0, 200000) : t;
  }

  // ───────────── PDF, page by page ─────────────

  /// A PDF, page by page. Pages that carry real text are read directly;
  /// pages that are only a picture (a scanned question paper, a photo saved
  /// as PDF) are drawn by Android and read with the same on-device OCR as
  /// photos. English and other Latin-script text only — ML Kit has no Tamil.
  Future<String> _pdfPagesText(LibraryItem item, File file) async {
    final pages = List<String>.of(await compute(_pdfPages, await file.readAsBytes()));
    if (Platform.isAndroid) {
      final scanned = <int>[
        for (var i = 0; i < pages.length; i++)
          if (looksScanned(pages[i])) i,
      ];
      if (scanned.isNotEmpty) {
        status.value = item.private ? 'Reading scanned pages…' : 'Reading the scanned pages of ${item.displayTitle}…';
        final read = await _ocrPdfPages(item, scanned.take(maxOcrPages).toList());
        for (final e in read.entries) {
          if (e.key >= 0 && e.key < pages.length) pages[e.key] = e.value;
        }
      }
    }
    return joinPages(pages);
  }

  /// Asks Android to draw pages of a PDF as pictures ([cover]: only the first
  /// page, small; otherwise the pages to read, large).
  ///
  /// Android's own PDF code can, on a rare broken file, take the whole app
  /// down with it — no catch stops that. So BYTE writes down which file it is
  /// about to draw and wipes the note when the drawing comes back. A note
  /// still there at the next start means that file crashed BYTE; after two
  /// such crashes it is not drawn again (its text is still read), so one bad
  /// PDF can never make BYTE crash at every start.
  Future<List<dynamic>?> _renderPdf(LibraryItem item, {required bool cover, required List<int> pages}) async {
    final prefs = await SharedPreferences.getInstance();
    final key = cover ? 'pdf_drawing_cover' : 'pdf_drawing_pages';
    final note = (prefs.getString(key) ?? '').split('|'); // "<item id>|<crashes so far>"
    final sameFile = note.length == 2 && note[0] == item.id;
    final crashes = sameFile ? int.tryParse(note[1]) ?? 0 : 0;
    if (crashes >= 2) {
      debugPrint('[index] pdf ${item.id}: drawing it crashed BYTE twice — skipped');
      return null;
    }
    await prefs.setString(key, '${item.id}|${crashes + 1}');
    try {
      return await _files.invokeMethod<List<dynamic>>('pdfRender', {
        'path': item.path,
        'outDir': (await LibraryRepo.instance.thumbsDir()).path,
        // "frame-…" files in the thumbs folder count as temporary (see storage_rules).
        'prefix': cover ? 'frame-pdfcover-${item.id}' : 'frame-pdf-${item.id}',
        'pages': pages,
        'maxWidth': cover ? 480 : 1500,
      });
    } finally {
      await prefs.remove(key); // it came back: this file does not crash BYTE
    }
  }

  /// Draws the given pages (0-based) as pictures and reads the words on them.
  Future<Map<int, String>> _ocrPdfPages(LibraryItem item, List<int> pageIndexes) async {
    final out = <int, String>{};
    if (pageIndexes.isEmpty) return out;
    final made = <String>[];
    TextRecognizer? recognizer;
    try {
      final rendered = await _renderPdf(item, cover: false, pages: pageIndexes);
      final jobs = <(int, String)>[];
      for (final r in rendered ?? const <dynamic>[]) {
        if (r is! Map) continue;
        final page = (r['page'] as num?)?.toInt();
        final path = '${r['path'] ?? ''}';
        if (page == null || path.isEmpty) continue;
        made.add(path);
        jobs.add((page, path));
      }
      if (jobs.isEmpty) return out;
      recognizer = TextRecognizer(script: TextRecognitionScript.latin);
      for (final (page, path) in jobs) {
        try {
          final t = (await recognizer.processImage(InputImage.fromFilePath(path))).text.trim();
          if (t.isNotEmpty) out[page] = t;
        } catch (e) {
          debugPrint('[index] pdf ocr p$page: $e');
        }
      }
    } catch (e) {
      debugPrint('[index] pdf pages: $e');
    } finally {
      await recognizer?.close();
      for (final path in made) {
        try {
          await File(path).delete();
        } catch (_) {}
      }
    }
    return out;
  }

  /// The first page of a PDF as its preview picture. '' when it can't be drawn
  /// (not Android, a locked PDF) — the row then keeps its PDF icon.
  Future<String> _pdfCover(LibraryItem item) async {
    if (!Platform.isAndroid) return '';
    try {
      final rendered = await _renderPdf(item, cover: true, pages: const [0]);
      if (rendered == null || rendered.isEmpty || rendered.first is! Map) return '';
      final tmp = '${(rendered.first as Map)['path'] ?? ''}';
      if (tmp.isEmpty) return '';
      final out = p.join((await LibraryRepo.instance.thumbsDir()).path, '${item.id}.jpg');
      await File(tmp).rename(out);
      return out;
    } catch (e) {
      debugPrint('[index] pdf cover: $e');
      return '';
    }
  }

  // ───────────── links ─────────────

  Future<_LinkMeta> _linkMeta(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return const _LinkMeta();
    final host = uri.host.toLowerCase();

    // YouTube (incl. Shorts): oEmbed gives title/author/thumbnail, no key needed.
    if (host.contains('youtube.com') || host == 'youtu.be') {
      try {
        final o = Uri.parse('https://www.youtube.com/oembed?format=json&url=${Uri.encodeComponent(url)}');
        final res = await http.get(o).timeout(const Duration(seconds: 12));
        if (res.statusCode == 200) {
          final j = jsonDecode(res.body) as Map<String, dynamic>;
          final title = (j['title'] ?? '').toString();
          final author = (j['author_name'] ?? '').toString();
          final thumbUrl = (j['thumbnail_url'] ?? '').toString();
          final thumb = await _downloadThumb(thumbUrl, url);
          return _LinkMeta(
            title: title,
            text: [title, author, 'youtube', if (url.contains('/shorts/')) 'shorts'].join('\n'),
            thumb: thumb,
          );
        }
      } catch (e) {
        debugPrint('[index] oembed: $e');
      }
    }

    try {
      final res = await http.get(uri, headers: {
        'User-Agent': 'Mozilla/5.0 (Linux; Android 14) BYTE/1.0',
        'Accept': 'text/html,*/*',
      }).timeout(const Duration(seconds: 12));
      if (res.statusCode != 200) return _LinkMeta(text: url);
      final html = res.body.length > 400000 ? res.body.substring(0, 400000) : res.body;
      String meta(String prop) {
        final m = RegExp('<meta[^>]+(?:property|name)=["\']$prop["\'][^>]*content=["\']([^"\']*)["\']', caseSensitive: false).firstMatch(html) ??
            RegExp('<meta[^>]+content=["\']([^"\']*)["\'][^>]*(?:property|name)=["\']$prop["\']', caseSensitive: false).firstMatch(html);
        return _unescape(m?.group(1) ?? '');
      }
      var title = meta('og:title');
      if (title.isEmpty) {
        final t = RegExp(r'<title[^>]*>([\s\S]*?)</title>', caseSensitive: false).firstMatch(html);
        title = _unescape(t?.group(1)?.trim() ?? '');
      }
      final desc = meta('og:description').isNotEmpty ? meta('og:description') : meta('description');
      final image = meta('og:image');
      final thumb = await _downloadThumb(image, url);
      return _LinkMeta(
        title: title,
        text: [title, desc, host].where((s) => s.isNotEmpty).join('\n'),
        thumb: thumb,
      );
    } catch (e) {
      debugPrint('[index] link: $e');
      return _LinkMeta(text: url);
    }
  }

  Future<String> _downloadThumb(String imageUrl, String pageUrl) async {
    if (imageUrl.isEmpty) return '';
    try {
      var u = Uri.parse(imageUrl);
      if (!u.hasScheme) u = Uri.parse(pageUrl).resolveUri(u);
      final res = await http.get(u).timeout(const Duration(seconds: 12));
      if (res.statusCode != 200 || res.bodyBytes.length > 3 * 1024 * 1024) return '';
      final ext = u.path.toLowerCase().endsWith('.png') ? '.png' : '.jpg';
      final out = File(p.join((await LibraryRepo.instance.thumbsDir()).path, 'link-${u.hashCode.abs()}$ext'));
      await out.writeAsBytes(res.bodyBytes, flush: true);
      return out.path;
    } catch (_) {
      return '';
    }
  }

  static String _unescape(String s) => s
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&#x27;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&nbsp;', ' ');
}

class _LinkMeta {
  const _LinkMeta({this.title = '', this.text = '', this.thumb = ''});
  final String title;
  final String text;
  final String thumb;
}

// ───────────── isolate workers (pure Dart) ─────────────

Uint8List _rgbaToJpg((Uint8List, int, int) job) {
  final (bytes, w, h) = job;
  final image = img.Image.fromBytes(width: w, height: h, bytes: bytes.buffer, order: img.ChannelOrder.rgba);
  return Uint8List.fromList(img.encodeJpg(image, quality: 80));
}

/// The text of every page of a PDF, one entry per page (a page that cannot
/// be read comes back empty and is tried with OCR by the caller).
List<String> _pdfPages(Uint8List bytes) {
  final doc = PdfDocument(inputBytes: bytes);
  try {
    final count = doc.pages.count;
    final take = count > LibraryIndexer.maxPdfPages ? LibraryIndexer.maxPdfPages : count;
    final extractor = PdfTextExtractor(doc);
    final out = <String>[];
    for (var i = 0; i < take; i++) {
      try {
        out.add(extractor.extractText(startPageIndex: i, endPageIndex: i));
      } catch (_) {
        out.add('');
      }
    }
    return out;
  } finally {
    doc.dispose();
  }
}

class _OoxmlJob {
  const _OoxmlJob(this.bytes, this.parts);
  final Uint8List bytes;
  final List<String> parts; // exact names or prefixes ending with '/'
}

/// Word / PowerPoint / Excel are ZIPs of XML: pull the text nodes out.
String _ooxmlText(_OoxmlJob job) {
  final archive = ZipDecoder().decodeBytes(job.bytes);
  final buf = StringBuffer();
  final files = archive.files.toList()..sort((a, b) => a.name.compareTo(b.name));
  for (final f in files) {
    final name = f.name;
    final wanted = job.parts.any((part) => part.endsWith('/') ? name.startsWith(part) : name == part);
    if (!wanted || !name.endsWith('.xml') || !f.isFile) continue;
    final xml = utf8.decode(f.content, allowMalformed: true);
    // Text nodes: <w:t>, <a:t>, <t> (shared strings), <v> (cell values).
    for (final m in RegExp(r'<(?:w:t|a:t|t|v)(?:\s[^>]*)?>([^<]*)</(?:w:t|a:t|t|v)>').allMatches(xml)) {
      final s = m.group(1)!.trim();
      if (s.isNotEmpty) buf.write('$s ');
    }
    // Paragraph / row boundaries → newlines.
    buf.write('\n');
  }
  return buf.toString()
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'");
}
