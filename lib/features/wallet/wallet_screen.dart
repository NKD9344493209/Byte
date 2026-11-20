import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/app_lock.dart';
import '../../core/bubble.dart';
import '../../core/drive_media.dart';
import '../../shared/theme.dart';
import '../../shared/ui.dart';
import '../library/library_item.dart';
import '../library/library_repo.dart';
import '../library/library_screen.dart' show LibraryThumb;
import '../library/library_viewer.dart';
import '../library/media_pager.dart';
import 'scan.dart';
import 'wallet.dart';

/// The document wallet: the papers that matter, quick to find, each with the
/// day it runs out. Opens behind the phone's own lock (when it has one).
class WalletScreen extends StatefulWidget {
  const WalletScreen({super.key});

  /// Asks for the phone's lock first, then opens the wallet.
  static Future<void> open(BuildContext context) async {
    final nav = Navigator.of(context);
    if (await AppLock.deviceLockSet()) {
      if (!await AppLock.biometric(reason: 'Open your document wallet')) return;
    }
    await nav.push(MaterialPageRoute<void>(builder: (_) => const WalletScreen()));
  }

  @override
  State<WalletScreen> createState() => _WalletScreenState();
}

class _WalletScreenState extends State<WalletScreen> {
  List<WalletDoc> _docs = const [];
  List<LibraryItem> _found = const [];
  bool _loaded = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    Wallet.changed.addListener(_load);
    LibraryRepo.instance.revision.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    Wallet.changed.removeListener(_load);
    LibraryRepo.instance.revision.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final docs = await Wallet.list();
    final found = await Wallet.suggestions();
    if (!mounted) return;
    setState(() {
      _docs = docs;
      _found = found;
      _loaded = true;
    });
  }

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _open(LibraryItem it) async {
    if (MediaPager.isMedia(it)) {
      await MediaPager.open(context, it, around: [for (final d in _docs) d.item]);
    } else {
      await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => LibraryViewer(itemId: it.id)));
    }
  }

  /// The day a paper runs out. BYTE reminds a month, a week and a day before.
  Future<void> _setDate(WalletDoc d) async {
    final now = DateTime.now();
    final first = DateTime(now.year - 1);
    var start = d.expiresAt ?? DateTime(now.year + 1, now.month, now.day);
    if (start.isBefore(first)) start = first;
    final day = await showDatePicker(
      context: context,
      initialDate: start,
      firstDate: first,
      lastDate: DateTime(now.year + 40),
      helpText: 'Valid until',
    );
    if (day == null) return;
    await Wallet.setExpiry(d.item.id, day);
    // Android 13 and later: reminders need "show notifications" allowed.
    final allowed = await Bubble.askNotifications();
    if (!mounted) return;
    _snack(allowed ? 'BYTE will remind you a month, a week and a day before.' : 'Saved. Allow notifications for BYTE to be reminded before it runs out.');
  }

  Future<void> _rename(WalletDoc d) async {
    final ctl = TextEditingController(text: d.name);
    final v = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Name in the wallet'),
        content: TextField(controller: ctl, autofocus: true, textCapitalization: TextCapitalization.words, decoration: const InputDecoration(hintText: 'Driving licence, Passport, Insurance…')),
        actions: [
          TextButton(style: inlineButton, onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(style: inlineButton, onPressed: () => Navigator.pop(ctx, ctl.text), child: const Text('Save')),
        ],
      ),
    );
    Future<void>.delayed(const Duration(seconds: 1), ctl.dispose);
    if (v == null) return;
    await Wallet.setLabel(d.item.id, v);
  }

  Future<void> _share(WalletDoc d) async {
    final it = d.item;
    if (!it.hasFile) return;
    final path = File(it.path).existsSync() ? it.path : await DriveMedia.ensureLocal(it);
    if (path == null) {
      if (mounted) _snack('This file is in Google Drive. Turn on the internet to send it.');
      return;
    }
    await SharePlus.instance.share(ShareParams(files: [XFile(path)], text: d.name));
  }

  Future<void> _menu(WalletDoc d) async {
    final v = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(leading: const Icon(Icons.event_outlined), title: Text(d.expiresAt == null ? 'Set the day it runs out' : 'Change the day it runs out'), onTap: () => Navigator.pop(ctx, 'date')),
            if (d.expiresAt != null) ListTile(leading: const Icon(Icons.event_busy_outlined), title: const Text('It does not run out'), onTap: () => Navigator.pop(ctx, 'nodate')),
            ListTile(leading: const Icon(Icons.edit_outlined), title: const Text('Name'), onTap: () => Navigator.pop(ctx, 'name')),
            if (d.item.hasFile) ListTile(leading: const Icon(Icons.send_outlined), title: const Text('Send a copy'), onTap: () => Navigator.pop(ctx, 'share')),
            ListTile(
              leading: const Icon(Icons.remove_circle_outline),
              title: const Text('Take out of the wallet'),
              subtitle: const Text('It stays in your Library'),
              onTap: () => Navigator.pop(ctx, 'remove'),
            ),
          ],
        ),
      ),
    );
    if (v == null || !mounted) return;
    switch (v) {
      case 'date':
        await _setDate(d);
      case 'nodate':
        await Wallet.setExpiry(d.item.id, null);
      case 'name':
        await _rename(d);
      case 'share':
        await _share(d);
      case 'remove':
        await Wallet.remove(d.item.id);
    }
  }

  Future<void> _add() async {
    final v = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(Icons.document_scanner_outlined, color: ByteColors.accentDim),
              title: const Text('Scan a paper'),
              subtitle: const Text('A photo of each page, saved as one clear PDF'),
              onTap: () => Navigator.pop(ctx, 'scan'),
            ),
            ListTile(
              leading: Icon(Icons.photo_library_outlined, color: ByteColors.accentDim),
              title: const Text('Choose a photo'),
              onTap: () => Navigator.pop(ctx, 'photo'),
            ),
            ListTile(
              leading: Icon(Icons.insert_drive_file_outlined, color: ByteColors.accentDim),
              title: const Text('Choose a file'),
              subtitle: const Text('PDF or anything else'),
              onTap: () => Navigator.pop(ctx, 'file'),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(ByteSpace.page, 4, ByteSpace.page, 12),
              child: Text('Something already in BYTE: open it, tap the green button (or the ⋮ menu) and choose "Add to the document wallet".'),
            ),
          ],
        ),
      ),
    );
    if (v == null || !mounted) return;
    setState(() => _busy = true);
    try {
      LibraryItem? it;
      switch (v) {
        case 'scan':
          it = await PaperScan.start(context);
        case 'photo':
          final f = await ImagePicker().pickImage(source: ImageSource.gallery);
          if (f != null) it = await LibraryRepo.instance.importFile(f.path, displayName: f.name);
        case 'file':
          final files = await FilePicker.pickFiles();
          for (final f in files) {
            if (f.path != null) it = await LibraryRepo.instance.importFile(f.path!, displayName: f.name);
          }
      }
      if (it != null) await Wallet.add(it.id);
    } catch (e) {
      if (mounted) _snack('Could not add it: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Color _tone(WalletDoc d) {
    final left = daysLeft(d.expiresAt);
    if (left == null) return ByteColors.textDim;
    if (left < 0) return ByteColors.danger;
    if (left <= 30) return ByteColors.heyInk;
    return ByteColors.textDim;
  }

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final fabFg = Theme.of(context).floatingActionButtonTheme.foregroundColor;
    return Scaffold(
      appBar: AppBar(title: const Text('Document wallet')),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'wallet-fab',
        onPressed: _busy ? null : _add,
        icon: _busy ? SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: fabFg)) : const Icon(Icons.add_rounded),
        label: const Text('Add a paper'),
      ),
      body: !_loaded
          ? const SizedBox.shrink()
          : ListView(
              padding: const EdgeInsets.only(bottom: 96),
              children: [
                if (_docs.isEmpty)
                  const EmptyNote('Keep the papers that matter here: Aadhaar, PAN, licence, passport, insurance, certificates. Give each the day it runs out and BYTE reminds you a month, a week and a day before.'),
                for (final d in _docs)
                  ByteRow(
                    title: d.name,
                    subtitle: validityText(d.expiresAt),
                    titleWeight: FontWeight.w600,
                    onTap: () => _open(d.item),
                    onLongPress: () => _menu(d),
                    leading: SizedBox(
                      width: 56,
                      height: 56,
                      child: ClipRRect(borderRadius: BorderRadius.circular(ByteSpace.rs), child: LibraryThumb(item: d.item, fit: BoxFit.cover)),
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (d.expiresAt != null) Icon(Icons.circle, size: 10, color: _tone(d)),
                        IconButton(tooltip: 'More', icon: const Icon(Icons.more_vert_rounded), onPressed: () => _menu(d)),
                      ],
                    ),
                  ),
                if (_found.isNotEmpty) ...[
                  const SectionLabel('BYTE found these ID cards. Put them in the wallet?'),
                  SizedBox(
                    height: 132,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: ByteSpace.page),
                      itemCount: _found.length,
                      separatorBuilder: (_, _) => const SizedBox(width: 10),
                      itemBuilder: (_, i) {
                        final it = _found[i];
                        return SizedBox(
                          width: 96,
                          child: Column(
                            children: [
                              GestureDetector(
                                onTap: () => _open(it),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(12),
                                  child: SizedBox(width: 96, height: 84, child: LibraryThumb(item: it, fit: BoxFit.cover)),
                                ),
                              ),
                              TextButton(style: inlineButton, onPressed: () => Wallet.add(it.id), child: const Text('Add')),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(ByteSpace.page, 0, ByteSpace.page, 0),
                    child: Text('BYTE can be wrong about what is an ID card. Nothing is added until you tap Add.', style: tt.bodySmall?.copyWith(color: ByteColors.textFaint)),
                  ),
                ],
              ],
            ),
    );
  }
}
