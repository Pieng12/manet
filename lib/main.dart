import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map_tile_caching/flutter_map_tile_caching.dart';
import 'package:pkmproject/screen/home_screen.dart';
import 'package:pkmproject/screen/mesh_monitor_screen.dart';
import 'package:pkmproject/screen/onboarding_screen.dart';
import 'package:pkmproject/screen/permission_screen.dart';
import 'package:pkmproject/screen/research_monitor_screen.dart';
import 'package:pkmproject/screen/splash_screen.dart';
import 'package:pkmproject/services/android_permission_service.dart';
import 'package:pkmproject/services/background_service_manager.dart';
import 'package:pkmproject/services/ble_advertiser_service.dart';
import 'package:pkmproject/services/ble_relay_service.dart';
import 'package:pkmproject/services/database_helper.dart';
import 'package:pkmproject/services/demo_seed_service.dart';
import 'package:pkmproject/services/experiment_logger.dart';
import 'package:pkmproject/services/native_bridge_service.dart';
import 'package:pkmproject/services/native_ble_inbox_drain_service.dart';
import 'package:pkmproject/services/relay_queue_service.dart';
import 'package:pkmproject/services/workmanager_service.dart';
import 'package:pkmproject/sync_service.dart';
import 'package:pkmproject/utils/navigator_key.dart';
import 'package:pkmproject/widgets/resq_ui.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    debugPrint("[main] Flutter error: ${details.exception}");
  };

  try {
    await _initializeCoreServices();
  } catch (e, st) {
    debugPrint("[main] Startup error: $e\n$st");
  }

  runApp(const MyApp());
}

Future<void> _initializeCoreServices() async {
  await DatabaseHelper().database;
  await SyncService().initializeIdentity();
  await ExperimentLogger().ensureSession(deviceId: SyncService().deviceId);
  await ExperimentLogger().logEvent(
    eventType: ExperimentEventTypes.serviceStarted,
    deviceId: SyncService().deviceId,
  );

  try {
    await FMTCObjectBoxBackend().initialise();
    await FMTCStore('mapStore').manage.create();
  } catch (e) {
    debugPrint('[main] Offline map init error: $e');
  }

  await DemoSeedService.seedIfNeeded();
  await DatabaseHelper().cleanupOldDuplicates();
  await WorkManagerService.initialize();
  SyncService().startSyncListener();

  if (await _hasCriticalPermissions()) {
    try {
      await BackgroundServiceManager.startBackgroundService();
      await BackgroundServiceManager.requestIgnoreBatteryOptimizations();
      await BackgroundServiceManager.requestSchedulerTick();
    } catch (e) {
      debugPrint('[main] Background service init error: $e');
    }
  } else {
    debugPrint(
      '[main] Background service deferred until permissions are granted',
    );
  }
}

Future<bool> _hasCriticalPermissions() async {
  return AndroidPermissionService.areCriticalPermissionsGranted();
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      navigatorKey: NavigatorKey.navigatorKey,
      title: 'ResQMesh',
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: ResqColors.ink,
        colorScheme: const ColorScheme.dark(
          primary: ResqColors.ember,
          secondary: ResqColors.signal,
          surface: ResqColors.surface,
          error: ResqColors.danger,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: ResqColors.surface,
          foregroundColor: Colors.white,
          elevation: 0,
          centerTitle: false,
          titleTextStyle: TextStyle(
            color: Colors.white,
            fontSize: 18,
            fontWeight: FontWeight.w800,
          ),
        ),
        snackBarTheme: SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: ResqColors.ember,
            foregroundColor: Colors.white,
            minimumSize: const Size.fromHeight(48),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
            textStyle: const TextStyle(fontWeight: FontWeight.w800),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            foregroundColor: ResqColors.field,
            side: const BorderSide(color: ResqColors.line),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        ),
        cardTheme: CardThemeData(
          color: ResqColors.surfaceRaised,
          margin: EdgeInsets.zero,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: const BorderSide(color: ResqColors.line),
          ),
        ),
      ),
      initialRoute: '/',
      routes: {
        '/': (context) => const SplashScreen(),
        '/onboarding': (context) => const OnboardingScreen(),
        '/home': (context) => const HomeScreen(),
        '/message_log': (context) => const MeshMonitorScreen(),
        '/research-monitor': (context) => const ResearchMonitorScreen(),
        '/permission': (context) => const PermissionScreen(),
      },
    );
  }
}

@pragma('vm:entry-point')
void backgroundServiceMain() {
  WidgetsFlutterBinding.ensureInitialized();

  const backgroundChannel = MethodChannel('id.ac.usu.resqmesh/mesh');
  final lastProcessedPayloads = <String, int>{};
  BleAdvertiserService().claimSchedulerOwnership();

  DatabaseHelper().database.then((_) async {
    await SyncService().initializeIdentity();
    await ExperimentLogger().ensureSession(deviceId: SyncService().deviceId);
    await ExperimentLogger().logEvent(
      eventType: ExperimentEventTypes.serviceStarted,
      deviceId: SyncService().deviceId,
      detail: {'entrypoint': 'background'},
    );
    SyncService().startSyncListener();
    await BleRelayService().start();
    await BleRelayService().recoverPersistedRelayState();
    await _drainNativeBleInbox();
  });

  backgroundChannel.setMethodCallHandler((call) async {
    switch (call.method) {
      case "bleWakeUpTriggered":
        debugPrint("[backgroundServiceMain] BLE wake-up triggered");
        break;
      case "connectivityChanged":
        debugPrint("[backgroundServiceMain] Connectivity changed");
        await WorkManagerService.registerSyncTask();
        break;
      case "recoverPersistedRelayState":
        debugPrint("[backgroundServiceMain] Recovering persisted relay state");
        await BleRelayService().recoverPersistedRelayState();
        break;
      case "schedulerTick":
        debugPrint("[backgroundServiceMain] Scheduler tick requested");
        await BleAdvertiserService().advertiseLatestOrStop(
          preemptCurrent: true,
        );
        break;
      case "environmentResumed":
        debugPrint("[backgroundServiceMain] Scheduler environment resumed");
        await NativeBridgeService.resumePendingNativeBleInbox();
        await BleAdvertiserService().resumeAfterEnvironmentChange();
        break;
      case "blePayloadReceived":
        final args = Map<String, dynamic>.from(call.arguments as Map);
        final payloadBase64 = args['payload'] as String?;
        final rssi = args['rssi'] as int?;
        final receivedAtMs = _asInt(args['received_at']);
        final receivedElapsedRealtimeMs = _asInt(
          args['received_elapsed_realtime_ms'],
        );
        final inboxId = args['inbox_id'] as String?;
        if (payloadBase64 == null || payloadBase64.isEmpty) return;

        final now = DateTime.now().millisecondsSinceEpoch;
        final last = lastProcessedPayloads[payloadBase64] ?? 0;
        if (now - last < 5000) {
          if (inboxId != null && inboxId.isNotEmpty) {
            await NativeBridgeService.acknowledgeBleInboxItem(inboxId);
          }
          return;
        }
        lastProcessedPayloads[payloadBase64] = now;
        if (lastProcessedPayloads.length > 50) {
          lastProcessedPayloads.clear();
        }

        try {
          final result = await BleRelayService().processIncomingBase64(
            payloadBase64,
            rssi: rssi,
            receivedAtMs: receivedAtMs,
            receivedElapsedRealtimeMs: receivedElapsedRealtimeMs,
          );
          if (inboxId != null && inboxId.isNotEmpty) {
            if (result.shouldAcknowledgeInbox) {
              await NativeBridgeService.acknowledgeBleInboxItem(inboxId);
            } else {
              await NativeBridgeService.failBleInboxItem(inboxId);
            }
          }
        } catch (_) {
          if (inboxId != null && inboxId.isNotEmpty) {
            await NativeBridgeService.failBleInboxItem(inboxId);
          }
          rethrow;
        }
        break;
      case "nativeBleInboxDrainRequested":
        final completed = await _drainNativeBleInbox();
        await backgroundChannel.invokeMethod('nativeBleInboxWorkerComplete', {
          'success': completed,
        });
        break;
      default:
        debugPrint("[backgroundServiceMain] Unknown method: ${call.method}");
    }
  });

  debugPrint("[backgroundServiceMain] BLE-only background service ready");
}

int? _asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

@pragma('vm:entry-point')
void nativeBleInboxWorkerMain() {
  WidgetsFlutterBinding.ensureInitialized();

  const workerChannel = MethodChannel('id.ac.usu.resqmesh/mesh');
  DatabaseHelper().database.then((_) async {
    await SyncService().initializeIdentity();
    await ExperimentLogger().ensureSession(deviceId: SyncService().deviceId);
    await ExperimentLogger().logEvent(
      eventType: ExperimentEventTypes.nativeInboxWorkerStarted,
      deviceId: SyncService().deviceId,
    );
    final completed = await _drainNativeBleInbox();
    final relayAttempted = await _attemptHeadlessRelayIfEligible();
    await ExperimentLogger().logEvent(
      eventType: ExperimentEventTypes.nativeInboxWorkerCompleted,
      deviceId: SyncService().deviceId,
      detail: {
        'inbox_completed': completed,
        'headless_relay_attempted': relayAttempted,
      },
    );
    await workerChannel.invokeMethod('nativeBleInboxWorkerComplete', {
      'success': completed,
    });
  });
}

Future<bool> _drainNativeBleInbox() async {
  final pending = await NativeBridgeService.getPendingBleInbox();
  return const NativeBleInboxDrainService().drain(
    items: pending,
    process: BleRelayService().processIncomingBase64,
    acknowledge: NativeBridgeService.acknowledgeBleInboxItem,
    fail: NativeBridgeService.failBleInboxItem,
  );
}

Future<bool> _attemptHeadlessRelayIfEligible() async {
  if (!await RelayQueueService().hasActiveItems()) {
    await NativeBridgeService.setHasPendingRelayWork(false);
    return false;
  }

  await ExperimentLogger().logEvent(
    eventType: ExperimentEventTypes.headlessRelayAttempted,
    deviceId: SyncService().deviceId,
  );
  final started = await BleAdvertiserService().advertiseOneHeadlessSlot();
  await ExperimentLogger().logEvent(
    eventType: started
        ? ExperimentEventTypes.headlessRelayStarted
        : ExperimentEventTypes.headlessRelayFailed,
    deviceId: SyncService().deviceId,
    detail: {'pending_relay_work': await RelayQueueService().hasActiveItems()},
  );
  return true;
}
