import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/private_space.dart';
import '../../core/slim.dart';
import '../../core/storage_audit.dart';
import '../../core/storage_info.dart';
import '../../shared/motion.dart';
import '../../shared/theme.dart';
import '../../shared/ui.dart';
import '../capture/audio_compress.dart';
import '../capture/audio_repo.dart';
import '../library/library_repo.dart';
import '../library/library_viewer.dart';
import 'drive_space_card.dart';

typedef _Owner = ({String id, String title, String kind, bool isThumb});

/// Settings → Storage: every byte inside BYTE's private folder, sorted into
/// buckets with real numbers, the 15 biggest files, and the buttons that
/// free space (shrink recordings/photos, clean up, delete one file).
/// "Copy report" puts the whole breakdown on the clipboard.
class StorageScreen extends StatefulWidget {
  const StorageScreen({super.key});

  @override
  State<StorageScreen> createState() => _StorageScreenState();
}

class _StorageScreenState extends State<StorageScreen> {
  AuditReport? _audit;
  ({int count, int bytes})? _recPending;
  ({int count, int bytes})? _photoPending;
  ({int done, int total, int saved, DateTime? at}) _shrunk = (done: 0, total: 0, saved: 0, at: null);
  CleanResult? _lastClean;
  final Map<String, _Owner?> _owners = {};
  Set<String> _hidden = const {};
  bool _auto = true;
  bool _working = false;
  String _status = '';

  @override
  void initState() {
    super.initState();
    AudioCompressor.status.addListener(_onAacStatus);
    AudioCompressor.progress.addListener(_onAacProgress);
    _load();
  }

  @override
  void dispose() {
    AudioCompressor.status.removeListener(_onAacStatus);
    AudioCompressor.progress.removeListener(_onAacProgress);
    super.dispose();
  }

  void _onAacStatus() {
    if (!mounted) return;
    final s = AudioCompressor.status.value;
    if (AudioCompressor.busy) setState(() => _status = s);
    // The final message is set just before the run ends; re-measure after it has.
    Future<void>.microtask(() {
      if (mounted && !AudioCompressor.busy && !_working) _load(force: true);
    });
  }

  void _onAacProgress() {
    if (!mounted) return;
    final p = AudioCompressor.progress.value;
    setState(() => _shrunk = (done: p.done, total: p.total, saved: p.saved, at: DateTime.now()));
  }

  Future<void> _load({bool force = false}) async {
    final audit = await StorageAudit.run(force: force);
    final rp = await AudioCompressor.pending();
    final pp = await PhotoSlim.pending();
    final auto = await AudioCompressor.autoEnabled();
    final shrunk = await AudioCompressor.savedProgress();
    final clean = await StorageCleaner.last();
    // Files of the private space are not named here (nor opened, nor deleted).
    final hidden = {for (final path in await PrivateSpace.filePaths()) normPath(path)};
    final owners = <String, _Owner?>{};
    for (final f in audit.biggest) {
      try {
        owners[f.path] = await StorageAudit.itemFor(f.path);
      } catch (_) {
        owners[f.path] = null;
      }
    }
    if (!mounted) return;
    setState(() {
      _audit = audit;
      _recPending = rp;
      _photoPending = pp;
      _auto = auto;
      if (!AudioCompressor.busy) _shrunk = shrunk;
      _lastClean = clean;
      _hidden = hidden;
      _owners
        ..clear()
        ..addAll(owners);
    });
  }

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _run(Future<String> Function(void Function(String)) job) async {
    if (_working) return;
    setState(() => _working = true);
    try {
      final msg = await job((s) {
        if (mounted) setState(() => _status = s);
      });
      if (mounted) _snack(msg);
    } catch (e) {
      if (mounted) _snack('$e');
    } finally {
      if (mounted) {
        setState(() {
          _working = false;
          _status = '';
        });
        await _load(force: true);
      }
    }
  }

  Future<void> _shrinkRecordings() => _run((say) async {
        final r = await AudioCompressor.compressAll(onStatus: say);
        return r.count == 0 ? 'Nothing to shrink.' : 'Shrunk ${r.count} recording${r.count == 1 ? '' : 's'} — saved ${fmtBytes(r.saved)}.';
      });

  Future<void> _cleanUp() => _run((say) async {
        final r = await StorageCleaner.run(onStatus: say);
        final thumbs = r.thumbsSlimmed > 0 ? ' Re-saved ${r.thumbsSlimmed} thumbnail${r.thumbsSlimmed == 1 ? '' : 's'} smaller.' : '';
        return r.files == 0 && r.thumbsSlimmed == 0 ? 'Nothing to clean — all good.' : 'Freed ${fmtBytes(r.bytes)} (${r.files} file${r.files == 1 ? '' : 's'}).$thumbs';
      });

  Future<void> _copyReport() async {
    final a = _audit;
    if (a == null) return;
    final shrunk = _shrunk.total > 0 ? 'Shrunk ${_shrunk.done} of ${_shrunk.total} recordings, saved ${fmtBytes(_shrunk.saved)}. ' : '';
    final clean = _lastClean == null ? 'Clean-up never ran.' : 'Last clean-up ${_ago(_lastClean!.at)}: freed ${fmtBytes(_lastClean!.bytes)} (${_lastClean!.files} files).';
    final text = '${a.reportText(appNote: 'the app itself, ~100–130 MB, is on top of this')}\n$shrunk$clean\n';
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) _snack('Report copied — paste it to Claude.');
  }

  Future<void> _shrinkPhotos() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Shrink photos?'),
        content: const Text('Photos bigger than 1.2 MB are re-saved at 2048 px (JPEG). They look the same on the phone and in Drive, but the original full-size file is replaced. Cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(style: inlineButton, onPressed: () => Navigator.pop(ctx, true), child: const Text('Shrink')),
        ],
      ),
    );
    if (ok != true) return;
    await _run((say) async {
      final r = await PhotoSlim.shrinkAll(onStatus: say);
      return r.count == 0 ? 'Nothing to shrink.' : 'Shrunk ${r.count} photo${r.count == 1 ? '' : 's'} — saved ${fmtBytes(r.saved)}.';
    });
  }

  Future<void> _deleteBig(AuditFile f) async {
    if (f.cat == StorageCat.db || f.cat == StorageCat.model || f.cat == StorageCat.other) {
      _snack('BYTE needs this file — it can\'t be deleted from here.');
      return;
    }
    final o = _owners[f.path];
    final owner = o != null && !o.isThumb ? o : null; // the vault row this file belongs to (thumbs don't count)
    final what = owner != null ? (owner.title.isEmpty ? '(${owner.kind})' : owner.title) : f.name;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete "$what"?'),
        content: Text(
          '${fmtBytes(f.size)} is freed right now.${owner != null ? ' The ${owner.kind == 'audio' ? 'voice note' : 'item'} is deleted for good — it does not go to the bin, because its file is removed now. If it is in Google Drive, that copy moves to Drive\'s own Trash.' : ''}'
          '${f.cat == StorageCat.backup || f.cat == StorageCat.cache || f.cat == StorageCat.picker || f.cat == StorageCat.temp ? ' This is a leftover copy — nothing in BYTE points to it.' : ''}',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(style: inlineButton.copyWith(backgroundColor: WidgetStatePropertyAll(ByteColors.danger)), onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    final freed = await StorageAudit.removeFile(f.path);
    if (owner != null && freed > 0) {
      // The file is gone, so the bin could not bring it back: remove the item for good.
      await LibraryRepo.instance.deleteForever(owner.id);
      if (owner.kind == 'audio') AudioRepo.instance.revision.value++;
    }
    if (mounted) _snack(freed > 0 ? 'Freed ${fmtBytes(freed)}' : 'Could not delete that file.');
    await _load(force: true);
  }

  static String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes} min ago';
    if (d.inHours < 24) return '${d.inHours} h ago';
    return '${d.inDays} day${d.inDays == 1 ? '' : 's'} ago';
  }

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final a = _audit;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Drive & storage'),
        actions: [IconButton(tooltip: 'Measure again', icon: const Icon(Icons.refresh_rounded), onPressed: _working ? null : () => _load(force: true))],
      ),
      body: a == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.only(bottom: 32),
              children: [
                // ── Google Drive: where photos and videos live ──
                const DriveSpaceCard(),

                // ── what takes space: the bars are a thing, so a well ──
                Padding(
                  padding: const EdgeInsets.fromLTRB(ByteSpace.page, 8, ByteSpace.page, 0),
                  child: Container(
                    width: double.infinity,
                    decoration: BoxDecoration(color: ByteColors.surface2, borderRadius: BorderRadius.circular(ByteSpace.rm)),
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('BYTE\'s data: ${fmtBytes(a.total)}', style: tt.titleLarge),
                        Text('Measured ${_ago(a.at)} · ${a.biggest.isEmpty ? 'nothing stored yet' : 'every file inside the app folder'}', style: tt.bodySmall),
                        const SizedBox(height: 10),
                        for (final c in a.ranked) _row(c.label, a.of(c), a.countOf(c), a.total),
                        const SizedBox(height: 10),
                        Text(
                          'Android\'s "App size" adds the app itself on top (~100–130 MB: Flutter, the on-device text reader and the speech engine). The part that grows is this data — mostly recordings and videos.',
                          style: tt.bodySmall,
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton.icon(onPressed: _copyReport, icon: const Icon(Icons.copy_rounded, size: 18), label: const Text('Copy report')),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: FilledButton.icon(onPressed: _working ? null : _cleanUp, icon: const Icon(Icons.cleaning_services_rounded, size: 18), label: const Text('Clean up now')),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                if (_working || AudioCompressor.busy)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(ByteSpace.page, 12, ByteSpace.page, 0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ClipRRect(borderRadius: BorderRadius.circular(3), child: const LinearProgressIndicator(minHeight: 6)),
                        const SizedBox(height: 6),
                        Text(_status, style: tt.bodySmall),
                      ],
                    ),
                  ),

                const SectionLabel('Recordings'),
                ByteList(
                  children: [
                    ByteRow(
                      icon: Icons.autorenew_rounded,
                      title: 'Shrink recordings automatically',
                      subtitle: _shrunk.total > 0
                          ? 'Shrunk ${_shrunk.done} of ${_shrunk.total} recordings${_shrunk.saved > 0 ? ', saved ${fmtBytes(_shrunk.saved)}' : ''}${_shrunk.at == null ? '' : ' · ${_ago(_shrunk.at!)}'}'
                          : 'WAV → AAC (8× smaller, same clarity) soon after each recording is saved',
                      trailing: ByteSwitch(
                        value: _auto,
                        onChanged: (v) async {
                          await AudioCompressor.setAuto(v);
                          if (mounted) setState(() => _auto = v);
                        },
                      ),
                    ),
                    ByteRow(
                      icon: Icons.compress_rounded,
                      tone: 'act',
                      title: 'Shrink all recordings now',
                      subtitle: _recPending == null || _recPending!.count == 0 ? 'All recordings are already small' : '${_recPending!.count} still in WAV (${fmtBytes(a.of(StorageCat.wav))}) — would save about ${fmtBytes(_recPending!.bytes)}',
                      trailing: FilledButton.tonal(style: inlineButton, onPressed: _working || AudioCompressor.busy || (_recPending?.count ?? 0) == 0 ? null : _shrinkRecordings, child: const Text('Shrink')),
                    ),
                  ],
                ),

                const SectionLabel('Clean-up'),
                ByteList(
                  children: [
                    ByteRow(
                      icon: Icons.cleaning_services_outlined,
                      tone: 'act',
                      title: _lastClean == null ? 'Clean-up has not run yet' : 'Last clean-up ${_ago(_lastClean!.at)}: freed ${fmtBytes(_lastClean!.bytes)}',
                      subtitle: _lastClean != null && _lastClean!.files > 0
                          ? '${_lastClean!.files} file${_lastClean!.files == 1 ? '' : 's'} removed last time. Runs by itself at launch and every few hours.'
                          : 'Runs by itself at launch and every few hours: cache leftovers, half-finished downloads, old backup ZIPs, files nothing points to, PNG thumbnails re-saved as JPEG',
                    ),
                  ],
                ),

                const SectionLabel('Photos'),
                ByteList(
                  children: [
                    ByteRow(
                      icon: Icons.photo_size_select_large_rounded,
                      tone: 'act',
                      title: 'Shrink big photos',
                      subtitle: _photoPending == null || _photoPending!.count == 0 ? 'No photos over 1.2 MB' : '${_photoPending!.count} large photo${_photoPending!.count == 1 ? '' : 's'} — would save about ${fmtBytes(_photoPending!.bytes)} (re-saved at 2048 px)',
                      trailing: FilledButton.tonal(style: inlineButton, onPressed: _working || (_photoPending?.count ?? 0) == 0 ? null : _shrinkPhotos, child: const Text('Shrink')),
                    ),
                  ],
                ),

                const SectionLabel('Cache'),
                ByteList(
                  children: [
                    ByteRow(
                      icon: Icons.delete_sweep_outlined,
                      title: 'Clear cache',
                      subtitle: '${fmtBytes(a.of(StorageCat.cache) + a.of(StorageCat.picker) + a.of(StorageCat.temp))} of temporary files and picker copies (safe — rebuilt when needed)',
                      trailing: TextButton(
                        style: inlineButton,
                        onPressed: _working
                            ? null
                            : () async {
                                final freed = await StorageInfo.clearCache();
                                if (mounted) _snack('Cleared ${fmtBytes(freed)}');
                                await _load(force: true);
                              },
                        child: const Text('Clear'),
                      ),
                    ),
                  ],
                ),

                const SectionLabel('Biggest files'),
                if (a.biggest.isEmpty)
                  const EmptyNote('Nothing yet.')
                else
                  ByteList(
                    children: [
                      for (final f in a.biggest)
                        if (!_hidden.contains(f.path)) _bigRow(f),
                    ],
                  ),
              ],
            ),
    );
  }

  Widget _bigRow(AuditFile f) {
    final owner = _owners[f.path];
    final title = owner == null || owner.isThumb || owner.title.isEmpty ? f.name : owner.title;
    final when = f.modified.toIso8601String().substring(0, 10);
    final openId = owner != null && !owner.isThumb && owner.kind != 'audio' ? owner.id : null;
    return ByteRow(
      icon: switch (f.cat) {
        StorageCat.wav || StorageCat.aac => Icons.mic_none_rounded,
        StorageCat.video => Icons.videocam_outlined,
        StorageCat.photo => Icons.photo_outlined,
        StorageCat.thumbs => Icons.image_outlined,
        StorageCat.db => Icons.lock_outline_rounded,
        StorageCat.backup => Icons.archive_outlined,
        StorageCat.model => Icons.record_voice_over_outlined,
        StorageCat.picker || StorageCat.cache || StorageCat.temp => Icons.content_copy_rounded,
        _ => Icons.insert_drive_file_outlined,
      },
      title: title,
      subtitle: '${f.cat.short} · ${fmtBytes(f.size)} · $when',
      titleWeight: FontWeight.w600,
      trailing: IconButton(tooltip: 'Delete file', icon: Icon(Icons.delete_outline, color: ByteColors.danger), onPressed: _working ? null : () => _deleteBig(f)),
      onTap: openId == null ? null : () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => LibraryViewer(itemId: openId))),
    );
  }

  Widget _row(String label, int bytes, int count, int total) {
    final tt = Theme.of(context).textTheme;
    final frac = total == 0 ? 0.0 : bytes / total;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(label, style: tt.bodyMedium, maxLines: 1, overflow: TextOverflow.ellipsis)),
              const SizedBox(width: 8),
              Text('${fmtBytes(bytes)} · $count', style: tt.bodySmall?.copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
            ],
          ),
          const SizedBox(height: 3),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(value: frac, minHeight: 6, backgroundColor: ByteColors.border, color: ByteColors.accent),
          ),
        ],
      ),
    );
  }
}
