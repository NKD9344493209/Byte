import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

import '../../shared/theme.dart';
import '../library/library_item.dart';
import '../library/library_repo.dart';
import '../library/photo_fix.dart';

/// Scan a paper: take a photo of each page; BYTE makes the pages clearer
/// (even light, stronger letters) and saves them as ONE PDF in the Library,
/// where its words are read like any other document.
///
/// It does not cut the paper out of the photo or straighten it — hold the
/// phone flat over the page and fill the picture with it.
class PaperScan {
  PaperScan._();

  /// Runs the whole flow. Returns the new Library item, or null when you
  /// stopped before the first page.
  static Future<LibraryItem?> start(BuildContext context) async {
    final pages = <Uint8List>[];
    final picker = ImagePicker();
    // (25 pages at most in one scan: more would be too much for the phone's memory.)
    while (pages.length < 25) {
      XFile? shot;
      try {
        shot = await picker.pickImage(source: ImageSource.camera, imageQuality: 92, maxWidth: 2600);
      } catch (e) {
        debugPrint('[scan] camera: $e');
      }
      if (shot == null) break;
      final raw = await shot.readAsBytes();
      // Even light, stronger letters, 1800 px wide (sharp on paper, small as a file).
      pages.add(await compute(applyPhotoFix, {'bytes': raw, 'params': const PhotoFixParams(auto: true, contrast: 14, sharpen: true).toMap(), 'maxW': 1800}));
      try {
        await File(shot.path).delete();
      } catch (_) {}
      if (!context.mounted) break;
      final more = await showModalBottomSheet<bool>(
        context: context,
        isDismissible: false,
        builder: (ctx) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(ByteSpace.page, 4, ByteSpace.page, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(pages.length == 1 ? '1 page scanned' : '${pages.length} pages scanned (25 at most)', style: Theme.of(ctx).textTheme.titleLarge),
                const SizedBox(height: 12),
                FilledButton.icon(onPressed: () => Navigator.pop(ctx, true), icon: const Icon(Icons.add_a_photo_outlined), label: const Text('Scan another page')),
                const SizedBox(height: 8),
                OutlinedButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Done — save as one PDF')),
              ],
            ),
          ),
        ),
      );
      if (more != true) break;
    }
    if (pages.isEmpty) return null;
    final bytes = await compute(_pdfOf, pages);
    final n = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final name = 'Scan ${n.year}-${two(n.month)}-${two(n.day)} ${two(n.hour)}.${two(n.minute)}.pdf';
    final tmp = File(p.join((await getTemporaryDirectory()).path, name));
    await tmp.writeAsBytes(bytes, flush: true);
    return LibraryRepo.instance.importFile(tmp.path, displayName: name, source: 'scan', move: true);
  }
}

/// The pages (JPEG bytes) as one PDF: A4 sheets, each picture as large as it
/// fits. Runs off the main thread.
Future<Uint8List> _pdfOf(List<Uint8List> pages) async {
  final doc = PdfDocument();
  doc.pageSettings.margins.all = 0;
  for (final jpg in pages) {
    final image = PdfBitmap(jpg);
    final page = doc.pages.add();
    final size = page.getClientSize();
    final scale = math.min(size.width / image.width, size.height / image.height);
    final w = image.width * scale;
    final h = image.height * scale;
    page.graphics.drawImage(image, Rect.fromLTWH((size.width - w) / 2, (size.height - h) / 2, w, h));
  }
  final out = await doc.save();
  doc.dispose();
  return Uint8List.fromList(out);
}
