import 'package:flutter/widgets.dart';
import 'package:pkmproject/services/database_helper.dart';
import 'package:pkmproject/sync_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

class WorkManagerService {
  static const String syncTaskName = 'syncSOSMessages';

  static Future<void> initialize() async {
    if (SyncService.offlineOnly) {
      print('[WorkManagerService] Offline-only mode active. Skipping init.');
      return;
    }

    await Workmanager().initialize(callbackDispatcher, isInDebugMode: false);
    print('[WorkManagerService] WorkManager initialized');
  }

  static Future<void> registerSyncTask() async {
    if (SyncService.offlineOnly) {
      print(
        '[WorkManagerService] Offline-only mode active. Sync task not registered.',
      );
      return;
    }

    try {
      await Workmanager().registerOneOffTask(
        syncTaskName,
        syncTaskName,
        existingWorkPolicy: ExistingWorkPolicy.replace,
        constraints: Constraints(networkType: NetworkType.connected),
        initialDelay: const Duration(seconds: 5),
      );

      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool('pending_sync', true);
        print('[WorkManagerService] Persisted pending_sync=true');
      } catch (e) {
        print('[WorkManagerService] Failed to persist pending_sync: $e');
      }
      print('[WorkManagerService] Sync task registered with WorkManager');
    } catch (e) {
      print('[WorkManagerService] Error registering sync task: $e');
    }
  }

  static Future<void> cancelSyncTask() async {
    try {
      await Workmanager().cancelByUniqueName(syncTaskName);
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool('pending_sync', false);
        print('[WorkManagerService] Cleared pending_sync flag');
      } catch (e) {
        print('[WorkManagerService] Failed to clear pending_sync: $e');
      }
      print('[WorkManagerService] Sync task cancelled');
    } catch (e) {
      print('[WorkManagerService] Error cancelling sync task: $e');
    }
  }
}

@pragma('vm:entry-point')
void callbackDispatcher() {
  WidgetsFlutterBinding.ensureInitialized();
  print('[WorkManager] callbackDispatcher initialized');

  Workmanager().executeTask((task, inputData) async {
    print('[WorkManager] Task executed: $task');

    if (task != WorkManagerService.syncTaskName) {
      return Future.value(true);
    }

    if (SyncService.offlineOnly) {
      print('[WorkManager] Offline-only mode active. Task skipped.');
      return Future.value(true);
    }

    try {
      await DatabaseHelper().database;
      await SyncService().initializeIdentity();

      final syncService = SyncService();
      await syncService.initiateFullSync();

      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool('pending_sync', false);
        print('[WorkManager] Cleared pending_sync after successful sync');
      } catch (e) {
        print('[WorkManager] Failed to clear pending_sync after sync: $e');
      }
      return Future.value(true);
    } catch (e, st) {
      print('[WorkManager] Error in sync task: $e\n$st');
      return Future.value(false);
    }
  });
}
