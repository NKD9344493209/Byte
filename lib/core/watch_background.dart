import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:workmanager/workmanager.dart';

import 'cloud_sync.dart';
import 'db.dart';
import 'drive_media.dart';
import 'prefs.dart';
import 'shares.dart';
import 'storage_audit.dart';

/// Old periodic job from the assistant days (watches, plan alarms). Cancelled
/// on start; the name is kept only so it can be cancelled.
const _oldTask = 'byte.watches';
const _cloudTask = 'byte.cloud';

/// Runs in a background isolate (Android WorkManager): opens the vault and
/// does the storage work that should not wait for BYTE to be opened —
/// uploads to Google Drive when the internet is back, and the daily Drive
/// copy of the vault.
///
/// The function keeps its old name: WorkManager remembers it by name, and a
/// job scheduled by the previous version must still find it after an update.
@pragma('vm:entry-point')
void watchesDispatcher() {
  Workmanager().executeTask((task, data) async {
    try {
      WidgetsFlutterBinding.ensureInitialized();
      databaseFactory = databaseFactoryFfi;
      await Prefs.init();
      await AppDb.instance.open();
      if (task == DriveMedia.backgroundTask) {
        // The internet came back while BYTE was closed: upload what's waiting.
        await DriveMedia.kick(background: true);
      } else if (task == _cloudTask) {
        // Daily Drive copy. Best effort: if Google sign-in can't give a token
        // without a screen, the next time BYTE is opened does it instead.
        if (await CloudSync.isDue() && (!await CloudSync.wifiOnly() || await CloudSync.onWifi())) {
          final r = await CloudSync.syncNow(background: true);
          debugPrint('[cloud-bg] ${r.ok ? 'uploaded ${r.uploaded}' : r.error}');
        }
        // Shared links whose last day has come stop working, also while BYTE is closed.
        await Shares.runDue();
        // Storage: drop leftovers and orphans (pure file work — the WAV→AAC
        // codec lives in MainActivity, so shrinking waits for the app to open).
        await StorageCleaner.runQuietly();
      }
      await AppDb.instance.close();
    } catch (e) {
      debugPrint('[bg] $e');
    }
    return true;
  });
}

class WatchBackground {
  WatchBackground._();
  static bool _ready = false;

  /// Schedules the daily Drive copy (needs Wi-Fi and some battery). Idempotent.
  static Future<void> register() async {
    if (!Platform.isAndroid || _ready) return;
    _ready = true;
    try {
      await Workmanager().initialize(watchesDispatcher);
      // The 6-hourly assistant job is gone with the features it served.
      try {
        await Workmanager().cancelByUniqueName(_oldTask);
      } catch (e) {
        debugPrint('[bg] cancel old: $e');
      }
      await Workmanager().registerPeriodicTask(
        _cloudTask,
        _cloudTask,
        frequency: const Duration(hours: 12),
        constraints: Constraints(networkType: NetworkType.unmetered, requiresBatteryNotLow: true),
        existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
      );
    } catch (e) {
      debugPrint('[bg] register: $e');
    }
  }
}
