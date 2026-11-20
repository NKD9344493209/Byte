import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/cloud_sync.dart';
import '../../core/friends.dart';
import '../../shared/theme.dart';
import '../notes/checklist_view.dart';

/// "Share with a friend" for photos and videos picked in the Library: they
/// go into an album the two of you share — a new one, or one you have.
class FriendShare {
  FriendShare._();

  /// Asks which album, makes the copies (with a small "working" box) and
  /// says what happened. True when something was shared.
  static Future<bool> run(BuildContext context, Friend friend, List<String> itemIds) async {
    final messenger = ScaffoldMessenger.of(context);
    final nav = Navigator.of(context, rootNavigator: true);
    final existing = await Friends.albumsWith(friend);
    if (!context.mounted) return false;

    // Which album: one you already share, or a new one.
    var albumId = '';
    var title = '';
    if (existing.isNotEmpty) {
      final pick = await showModalBottomSheet<String>(
        context: context,
        builder: (ctx) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(title: Text('Share with ${friend.name}'), subtitle: const Text('Into which album?')),
              for (final a in existing)
                ListTile(
                  leading: Icon(Icons.photo_library_outlined, color: ByteColors.accentDim),
                  title: Text(a.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text('${a.count} in it'),
                  onTap: () => Navigator.pop(ctx, a.id),
                ),
              ListTile(
                leading: Icon(Icons.add_rounded, color: ByteColors.accentDim),
                title: const Text('A new album'),
                onTap: () => Navigator.pop(ctx, 'new'),
              ),
            ],
          ),
        ),
      );
      if (pick == null || !context.mounted) return false;
      if (pick != 'new') albumId = pick;
    }
    if (albumId.isEmpty) {
      final name = await ChecklistView.askLine(context, title: 'Name of the album', initial: 'Photos with ${friend.name}', action: 'Share');
      if (name == null || !context.mounted) return false;
      title = name;
    }

    // A small "working" box that cannot be tapped away while copies are made.
    final progress = ValueNotifier<String>('Getting ready…');
    var stop = false;
    final working = DialogRoute<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => PopScope(
        canPop: false,
        child: AlertDialog(
          content: Row(
            children: [
              const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4)),
              const SizedBox(width: 16),
              Expanded(child: ValueListenableBuilder<String>(valueListenable: progress, builder: (_, s, _) => Text(s))),
            ],
          ),
          actions: [
            TextButton(
              style: inlineButton,
              onPressed: () {
                stop = true;
                progress.value = 'Stopping…';
              },
              child: const Text('Stop'),
            ),
          ],
        ),
      ),
    );
    nav.push(working);
    var shared = 0;
    var problem = '';
    try {
      shared = await Friends.addToAlbum(
        friend,
        itemIds: itemIds,
        albumId: albumId,
        title: title,
        onProgress: (done, total) {
          if (!stop) progress.value = 'Copying $done of $total…';
        },
        shouldStop: () => stop,
      );
    } on FriendProblem catch (e) {
      problem = e.message;
    } on CloudNeedsSignIn {
      problem = 'Google Drive asked you to sign in again. Open Settings, then Google Drive.';
    } on SocketException {
      problem = 'No internet. Nothing was shared.';
    } catch (e) {
      debugPrint('[friend share] $e');
      problem = stop ? 'Stopped. Nothing was shared.' : 'Could not share them. Check the internet and Google Drive, then try again.';
    } finally {
      // Exactly this box goes, whatever else is on screen by now.
      if (working.isActive) nav.removeRoute(working);
      // (The box may still be closing for a moment.)
      Future<void>.delayed(const Duration(seconds: 1), progress.dispose);
    }
    if (problem.isNotEmpty) {
      messenger.showSnackBar(SnackBar(content: Text(problem)));
      return false;
    }
    messenger.showSnackBar(SnackBar(
      duration: const Duration(seconds: 6),
      content: Text('$shared ${shared == 1 ? 'thing is' : 'things are'} in the album. ${friend.name} sees ${shared == 1 ? 'it' : 'them'} in BYTE the next time it is open (Folders, then Friends and sharing).'),
    ));
    return true;
  }
}
