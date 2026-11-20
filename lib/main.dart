import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'app.dart';
import 'core/app_lock.dart';
import 'core/backup.dart';
import 'core/capture_trigger.dart';
import 'core/cloud_sync.dart';
import 'core/db.dart';
import 'core/drive_media.dart';
import 'core/friends.dart';
import 'core/expiry.dart';
import 'core/gallery.dart';
import 'core/prefs.dart';
import 'core/private_space.dart';
import 'core/share_intake.dart';
import 'core/shares.dart';
import 'core/storage_audit.dart';
import 'core/watch_background.dart';
import 'features/albums/albums.dart';
import 'features/capture/audio_compress.dart';
import 'features/library/indexer.dart';
import 'features/notes/repeats.dart';
import 'features/notes/task_reminders.dart';
import 'features/search/words.dart';
import 'features/wallet/wallet.dart';
import 'shared/motion.dart';
import 'shared/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // The SQLite build is chosen in pubspec.yaml (hooks → user_defines →
  // sqlite3.source: sqlite3mc), which gives us encryption via PRAGMA key.
  // The FFI factory is used on every platform so the same code runs on the
  // phone and on Windows.
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    sqfliteFfiInit();
  }
  databaseFactory = databaseFactoryFfi;

  // Never a blank screen: if startup fails, show what went wrong.
  try {
    await Prefs.init();
    await Motion.load();
    AppLock.init();
    await AppDb.instance.open();
    await CaptureTrigger.init();
  } catch (e, st) {
    debugPrint('[boot] $e\n$st');
    runApp(_BootError(error: '$e', stack: '$st'));
    return;
  }

  runApp(const ByteApp());

  // After the first frame so nothing here can slow the first picture down.
  WidgetsBinding.instance.addPostFrameCallback((_) {
    // Things shared to BYTE from other apps.
    ShareIntake.init();
    // Reads what was added (previews, words inside photos and documents).
    LibraryIndexer.instance.start();
    // Photos and videos → Google Drive (watches the network for the Drive pill).
    DriveMedia.init();
    // The phone's own gallery, if it was brought in: list what is new.
    Gallery.init();
    // BYTE's own filing: sorts photos and documents into albums by itself.
    Albums.start();
    // Private space: nothing opened in the last run may still lie around.
    PrivateSpace.init();
    // Things you gave a last day: the ones whose day has come go to the bin.
    Future<void>.delayed(const Duration(seconds: 6), Expiry.runDue);
    // Shared links whose last day has come stop working.
    Future<void>.delayed(const Duration(seconds: 9), Shares.runDue);
    // Document wallet: the reminders are handed to Android again (a restore
    // or a new phone starts with none).
    Future<void>.delayed(const Duration(seconds: 14), Wallet.reschedule);
    Wallet.watch();
    // Friends: shared checklists follow each other.
    Friends.start();
    // Lists that start again every day or week: the new round begins now, not
    // a moment after the first tick.
    unawaited(Repeats.runDue());
    // Reminders of checklist items: the same, and they follow every change.
    Future<void>.delayed(const Duration(seconds: 11), TaskReminders.reschedule);
    TaskReminders.watch();
    // Once: the word list that lets Search forgive a spelling slip.
    Future<void>.delayed(const Duration(seconds: 12), Words.backfillOnce);
    // The daily Drive copy of the vault, also while BYTE is closed.
    WatchBackground.register();
    // Daily safety net; runs quietly in the background.
    Future<void>.delayed(const Duration(seconds: 8), BackupService.autoBackupIfDue);
    // Off-phone copy (Google Drive) once a day on Wi-Fi.
    Future<void>.delayed(const Duration(seconds: 20), CloudSync.autoSyncIfDue);
    // Tidy up: picker/cache leftovers, orphan files, old backup ZIPs inside the app.
    Future<void>.delayed(const Duration(seconds: 20), StorageCleaner.runQuietly);
    // Every recording still in WAV → 8× smaller (AAC). Quiet, one at a time, until none are left.
    Future<void>.delayed(const Duration(seconds: 25), AudioCompressor.compressDue);
  });
}

class _BootError extends StatelessWidget {
  const _BootError({required this.error, required this.stack});
  final String error;
  final String stack;

  @override
  Widget build(BuildContext context) {
    // Shown before ByteApp exists, so it carries the paper-and-ink theme itself.
    final theme = ByteTheme.light();
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: theme,
      home: Scaffold(
        backgroundColor: ByteColors.bg,
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(ByteSpace.page),
            children: [
              Text('BYTE could not start', style: theme.textTheme.headlineSmall),
              const SizedBox(height: 8),
              Text('Send this to Claude:', style: theme.textTheme.bodyMedium?.copyWith(color: ByteColors.textDim)),
              const SizedBox(height: 12),
              SelectableText(error, style: TextStyle(fontFamily: 'monospace', fontSize: 13, color: ByteColors.danger)),
              const SizedBox(height: 12),
              SelectableText(stack, style: TextStyle(fontFamily: 'monospace', fontSize: 11, color: ByteColors.text)),
            ],
          ),
        ),
      ),
    );
  }
}
