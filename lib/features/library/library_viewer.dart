import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

import '../../core/cloud_sync.dart';
import '../../core/drive_media.dart';
import '../../core/expiry.dart';
import '../../core/stars.dart';
import '../../shared/sticky.dart';
import '../../shared/motion.dart';
import '../../shared/theme.dart';
import '../../shared/ui.dart';
import '../capture/audio_repo.dart';
import '../capture/voice_note_screen.dart';
import '../notes/notes_repo.dart';
import '../private/private_gate.dart';
import '../wallet/wallet.dart';
import '../albums/albums.dart';
import '../albums/places.dart';
import '../../core/prefs.dart';
import '../capture/recorder_service.dart';
import '../voice/voice_bridge.dart';
import '../voice/voice_command.dart';
import 'library_item.dart';
import 'library_repo.dart';
import 'library_screen.dart' show LibraryThumb;
import 'media_pager.dart';
import '../search/search_text.dart';
import 'photo_fix.dart';
import 'collection_picker.dart';

/// One item, full screen: the thing itself on top, details below
/// (name, tags, what BYTE found inside it).
///
/// [embedded]: only the details, as the sheet that slides up over a photo
/// or video in [MediaPager] — the picture itself is behind it.
class LibraryViewer extends StatefulWidget {
  const LibraryViewer({super.key, required this.itemId, this.fixPreset, this.find = '', this.embedded = false, this.scroll});
  final String itemId;

  /// Shown inside the details sheet of the full-screen viewer.
  final bool embedded;

  /// The sheet's own scroll controller (so dragging the list drags the sheet).
  final ScrollController? scroll;

  /// Open the photo-fix sheet straight away with this preset.
  final String? fixPreset;

  /// Opened from Search with these words: the place they were found (and the
  /// page, for a document) is shown first, with the word marked.
  final String find;

  @override
  State<LibraryViewer> createState() => _LibraryViewerState();
}

class _LibraryViewerState extends State<LibraryViewer> {
  final _repo = LibraryRepo.instance;
  LibraryItem? _it;
  bool _pinned = false;
  DriveEntry? _drive;
  bool _bringing = false;

  /// The day this item moves to the bin by itself, if you gave it one.
  DateTime? _expires;

  /// It is one of the papers in the document wallet.
  bool _inWallet = false;

  /// The albums BYTE sorted it into, and the one you chose yourself ('' = none chosen).
  List<String> _places = const [];
  String _fixed = '';

  @override
  void initState() {
    super.initState();
    _repo.revision.addListener(_load);
    AudioRepo.instance.revision.addListener(_load); // the words of a voice note were fixed
    DriveMedia.changed.addListener(_loadDrive);
    Albums.changed.addListener(_load); // sorted (again): its albums may have changed
    _load();
  }

  @override
  void dispose() {
    _repo.revision.removeListener(_load);
    AudioRepo.instance.revision.removeListener(_load);
    DriveMedia.changed.removeListener(_loadDrive);
    Albums.changed.removeListener(_load);
    super.dispose();
  }

  Future<void> _loadDrive() async {
    final e = await DriveMedia.entry(widget.itemId);
    if (mounted) setState(() => _drive = e);
  }

  bool get _isMedia => _it?.kind == LibraryKind.photo || _it?.kind == LibraryKind.video;

  /// The full file on the phone, bringing it back from Drive when needed
  /// (Share, Open with, Fix photo). Shows a quiet "Getting it from Drive…".
  Future<String?> _local() async {
    final it = _it;
    if (it == null || !it.hasFile) return null;
    if (File(it.path).existsSync()) {
      // On the phone: mark it in use so it isn't freed while Share/Open/Fix has it.
      if (_isMedia) await DriveMedia.ensureLocal(it);
      return it.path;
    }
    setState(() => _bringing = true);
    final path = await DriveMedia.ensureLocal(it);
    if (!mounted) return path;
    setState(() => _bringing = false);
    if (path == null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(it.fromGallery ? 'This photo is not on the phone right now.' : 'This lives in Google Drive. Turn on the internet to open it.'),
      ));
    }
    return path;
  }

  Future<void> _load() async {
    final it = await _repo.get(widget.itemId);
    final pinned = await Stars.isStarred(widget.itemId);
    if (!mounted) return;
    if (it == null) {
      Navigator.of(context).maybePop();
      return;
    }
    final drive = await DriveMedia.entry(widget.itemId);
    final expires = await Expiry.of(widget.itemId);
    final inWallet = await Wallet.has(widget.itemId);
    final places = await _repo.placesOf(widget.itemId);
    final fixed = await _repo.fixedPlace(widget.itemId);
    if (!mounted) return;
    places.sort((a, b) => placeRank(a).compareTo(placeRank(b)));
    setState(() {
      _it = it;
      _pinned = pinned;
      _drive = drive;
      _expires = expires;
      _inWallet = inWallet;
      _places = places;
      _fixed = fixed;
    });
    if (!_fixOffered && widget.fixPreset != null && it.kind == LibraryKind.photo && it.hasFile) {
      _fixOffered = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _fix(widget.fixPreset!));
    }
  }

  bool _fixOffered = false;

  Future<void> _fix(String preset) async {
    final it = _it;
    if (it == null || it.kind != LibraryKind.photo || !it.hasFile) return;
    if (await _local() == null || !mounted) return;
    final saved = await PhotoFixSheet.show(context, it, preset: preset);
    if (saved == null || !mounted) return;
    ScaffoldMessenger.of(widget.embedded ? Navigator.of(context).context : context).showSnackBar(SnackBar(content: Text('Saved "${saved.displayTitle}" to Library')));
    // The fixed copy, full screen (it takes the place of this sheet or page).
    await Navigator.of(context).pushReplacement(widget.embedded ? MediaPager.route([saved]) : MaterialPageRoute<void>(builder: (_) => LibraryViewer(itemId: saved.id)));
  }

  Future<void> _togglePin() async {
    final now = !_pinned;
    await Stars.set(widget.itemId, now);
    if (!mounted) return;
    setState(() => _pinned = now);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(now ? 'Starred' : 'Star removed'),
    ));
  }

  Future<void> _rename() async {
    final it = _it!;
    final ctl = TextEditingController(text: it.title);
    final v = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Name'),
        // Type it, or tap the mic and say it ("save this as hostel fee receipt").
        content: TextField(
          controller: ctl,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(
            suffixIcon: IconButton(
              tooltip: 'Say the name',
              icon: const Icon(Icons.mic_none_rounded),
              onPressed: () async {
                if (!VoiceBridge.supported || !await RecorderService.instance.hasPermission()) return;
                final h = await VoiceBridge.listen(offline: false, locale: Prefs.voiceLocale, pauseMs: 1500, minMs: 2500);
                if (!h.ok || !ctx.mounted) return;
                final name = voiceName(h.text);
                ctl.value = TextEditingValue(text: name, selection: TextSelection.collapsed(offset: name.length));
              },
            ),
          ),
        ),
        actions: [
          TextButton(style: inlineButton, onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(style: inlineButton, onPressed: () => Navigator.pop(ctx, ctl.text), child: const Text('Save')),
        ],
      ),
    );
    // The mic of the Name box does not stay on after the box is closed.
    unawaited(VoiceBridge.cancelListen());
    Future<void>.delayed(const Duration(seconds: 1), ctl.dispose);
    if (v == null) return;
    if (it.kind == LibraryKind.audio) {
      await AudioRepo.instance.rename(it.id, v);
      _load();
    } else {
      await _repo.rename(it.id, v);
    }
  }

  Future<void> _tags() async {
    final it = _it!;
    final ctl = TextEditingController(text: it.tags.join(', '));
    final v = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Tags'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'id, bank, trip 2026 — comma separated'),
        ),
        actions: [
          TextButton(style: inlineButton, onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(style: inlineButton, onPressed: () => Navigator.pop(ctx, ctl.text), child: const Text('Save')),
        ],
      ),
    );
    Future<void>.delayed(const Duration(seconds: 1), ctl.dispose);
    if (v == null) return;
    await _repo.setTags(it.id, v.split(','));
  }

  Future<void> _sticky() async {
    final it = _it!;
    final v = await editStickyNote(context, it.body);
    if (v == null) return;
    if (it.kind == LibraryKind.audio) {
      await AudioRepo.instance.setNote(it.id, v);
      _load();
    } else {
      await _repo.setNote(it.id, v);
    }
  }

  Future<void> _delete() async {
    final it = _it!;
    final nav = Navigator.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Move to the bin?'),
        content: const Text('It stays in the bin for 30 days. You can bring it back from Folders → Bin.'),
        actions: [
          TextButton(style: inlineButton, onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
            style: inlineButton,
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Move to bin', style: TextStyle(color: ByteColors.danger)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    _repo.revision.removeListener(_load);
    AudioRepo.instance.revision.removeListener(_load);
    if (it.kind == LibraryKind.audio) {
      await AudioRepo.instance.delete(it.id);
    } else {
      await _repo.delete(it.id);
    }
    nav.pop();
  }

  // ───────────── for a screenshot ─────────────
  // A screenshot is usually kept for its words, or only for a while: the
  // three things people do with one, right under it.

  Future<void> _copyWords() async {
    final it = _it;
    if (it == null) return;
    final messenger = ScaffoldMessenger.of(context);
    await Clipboard.setData(ClipboardData(text: it.text.trim()));
    messenger.showSnackBar(const SnackBar(content: Text('The words are copied. Paste them anywhere.')));
  }

  Future<void> _noteFromIt() async {
    final it = _it;
    if (it == null) return;
    final messenger = ScaffoldMessenger.of(context);
    await NotesRepo.instance.create(title: it.displayTitle, body: it.text.trim());
    messenger.showSnackBar(const SnackBar(content: Text('Saved as a note. It is under Notes.')));
  }

  Future<void> _binInAWeek() async {
    final it = _it;
    if (it == null) return;
    final messenger = ScaffoldMessenger.of(context);
    await Expiry.setFor([it.id], 7);
    final at = await Expiry.of(it.id);
    if (!mounted) return;
    setState(() => _expires = at);
    messenger.showSnackBar(const SnackBar(content: Text('It moves to the bin in a week, and waits there 30 more days.')));
  }

  /// "Delete by itself": for things needed only for a while. On its last day
  /// the item moves to the bin (where it still waits 30 days).
  Future<void> _expire() async {
    final it = _it;
    if (it == null) return;
    final choice = await showModalBottomSheet<int>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(ByteSpace.page, 16, ByteSpace.page, 4),
              child: Align(alignment: Alignment.centerLeft, child: Text('Move this to the bin by itself', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700))),
            ),
            for (final (days, label) in const [(1, 'Tomorrow'), (7, 'In a week'), (30, 'In a month'), (90, 'In three months')])
              ListTile(title: Text(label), onTap: () => Navigator.pop(ctx, days)),
            ListTile(title: const Text('Never (keep it)'), onTap: () => Navigator.pop(ctx, 0)),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (choice == null) return;
    await Expiry.setFor([it.id], choice == 0 ? null : choice);
    final at = await Expiry.of(it.id);
    if (!mounted) return;
    setState(() => _expires = at);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(at == null ? 'It stays until you delete it.' : 'It moves to the bin on ${at.day}/${at.month}/${at.year}. It waits there 30 more days.'),
    ));
  }

  /// "Where does this belong?" — BYTE's sorting can be wrong; what you choose
  /// here stands and is never changed by BYTE again.
  Future<void> _choosePlace() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.75),
          child: ListView(
            shrinkWrap: true,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(ByteSpace.page, 4, ByteSpace.page, 8),
                child: Text('Which album does this belong in?', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
              ),
              ListTile(
                title: const Text('Let BYTE decide'),
                trailing: _fixed.isEmpty ? Icon(Icons.check_rounded, color: ByteColors.accentDim) : null,
                onTap: () => Navigator.pop(ctx, ''),
              ),
              ListTile(
                title: const Text('None of these'),
                subtitle: const Text('Only where it came from (Camera, WhatsApp…)'),
                trailing: _fixed == '-' ? Icon(Icons.check_rounded, color: ByteColors.accentDim) : null,
                onTap: () => Navigator.pop(ctx, '-'),
              ),
              for (final place in choosablePlaces)
                ListTile(
                  title: Text(place),
                  trailing: _fixed == place ? Icon(Icons.check_rounded, color: ByteColors.accentDim) : null,
                  onTap: () => Navigator.pop(ctx, place),
                ),
            ],
          ),
        ),
      ),
    );
    if (choice == null || choice == _fixed) return;
    await _repo.setFixedPlace(widget.itemId, choice);
    unawaited(Albums.sort());
  }

  /// In or out of the document wallet (Folders → Document wallet), where a
  /// paper can be given the day it runs out.
  Future<void> _toggleWallet() async {
    final now = !_inWallet;
    final messenger = ScaffoldMessenger.of(context);
    if (now) {
      await Wallet.add(widget.itemId);
    } else {
      await Wallet.remove(widget.itemId);
    }
    if (!mounted) return;
    setState(() => _inWallet = now);
    messenger.showSnackBar(SnackBar(content: Text(now ? 'In your document wallet (Folders → Document wallet). Set the day it runs out there.' : 'Taken out of the document wallet.')));
  }

  /// Into the private space; this screen closes, because the item no longer
  /// belongs to the Library.
  Future<void> _makePrivate() async {
    final it = _it;
    if (it == null) return;
    final nav = Navigator.of(context);
    // In the sheet: asked from the screen under it, so its messages outlive the sheet.
    final moved = await PrivateGate.makePrivate(widget.embedded ? nav.context : context, [it.id]);
    if (moved && mounted) nav.pop();
  }

  Future<void> _share() async {
    final it = _it!;
    if (it.kind == LibraryKind.link) {
      await SharePlus.instance.share(ShareParams(text: it.url));
    } else if (it.hasFile) {
      final path = await _local();
      if (path == null) return;
      await SharePlus.instance.share(ShareParams(files: [XFile(path)], text: it.displayTitle));
    }
  }

  Future<void> _openExternal() async {
    final it = _it!;
    if (it.kind == LibraryKind.link) {
      final u = Uri.tryParse(it.url);
      if (u != null) await launchUrl(u, mode: LaunchMode.externalApplication);
      return;
    }
    if (it.hasFile) {
      final path = await _local();
      if (path == null) return;
      final r = await OpenFilex.open(path);
      if (r.type != ResultType.done && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('No app can open this: ${r.message}')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final it = _it;
    if (it == null) return widget.embedded ? const SizedBox.shrink() : const Scaffold(body: SizedBox.shrink());
    final about = [
      it.kind.label.replaceAll(RegExp(r's$'), ''),
      if (it.ext.isNotEmpty) it.ext,
      if (it.size > 0) humanSize(it.size),
      '${it.createdAt.day}/${it.createdAt.month}/${it.createdAt.year}',
      if (_expires != null) 'moves to the bin by itself on ${_expires!.day}/${_expires!.month}/${_expires!.year}',
    ].join(', ');
    final readState = it.indexStatus == 'pending' || it.indexStatus == 'working'
        ? 'BYTE is still reading this…'
        : it.indexStatus == 'unsupported'
            ? 'BYTE can\'t read inside this type yet. Name and tags are searchable.'
            : it.indexStatus == 'failed'
                ? 'Couldn\'t read this one. Try "Read it again" from the menu.'
                : it.text.trim().isEmpty
                    ? (it.kind == LibraryKind.audio
                        ? 'No words were heard in this one.'
                        : it.kind == LibraryKind.photo || it.kind == LibraryKind.video
                            ? 'No words found in this one.'
                            : 'Nothing readable found.')
                    : null;
    final found = widget.find.trim().isEmpty ? null : hitIn(it, widget.find);
    final actions = <Widget>[
          IconButton(
            tooltip: _pinned ? 'Remove star' : 'Star',
            icon: Icon(_pinned ? Icons.star_rounded : Icons.star_outline_rounded, color: _pinned ? ByteColors.accentDim : null),
            onPressed: _togglePin,
          ),
          IconButton(
            tooltip: 'Move to a folder',
            icon: const Icon(Icons.drive_file_move_outline),
            onPressed: () async {
              final changed = await CollectionPicker.show(context, itemIds: [it.id]);
              if (!context.mounted || changed == null || changed.isEmpty) return;
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(changed.join(', '))));
            },
          ),
          IconButton(tooltip: 'Share', icon: const Icon(Icons.share_outlined), onPressed: _share),
          PopupMenuButton<String>(
            tooltip: 'More',
            onSelected: (v) {
              switch (v) {
                case 'rename':
                  _rename();
                case 'tags':
                  _tags();
                case 'fix':
                  _fix('brighter');
                case 'open':
                  _openExternal();
                case 'reindex':
                  _repo.resetIndex(it.id);
                case 'wallet':
                  _toggleWallet();
                case 'private':
                  _makePrivate();
                case 'expire':
                  _expire();
                case 'delete':
                  _delete();
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'rename', child: Text('Rename')),
              const PopupMenuItem(value: 'tags', child: Text('Edit tags')),
              if (it.kind == LibraryKind.photo && it.hasFile)
                const PopupMenuItem(value: 'fix', child: Text('Fix photo (brighter or clearer)')),
              if (it.kind != LibraryKind.note && it.kind != LibraryKind.audio)
                const PopupMenuItem(value: 'open', child: Text('Open with…')),
              if (it.kind != LibraryKind.note && it.kind != LibraryKind.audio)
                const PopupMenuItem(value: 'reindex', child: Text('Read it again')),
              if (it.kind == LibraryKind.photo || it.kind == LibraryKind.doc)
                PopupMenuItem(value: 'wallet', child: Text(_inWallet ? 'Take out of the document wallet' : 'Add to the document wallet')),
              const PopupMenuItem(value: 'private', child: Text('Make private')),
              PopupMenuItem(value: 'expire', child: Text(_expires == null ? 'Delete by itself after…' : 'Change when it deletes itself')),
              PopupMenuItem(value: 'delete', child: Text('Move to bin', style: TextStyle(color: ByteColors.danger))),
            ],
          ),
    ];
    final details = <Widget>[
          // Came from Search: where the word is, before anything else.
          if (found != null) ...[
            SectionLabel(found.page == null ? 'Found here' : 'Found on page ${found.page}', top: 16),
            Well(
              child: Text.rich(
                TextSpan(children: [
                  TextSpan(text: '…${found.before}'),
                  TextSpan(text: found.match, style: TextStyle(fontWeight: FontWeight.w800, backgroundColor: ByteColors.accentSoft)),
                  TextSpan(text: '${found.after}…'),
                ]),
                style: tt.bodyMedium,
              ),
            ),
          ],
          // The one action for a link or a file.
          if (it.kind == LibraryKind.link || it.kind == LibraryKind.doc)
            Padding(
              padding: const EdgeInsets.fromLTRB(ByteSpace.page, 16, ByteSpace.page, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  FilledButton.icon(
                    onPressed: _openExternal,
                    icon: const Icon(Icons.open_in_new_rounded),
                    label: Text(it.kind == LibraryKind.link ? 'Open link' : 'Open file'),
                  ),
                  if (it.kind == LibraryKind.link) ...[
                    const SizedBox(height: 8),
                    SelectableText(it.url, style: tt.bodySmall),
                  ],
                ],
              ),
            ),
          if (it.kind != LibraryKind.note)
            Padding(
              padding: const EdgeInsets.fromLTRB(ByteSpace.page, 16, ByteSpace.page, 0),
              child: StickyNote(text: it.body, onTap: _sticky),
            ),
          // A screenshot: copy its words, keep them as a note, or let it go by itself.
          if (it.kind == LibraryKind.photo && !it.private && _places.contains(Places.screenshots))
            Padding(
              padding: const EdgeInsets.fromLTRB(ByteSpace.page, 12, ByteSpace.page, 0),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (it.text.trim().isNotEmpty)
                    FilledButton.tonalIcon(style: inlineButton, onPressed: _copyWords, icon: const Icon(Icons.copy_rounded, size: 18), label: const Text('Copy the words')),
                  if (it.text.trim().isNotEmpty)
                    FilledButton.tonalIcon(style: inlineButton, onPressed: _noteFromIt, icon: const Icon(Icons.sticky_note_2_outlined, size: 18), label: const Text('Make a note of it')),
                  if (_expires == null)
                    FilledButton.tonalIcon(style: inlineButton, onPressed: _binInAWeek, icon: const Icon(Icons.auto_delete_outlined, size: 18), label: const Text('Bin it in a week')),
                ],
              ),
            ),
          // Details as rows.
          const SectionLabel('Details', top: 20),
          ByteList(
            children: [
              ByteRow(
                icon: Icons.edit_outlined,
                title: 'Name',
                subtitle: it.displayTitle,
                titleWeight: FontWeight.w600,
                chevron: true,
                onTap: _rename,
              ),
              ByteRow(
                icon: Icons.sell_outlined,
                title: 'Tags',
                subtitle: it.tags.isEmpty ? 'None yet' : it.tags.join(', '),
                titleWeight: FontWeight.w600,
                chevron: true,
                onTap: _tags,
              ),
              // Where BYTE filed it — and the way to say "no, it belongs there".
              if (it.kind == LibraryKind.photo || it.kind == LibraryKind.video || it.kind == LibraryKind.doc)
                ByteRow(
                  icon: Icons.photo_album_outlined,
                  title: 'Albums',
                  subtitle: _places.isEmpty
                      ? (it.kind == LibraryKind.doc ? 'In no album. Tap to choose one' : 'Not sorted yet')
                      : '${_places.join(', ')}${_fixed.isEmpty ? '' : ' (you chose)'}. Tap to change',
                  titleWeight: FontWeight.w600,
                  chevron: true,
                  onTap: _choosePlace,
                ),
              ByteRow(
                icon: Icons.info_outline_rounded,
                title: 'About',
                subtitle: about,
                titleWeight: FontWeight.w600,
              ),
              if (_isMedia) _driveRow(it),
            ],
          ),
          if (it.labels.isNotEmpty) ...[
            const SectionLabel('BYTE sees'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: ByteSpace.page),
              child: Wrap(spacing: 6, runSpacing: 6, children: [for (final l in it.labels) Chip(label: Text(l), visualDensity: VisualDensity.compact)]),
            ),
          ],
          SectionLabel(switch (it.kind) {
            LibraryKind.photo => 'Text in this photo',
            LibraryKind.video => 'What\'s in this video',
            LibraryKind.doc => 'Text inside',
            LibraryKind.link => 'About this link',
            LibraryKind.audio => 'What was said',
            _ => 'What BYTE read',
          }),
          if (readState != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: ByteSpace.page),
              child: Text(readState, style: tt.bodyMedium?.copyWith(color: ByteColors.textDim)),
            )
          else
            _TextPreview(text: readablePages(it.text)),
    ];
    if (widget.embedded) {
      // The sheet over a photo or video: its name, the same buttons, the details.
      return ListView(
        controller: widget.scroll,
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(ByteSpace.page, 4, ByteSpace.page, 0),
            child: Text(it.displayTitle, maxLines: 2, overflow: TextOverflow.ellipsis, style: tt.titleLarge),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(ByteSpace.page - 12, 4, ByteSpace.page - 12, 0),
            child: Row(children: actions),
          ),
          ...details,
        ],
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(it.displayTitle, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: actions,
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          // The thing itself.
          _hero(it),
          ...details,
        ],
      ),
    );
  }

  /// One quiet row: where this photo/video lives, and "Keep on this phone".
  Widget _driveRow(LibraryItem it) {
    final e = _drive;
    final onPhone = File(it.path).existsSync();
    final (String sub, IconData icon) = switch (e) {
      null => ('On this phone only', Icons.smartphone_rounded),
      DriveEntry(inDrive: true, keep: true) => ('In Google Drive, and kept on this phone', Icons.cloud_done_outlined),
      DriveEntry(inDrive: true) when onPhone => ('In Google Drive', Icons.cloud_done_outlined),
      DriveEntry(inDrive: true) => ('In Google Drive. Opens from there', Icons.cloud_outlined),
      DriveEntry(state: 'uploading') => ('Uploading to Google Drive…', Icons.cloud_upload_outlined),
      DriveEntry(state: 'failed') => ('Waiting to upload. Tries again by itself', Icons.cloud_queue_rounded),
      DriveEntry() => ('Waiting to upload', Icons.cloud_queue_rounded),
    };
    return ByteRow(
      icon: icon,
      tone: e?.inDrive == true ? 'act' : 'plain',
      title: 'Google Drive',
      subtitle: _bringing ? 'Getting it from Drive…' : sub,
      titleWeight: FontWeight.w600,
      trailing: e == null
          ? null
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                ByteSwitch(
                  value: e.keep,
                  onChanged: (v) async {
                    // Grabbed before the wait, so no context is used after it.
                    final messenger = ScaffoldMessenger.of(context);
                    final ok = await DriveMedia.setKeep(it, v);
                    if (!ok) messenger.showSnackBar(const SnackBar(content: Text('Needs the internet to bring it back to the phone.')));
                    await _loadDrive();
                  },
                ),
                Text('Keep on phone', style: Theme.of(context).textTheme.labelSmall),
              ],
            ),
    );
  }

  Widget _hero(LibraryItem it) {
    switch (it.kind) {
      case LibraryKind.photo:
        return _PhotoHero(
          item: it,
          inDrive: _drive?.inDrive == true,
          onOpenFull: (path) => Navigator.of(context).push(PageRouteBuilder<void>(
            opaque: false,
            transitionDuration: const Duration(milliseconds: 280),
            reverseTransitionDuration: const Duration(milliseconds: 220),
            pageBuilder: (_, a, _) => FadeTransition(opacity: CurvedAnimation(parent: a, curve: Curves.easeOutCubic), child: _FullImage(path: path)),
          )),
        );
      case LibraryKind.video:
        // Rebuilt only when the source changes (phone file ↔ Drive stream), not
        // on every status bump — that would restart a playing video.
        final remote = File(it.path).existsSync() ? null : _drive?.remoteId;
        return VideoBox(key: ValueKey('v-${remote ?? it.path}'), item: it, remoteId: remote, onOpen: _openExternal);
      case LibraryKind.audio:
        return _AudioBox(item: it);
      case LibraryKind.link:
        return it.thumb.isNotEmpty && File(it.thumb).existsSync()
            ? Container(
                color: Colors.black,
                constraints: const BoxConstraints(maxHeight: 260),
                child: Image.file(File(it.thumb), fit: BoxFit.contain),
              )
            : SizedBox(height: 160, child: LibraryThumb(item: it));
      default:
        return SizedBox(height: 160, child: LibraryThumb(item: it));
    }
  }
}

class _TextPreview extends StatefulWidget {
  const _TextPreview({required this.text});
  final String text;
  @override
  State<_TextPreview> createState() => _TextPreviewState();
}

class _TextPreviewState extends State<_TextPreview> {
  bool _all = false;
  @override
  Widget build(BuildContext context) {
    final t = widget.text.trim();
    final short = t.length > 1200 && !_all ? '${t.substring(0, 1200)}…' : t;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Well(child: SelectableText(short, style: Theme.of(context).textTheme.bodyMedium)),
        if (t.length > 1200)
          Padding(
            padding: const EdgeInsets.fromLTRB(ByteSpace.page - 8, 4, 0, 0),
            child: TextButton(style: inlineButton, onPressed: () => setState(() => _all = !_all), child: Text(_all ? 'Show less' : 'Show all')),
          ),
      ],
    );
  }
}

class _FullImage extends StatelessWidget {
  const _FullImage({required this.path});
  final String path;
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black, foregroundColor: Colors.white),
      body: InteractiveViewer(
        maxScale: 6,
        child: Center(child: Image.file(File(path), fit: BoxFit.contain)),
      ),
    );
  }
}

/// A photo: the small preview at once, the full picture fading in over it
/// (from the phone, or brought back from Drive with a thin progress line).
class _PhotoHero extends StatefulWidget {
  const _PhotoHero({required this.item, required this.inDrive, required this.onOpenFull});
  final LibraryItem item;
  final bool inDrive;
  final void Function(String path) onOpenFull;

  @override
  State<_PhotoHero> createState() => _PhotoHeroState();
}

class _PhotoHeroState extends State<_PhotoHero> {
  String? _full;
  double? _progress; // null = not downloading
  bool _offline = false;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(covariant _PhotoHero old) {
    super.didUpdateWidget(old);
    // Its Drive status arrived (or the file moved): try again if nothing is shown yet.
    if (_full == null && _progress == null && (old.inDrive != widget.inDrive || old.item.path != widget.item.path)) _resolve();
  }

  Future<void> _resolve() async {
    final it = widget.item;
    if (File(it.path).existsSync()) {
      setState(() => _full = it.path);
      unawaited(DriveMedia.ensureLocal(it)); // on screen: not freed for a while
      return;
    }
    if (!widget.inDrive) return;
    setState(() {
      _progress = 0;
      _offline = false;
    });
    final path = await DriveMedia.ensureLocal(it, onProgress: (got, total) {
      if (mounted && total > 0) setState(() => _progress = got / total);
    });
    if (!mounted) return;
    setState(() {
      _full = path;
      _progress = null;
      _offline = path == null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final it = widget.item;
    final full = _full;
    return GestureDetector(
      onTap: full == null ? (_offline ? _resolve : null) : () => widget.onOpenFull(full),
      child: Hero(
        tag: 'media-${it.id}',
        child: Container(
        color: Colors.black,
        constraints: const BoxConstraints(maxHeight: 420, minHeight: 220),
        child: Stack(
          alignment: Alignment.center,
          children: [
            // The preview is always under, so nothing ever flashes empty.
            Positioned.fill(child: LibraryThumb(item: it, fit: BoxFit.contain, bare: true)),
            AnimatedOpacity(
              opacity: full == null ? 0 : 1,
              duration: const Duration(milliseconds: 420),
              curve: Curves.easeOutCubic,
              child: full == null
                  ? const SizedBox(height: 220)
                  : Image.file(
                      File(full),
                      fit: BoxFit.contain,
                      gaplessPlayback: true,
                      errorBuilder: (_, _, _) => const SizedBox(height: 220),
                    ),
            ),
            if (_progress != null)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0, end: _progress!),
                  duration: const Duration(milliseconds: 240),
                  builder: (_, v, _) => LinearProgressIndicator(value: v == 0 ? null : v, minHeight: 2, backgroundColor: Colors.transparent, color: ByteColors.accent),
                ),
              ),
            if (_offline)
              Positioned(
                bottom: 12,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.55), borderRadius: BorderRadius.circular(999)),
                  child: Text('Full photo is in Drive. Tap when online', style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Colors.white)),
                ),
              ),
          ],
        ),
        ),
      ),
    );
  }
}

/// A video that plays in place (from the phone, or streamed from Drive).
class VideoBox extends StatefulWidget {
  const VideoBox({super.key, required this.item, required this.onOpen, this.remoteId, this.maxHeight = 360, this.autoPlay = false});
  final LibraryItem item;
  final VoidCallback onOpen;

  /// The picture is never taller than this.
  final double maxHeight;

  /// Start playing as soon as it is ready (the full-screen viewer: you
  /// already tapped play).
  final bool autoPlay;

  /// Set when the video lives only in Drive: it streams from there.
  final String? remoteId;
  @override
  State<VideoBox> createState() => VideoBoxState();
}

class VideoBoxState extends State<VideoBox> {
  VideoPlayerController? _c;
  String _err = '';

  @override
  void initState() {
    super.initState();
    if (Platform.isAndroid) _start();
  }

  Future<void> _start() async {
    VideoPlayerController c;
    final remote = widget.remoteId;
    if (remote != null && remote.isNotEmpty) {
      // Lives in Drive: stream it (Drive serves ranges, so it starts at once).
      final token = await DriveMedia.token();
      if (!mounted) return;
      if (token == null) {
        setState(() => _err = 'offline');
        return;
      }
      c = VideoPlayerController.networkUrl(CloudSync.mediaUrl(remote), httpHeaders: {'Authorization': 'Bearer $token'});
    } else {
      c = VideoPlayerController.file(File(widget.item.path));
      unawaited(DriveMedia.ensureLocal(widget.item)); // playing: not freed for a while
    }
    c.initialize().then((_) {
      if (!mounted) return;
      setState(() {});
      if (widget.autoPlay) c.play();
    }).catchError((e) {
      if (mounted) setState(() => _err = '$e');
    });
    c.addListener(() {
      if (mounted) setState(() {});
    });
    _c = c;
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _c?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    if (c == null || _err.isNotEmpty || !c.value.isInitialized) {
      return GestureDetector(
        onTap: widget.onOpen,
        child: Container(
          height: 220,
          color: Colors.black,
          child: Stack(
            fit: StackFit.expand,
            children: [
              LibraryThumb(item: widget.item, fit: BoxFit.contain, bare: true),
              const Center(child: Icon(Icons.play_circle_fill_rounded, size: 64, color: Colors.white70)),
              if (_err.isNotEmpty)
                Positioned(
                  bottom: 8, left: 12, right: 12,
                  child: Text(
                    _err == 'offline' ? 'This video plays from Google Drive when you\'re online' : 'Tap to open in another app',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.white.withValues(alpha: 0.8)),
                  ),
                ),
              if (_err.isEmpty && c != null && !c.value.isInitialized)
                const Positioned(left: 0, right: 0, bottom: 0, child: LinearProgressIndicator(minHeight: 2, backgroundColor: Colors.transparent)),
            ],
          ),
        ),
      );
    }
    final v = c.value;
    return Container(
      color: Colors.black,
      child: Column(
        mainAxisSize: MainAxisSize.min, // centred in the full-screen viewer; no change inside a list
        children: [
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: widget.maxHeight < 120 ? 120 : widget.maxHeight),
            child: AspectRatio(
              aspectRatio: v.aspectRatio == 0 ? 16 / 9 : v.aspectRatio,
              child: GestureDetector(
                onTap: () => v.isPlaying ? c.pause() : c.play(),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    VideoPlayer(c),
                    if (!v.isPlaying)
                      const Center(child: Icon(Icons.play_circle_fill_rounded, size: 64, color: Colors.white70)),
                  ],
                ),
              ),
            ),
          ),
          VideoProgressIndicator(c, allowScrubbing: true, colors: VideoProgressColors(playedColor: ByteColors.accent)),
        ],
      ),
    );
  }
}

class _AudioBox extends StatefulWidget {
  const _AudioBox({required this.item});
  final LibraryItem item;
  @override
  State<_AudioBox> createState() => _AudioBoxState();
}

class _AudioBoxState extends State<_AudioBox> {
  final _player = AudioPlayer();
  bool _playing = false;
  Duration _pos = Duration.zero;
  Duration _total = Duration.zero;

  @override
  void initState() {
    super.initState();
    _player.setAudioContext(AudioContext(
      android: const AudioContextAndroid(
        contentType: AndroidContentType.speech,
        usageType: AndroidUsageType.media,
        audioFocus: AndroidAudioFocus.none,
      ),
    ));
    _player.onPositionChanged.listen((d) {
      if (mounted) setState(() => _pos = d);
    });
    _player.onDurationChanged.listen((d) {
      if (mounted) setState(() => _total = d);
    });
    _player.onPlayerComplete.listen((_) {
      if (!mounted) return;
      _started = false;
      setState(() {
        _playing = false;
        _pos = Duration.zero;
      });
    });
    AudioRepo.instance.get(widget.item.id).then((a) {
      if (mounted && a != null) setState(() => _own = true);
    }).catchError((Object e) {
      debugPrint('[library] voice note: $e');
    });
    // Imported audio (call recordings, mp3) has no stored duration: ask the
    // decoder without playing.
    if (widget.item.durationMs == 0 && widget.item.path.isNotEmpty) {
      _player.setSource(DeviceFileSource(widget.item.path)).then((_) async {
        final d = await _player.getDuration();
        if (mounted && d != null) setState(() => _total = d);
      }).catchError((Object e) {
        debugPrint('[library] audio duration: $e');
      });
    }
  }

  Future<void> _seekBy(int seconds) async {
    final total = _total == Duration.zero ? Duration(milliseconds: widget.item.durationMs) : _total;
    var to = _pos + Duration(seconds: seconds);
    if (to < Duration.zero) to = Duration.zero;
    if (total > Duration.zero && to > total) to = total;
    await _player.seek(to);
    if (mounted) setState(() => _pos = to);
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  bool _started = false; // a source is loaded; pause/play continue from the head

  /// BYTE's own voice notes have words to read and fix; audio files brought
  /// in from elsewhere (songs, call recordings) do not.
  bool _own = false;

  Future<void> _openWords() async {
    if (_playing) {
      await _player.pause();
      if (!mounted) return;
      setState(() => _playing = false);
    }
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => VoiceNoteScreen(itemId: widget.item.id)));
  }

  Future<void> _toggle() async {
    if (_playing) {
      await _player.pause();
      setState(() => _playing = false);
      return;
    }
    if (_started && _pos > Duration.zero) {
      await _player.resume();
    } else {
      await _player.play(DeviceFileSource(widget.item.path), position: _pos > Duration.zero ? _pos : null);
      _started = true;
    }
    setState(() => _playing = true);
  }

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final total = _total == Duration.zero ? Duration(milliseconds: widget.item.durationMs) : _total;
    return Padding(
      padding: const EdgeInsets.fromLTRB(ByteSpace.page, 28, ByteSpace.page, 8),
      child: Row(
        children: [
          // The one action: play.
          Material(
            color: ByteColors.accentBright,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: _toggle,
              child: SizedBox(
                width: 56,
                height: 56,
                child: Icon(_playing ? Icons.pause_rounded : Icons.play_arrow_rounded, size: 28, color: ByteColors.onAccent, semanticLabel: _playing ? 'Pause' : 'Play'),
              ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 3,
                    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                    overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                    activeTrackColor: ByteColors.accent,
                    inactiveTrackColor: ByteColors.border,
                    thumbColor: ByteColors.accent,
                  ),
                  child: Slider(
                    padding: EdgeInsets.zero,
                    value: total.inMilliseconds == 0 ? 0 : _pos.inMilliseconds.clamp(0, total.inMilliseconds).toDouble(),
                    max: total.inMilliseconds == 0 ? 1 : total.inMilliseconds.toDouble(),
                    onChanged: total.inMilliseconds == 0
                        ? null
                        : (v) async {
                            final to = Duration(milliseconds: v.round());
                            await _player.seek(to);
                            if (mounted) setState(() => _pos = to);
                          },
                  ),
                ),
                Row(
                  children: [
                    Text('${_fmt(_pos)} / ${_fmt(total)}', style: tt.bodySmall?.copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
                    const Spacer(),
                    IconButton(
                      tooltip: 'Back 10 seconds',
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.replay_10_rounded, size: 22),
                      onPressed: () => _seekBy(-10),
                    ),
                    IconButton(
                      tooltip: 'Forward 10 seconds',
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.forward_10_rounded, size: 22),
                      onPressed: () => _seekBy(10),
                    ),
                  ],
                ),
                if (_own) TextButton(style: inlineButton, onPressed: _openWords, child: const Text('Read and fix the words')),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
