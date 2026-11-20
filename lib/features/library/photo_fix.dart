import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import '../../shared/theme.dart';
import 'library_item.dart';
import 'library_repo.dart';

/// Quick fixes BYTE can do itself: brighter / darker / clearer (contrast +
/// a touch of sharpening) / auto. The original is never touched — a fixed
/// copy is saved as a new Library item.
class PhotoFixParams {
  const PhotoFixParams({this.brightness = 0, this.contrast = 0, this.sharpen = false, this.auto = false});

  /// -60 … +60 (percent-ish).
  final int brightness;

  /// -40 … +40.
  final int contrast;
  final bool sharpen;
  final bool auto;

  static PhotoFixParams preset(String name) => switch (name) {
        'brighter' => const PhotoFixParams(brightness: 25, contrast: 8),
        'darker' => const PhotoFixParams(brightness: -20),
        'contrast' => const PhotoFixParams(contrast: 20, sharpen: true),
        'auto' => const PhotoFixParams(auto: true, sharpen: true),
        _ => const PhotoFixParams(),
      };

  bool get isIdentity => brightness == 0 && contrast == 0 && !sharpen && !auto;

  PhotoFixParams copyWith({int? brightness, int? contrast, bool? sharpen, bool? auto}) => PhotoFixParams(
        brightness: brightness ?? this.brightness,
        contrast: contrast ?? this.contrast,
        sharpen: sharpen ?? this.sharpen,
        auto: auto ?? this.auto,
      );

  @override
  bool operator ==(Object other) =>
      other is PhotoFixParams && other.brightness == brightness && other.contrast == contrast && other.sharpen == sharpen && other.auto == auto;

  @override
  int get hashCode => Object.hash(brightness, contrast, sharpen, auto);

  Map<String, Object> toMap() => {'b': brightness, 'c': contrast, 's': sharpen, 'a': auto};
  static PhotoFixParams fromMap(Map m) => PhotoFixParams(brightness: m['b'] as int, contrast: m['c'] as int, sharpen: m['s'] as bool, auto: m['a'] as bool);
}

/// Pure image maths — runs in an isolate via [compute].
Uint8List applyPhotoFix(Map<String, Object?> job) {
  final bytes = job['bytes'] as Uint8List;
  final params = PhotoFixParams.fromMap(job['params'] as Map);
  final maxW = job['maxW'] as int? ?? 0;
  var image = img.decodeImage(bytes);
  if (image == null) return bytes;
  image = img.bakeOrientation(image);
  if (maxW > 0 && image.width > maxW) {
    image = img.copyResize(image, width: maxW);
  }
  if (params.auto) {
    image = img.normalize(image, min: 0, max: 255);
  }
  if (params.brightness != 0 || params.contrast != 0) {
    image = img.adjustColor(
      image,
      brightness: 1 + params.brightness / 100,
      contrast: 1 + params.contrast / 100,
    );
  }
  if (params.sharpen) {
    image = img.convolution(image, filter: [0, -1, 0, -1, 5, -1, 0, -1, 0], div: 1);
  }
  return Uint8List.fromList(img.encodeJpg(image, quality: 92));
}

/// Bottom sheet with live preview; "Keep" saves a copy into the Library.
class PhotoFixSheet extends StatefulWidget {
  const PhotoFixSheet({super.key, required this.item, this.preset = 'brighter'});
  final LibraryItem item;
  final String preset;

  static Future<LibraryItem?> show(BuildContext context, LibraryItem item, {String preset = 'brighter'}) =>
      showModalBottomSheet<LibraryItem>(
        context: context,
        isScrollControlled: true,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
        builder: (_) => PhotoFixSheet(item: item, preset: preset),
      );

  @override
  State<PhotoFixSheet> createState() => _PhotoFixSheetState();
}

class _PhotoFixSheetState extends State<PhotoFixSheet> {
  late PhotoFixParams _p = PhotoFixParams.preset(widget.preset);
  Uint8List? _original;
  Uint8List? _preview;
  bool _busy = false;
  bool _saving = false;
  int _job = 0;

  @override
  void initState() {
    super.initState();
    _loadOriginal();
  }

  Future<void> _loadOriginal() async {
    try {
      final bytes = await File(widget.item.path).readAsBytes();
      // A small working copy for the live preview; the full image is used on Keep.
      final small = await compute(applyPhotoFix, {'bytes': bytes, 'params': const PhotoFixParams().toMap(), 'maxW': 900});
      if (!mounted) return;
      setState(() => _original = small);
      _render();
    } catch (e) {
      if (mounted) setState(() => _original = null);
    }
  }

  Future<void> _render() async {
    final src = _original;
    if (src == null) return;
    final id = ++_job;
    setState(() => _busy = true);
    try {
      final out = await compute(applyPhotoFix, {'bytes': src, 'params': _p.toMap(), 'maxW': 0});
      if (!mounted || id != _job) return;
      setState(() {
        _preview = out;
        _busy = false;
      });
    } catch (_) {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _set(PhotoFixParams p) {
    setState(() => _p = p);
    _render();
  }

  Future<void> _keep() async {
    setState(() => _saving = true);
    try {
      final bytes = await File(widget.item.path).readAsBytes();
      final out = await compute(applyPhotoFix, {'bytes': bytes, 'params': _p.toMap(), 'maxW': 0});
      final dir = await LibraryRepo.instance.filesDir();
      final tmp = File(p.join(dir.path, 'fix-${DateTime.now().millisecondsSinceEpoch}.jpg'));
      await tmp.writeAsBytes(out);
      final saved = await LibraryRepo.instance.importFile(
        tmp.path,
        displayName: '${widget.item.displayTitle} (fixed).jpg',
        source: 'photofix',
        move: true,
      );
      if (!mounted) return;
      Navigator.of(context).pop(saved);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Couldn\'t save: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final preview = _preview ?? _original;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(child: Text('Fix photo', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700))),
                if (_busy) SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: ByteColors.accent)),
              ],
            ),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: AspectRatio(
                aspectRatio: 4 / 3,
                child: preview == null
                    ? Container(color: ByteColors.surface2, alignment: Alignment.center, child: const CircularProgressIndicator())
                    : Image.memory(preview, fit: BoxFit.contain, gaplessPlayback: true),
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              children: [
                for (final (k, label) in const [('brighter', 'Brighter'), ('darker', 'Darker'), ('contrast', 'Clearer'), ('auto', 'Auto')])
                  ChoiceChip(
                    label: Text(label),
                    selected: _p == PhotoFixParams.preset(k),
                    showCheckmark: false,
                    onSelected: (_) => _set(PhotoFixParams.preset(k)),
                  ),
              ],
            ),
            _slider('Brightness', _p.brightness.toDouble(), -60, 60, (v) => _set(_p.copyWith(brightness: v.round(), auto: false))),
            _slider('Contrast', _p.contrast.toDouble(), -40, 40, (v) => _set(_p.copyWith(contrast: v.round(), auto: false))),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('Sharpen'),
              value: _p.sharpen,
              onChanged: (v) => _set(_p.copyWith(sharpen: v)),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
                const Spacer(),
                FilledButton.icon(
                  style: FilledButton.styleFrom(minimumSize: const Size(140, 46)),
                  onPressed: _saving || _original == null || _p.isIdentity ? null : _keep,
                  icon: _saving
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.check_rounded),
                  label: const Text('Keep a copy'),
                ),
              ],
            ),
            Text('The original stays as it is.', style: TextStyle(fontSize: 11, color: ByteColors.textDim)),
          ],
        ),
      ),
    );
  }

  Widget _slider(String label, double v, double min, double max, ValueChanged<double> onChanged) {
    return Row(
      children: [
        SizedBox(width: 84, child: Text(label, style: TextStyle(fontSize: 13, color: ByteColors.textDim))),
        Expanded(
          child: Slider(
            value: v.clamp(min, max),
            min: min,
            max: max,
            divisions: ((max - min) / 5).round(),
            label: '${v.round()}',
            activeColor: ByteColors.accent,
            onChanged: onChanged,
          ),
        ),
      ],
    );
  }
}
