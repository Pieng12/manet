import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:pkmproject/config/mesh_config.dart';
import 'package:pkmproject/models/ack_apply_result.dart';
import 'package:pkmproject/models/gateway_ack.dart';
import 'package:pkmproject/models/sos_message.dart';
import 'package:pkmproject/services/api_service.dart';
import 'package:pkmproject/services/ble_advertiser_service.dart';
import 'package:pkmproject/services/database_helper.dart';
import 'package:pkmproject/services/experiment_logger.dart';
import 'package:pkmproject/services/relay_queue_service.dart';
import 'package:pkmproject/services/workmanager_service.dart';
import 'package:pkmproject/utils/hash_utils.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

class SyncService {
  static final SyncService _instance = SyncService._internal();
  factory SyncService() => _instance;
  SyncService._internal();

  static bool get offlineOnly =>
      MeshConfig.resqMeshMode == ResqMeshMode.offline;
  static bool get gatewayMode =>
      MeshConfig.resqMeshMode == ResqMeshMode.gateway;

  final DatabaseHelper _databaseHelper = DatabaseHelper();
  final BleAdvertiserService _bleAdvertiser = BleAdvertiserService();
  final RelayQueueService _relayQueue = RelayQueueService();
  final ExperimentLogger _experimentLogger = ExperimentLogger();
  final _syncCompletedController = StreamController<void>.broadcast();

  Stream<void> get onSyncCompleted => _syncCompletedController.stream;

  StreamSubscription? _connectivitySubscription;
  DateTime? _serverBackoffUntil;
  int? gatewayDetectedAt;
  int? gatewayUploadStartedAt;
  int? gatewayUploadCompletedAt;
  bool _isSyncListening = false;
  bool _isSyncInProgress = false;
  String _deviceId = 'device-${Uuid().v4().substring(0, 8)}';
  String get deviceId => _deviceId;

  static bool isServerBackoffActive(DateTime? backoffUntil, DateTime now) {
    return backoffUntil != null && now.isBefore(backoffUntil);
  }

  static DateTime? clearBackoffIfElapsed(DateTime? backoffUntil, DateTime now) {
    if (backoffUntil == null || !now.isBefore(backoffUntil)) return null;
    return backoffUntil;
  }

  static List<SOSMessage> filterGatewayUploadCandidates(
    Iterable<SOSMessage> messages, {
    required int nowMs,
  }) {
    final latestByDevice = <String, SOSMessage>{};
    for (final message in messages) {
      if (message.isSynced != 0 ||
          message.ackReceivedAt != null ||
          message.fromServer ||
          message.localState == 'acked' ||
          message.localState == 'synced') {
        continue;
      }

      final key = message.senderCrc?.toString() ?? message.senderId;
      final existing = latestByDevice[key];
      if (existing == null || message.updatedAt > existing.updatedAt) {
        latestByDevice[key] = message;
      }
    }
    return latestByDevice.values.toList();
  }

  Future<void> initializeIdentity() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString('sync_device_id');
      if (stored != null && stored.isNotEmpty) {
        _deviceId = stored;
        return;
      }

      _deviceId = 'device-${Uuid().v4().substring(0, 8)}';
      await prefs.setString('sync_device_id', _deviceId);
    } catch (_) {
      // Keep the generated fallback id.
    }
  }

  Future<bool> checkInternetConnection() async {
    final result = await Connectivity().checkConnectivity();
    return result.any((item) => item != ConnectivityResult.none);
  }

  Future<bool> checkGatewayAvailability() async {
    if (!gatewayMode) return false;
    if (!await checkInternetConnection()) return false;
    final reachable = await ApiService.ping();
    if (reachable) {
      gatewayDetectedAt = DateTime.now().millisecondsSinceEpoch;
      await _experimentLogger.logEvent(
        eventType: ExperimentEventTypes.gatewayDetected,
        deviceId: _deviceId,
      );
    }
    return reachable;
  }

  Future<void> initiateFullSync() async {
    if (_isSyncInProgress) {
      print('[SyncService] Full sync skipped: another sync is running.');
      return;
    }
    _isSyncInProgress = true;
    try {
      if (offlineOnly) {
        print('[SyncService] Offline-only mode active. Server sync skipped.');
        await _bleAdvertiser.advertiseLatestOrStop();
        return;
      }

      if (!await checkGatewayAvailability()) {
        print('[SyncService] Gateway unavailable. Server sync skipped.');
        await _bleAdvertiser.advertiseLatestOrStop();
        return;
      }

      final now = DateTime.now();
      _serverBackoffUntil = clearBackoffIfElapsed(_serverBackoffUntil, now);
      if (isServerBackoffActive(_serverBackoffUntil, now)) {
        print('[SyncService] Upload skipped: server backoff is active');
      }

      print('[SyncService] Full sync initiated');
      if (_serverBackoffUntil == null) {
        await _uploadLatestLocalStates();
      }
      await _downloadServerStates();
      await _bleAdvertiser.advertiseLatestOrStop();
      _syncCompletedController.add(null);
      print('[SyncService] Full sync completed');
    } finally {
      _isSyncInProgress = false;
    }
  }

  Future<void> _uploadLatestLocalStates() async {
    final allLocalMessages = await _databaseHelper.getGatewayUploadCandidates();
    if (allLocalMessages.isEmpty) return;

    final messagesToSync = filterGatewayUploadCandidates(
      allLocalMessages,
      nowMs: DateTime.now().millisecondsSinceEpoch,
    );
    if (messagesToSync.isEmpty) return;

    try {
      gatewayUploadStartedAt = DateTime.now().millisecondsSinceEpoch;
      await _experimentLogger.logEvent(
        eventType: ExperimentEventTypes.gatewayUploadStarted,
        deviceId: _deviceId,
        detail: {'message_count': messagesToSync.length},
      );
      final response = await ApiService.uploadData(
        messagesToSync.map((message) => message.toApiJson()).toList(),
      );
      _serverBackoffUntil = null;
      gatewayUploadCompletedAt = DateTime.now().millisecondsSinceEpoch;
      await _experimentLogger.logEvent(
        eventType: ExperimentEventTypes.gatewayUploadSucceeded,
        deviceId: _deviceId,
        detail: {
          'message_count': messagesToSync.length,
          'latency_ms': gatewayUploadCompletedAt! - gatewayUploadStartedAt!,
        },
      );

      final ackData = _extractList(response['ack_data']);
      if (ackData.isNotEmpty) {
        for (final rawAck in ackData) {
          await _processAckData(
            GatewayAck.fromJson(
              Map<String, dynamic>.from(rawAck as Map),
              nowMs: DateTime.now().millisecondsSinceEpoch,
            ),
          );
        }
        return;
      }

      if (response['acknowledged'] == true ||
          response.containsKey('processed_ids')) {
        for (final message in messagesToSync) {
          await _acceptAckForLocalMessage(
            message,
            message.updatedAt,
            shouldBroadcastAck: true,
          );
        }
      }
    } catch (e) {
      await _experimentLogger.logEvent(
        eventType: ExperimentEventTypes.gatewayUploadFailed,
        deviceId: _deviceId,
        detail: {'error': e.toString()},
      );
      print('[SyncService] Upload failed: $e');
      _applyServerBackoffIfNeeded(e);
    }
  }

  Future<void> _downloadServerStates() async {
    final since = await _databaseHelper.getLastSyncTimestamp();

    try {
      final response = await ApiService.downloadData(since);
      _serverBackoffUntil = null;

      final ackData = _extractList(response['ack_data']);
      for (final rawAck in ackData) {
        await _processAckData(
          GatewayAck.fromJson(
            Map<String, dynamic>.from(rawAck as Map),
            nowMs: DateTime.now().millisecondsSinceEpoch,
          ),
        );
      }

      final messages = _extractList(response['messages']);
      for (final rawMessage in messages) {
        final message = SOSMessage.fromApiJson(
          Map<String, dynamic>.from(rawMessage as Map),
        );
        if (await _databaseHelper.isMessageNewer(message)) {
          await _databaseHelper.replaceWithLatestMessage(message);
        }
      }
    } catch (e) {
      print('[SyncService] Download failed: $e');
      _applyServerBackoffIfNeeded(e);
    }
  }

  void _applyServerBackoffIfNeeded(Object error) {
    final isBackendNotFound =
        error is ApiException && error.isNotFound ||
        error.toString().contains('Status: 404');

    if (!isBackendNotFound) return;

    _serverBackoffUntil = DateTime.now().add(const Duration(minutes: 5));
    print(
      '[SyncService] Backend endpoint not found. Sync paused for 5 minutes.',
    );
  }

  Future<void> _processAckData(GatewayAck ack) async {
    final result = await _relayQueue.acceptAndQueueAck(
      senderCrc: ack.senderCrc,
      ackTimestampMs: ack.ackTimestampMs,
      status: ack.status,
      nowMs: DateTime.now().millisecondsSinceEpoch,
    );
    if (result.shouldRelay) {
      await _bleAdvertiser.advertiseLatestOrStop(preemptCurrent: true);
    }
  }

  Future<void> _acceptAckForLocalMessage(
    SOSMessage localMessage,
    int ackTimestampMs, {
    required bool shouldBroadcastAck,
    SOSMessageStatus? ackStatus,
  }) async {
    localMessage.senderCrc ??= crc32(localMessage.senderId);
    final result = await _relayQueue.acceptAndQueueAck(
      senderCrc: localMessage.senderCrc!,
      ackTimestampMs: ackTimestampMs,
      status:
          ackStatus ??
          (localMessage.status == SOSMessageStatus.cancelled
              ? SOSMessageStatus.cancelled
              : SOSMessageStatus.resolved),
      nowMs: DateTime.now().millisecondsSinceEpoch,
    );
    if (result.shouldRelay && shouldBroadcastAck) {
      await _bleAdvertiser.advertiseLatestOrStop(preemptCurrent: true);
    }
  }

  void startSyncListener() {
    if (offlineOnly) {
      print('[SyncService] Offline-only mode active. Sync listener disabled.');
      return;
    }

    if (_isSyncListening) return;
    _isSyncListening = true;

    checkInternetConnection().then((hasInternet) {
      if (hasInternet) {
        WorkManagerService.registerSyncTask();
      }
    });

    _connectivitySubscription?.cancel();
    _connectivitySubscription = Connectivity().onConnectivityChanged.listen((
      results,
    ) async {
      final hasConnection = results.any((r) => r != ConnectivityResult.none);
      if (hasConnection && await checkInternetConnection()) {
        await WorkManagerService.registerSyncTask();
      }
    });
  }

  List<dynamic> _extractList(dynamic value) {
    if (value is List) return value;
    return const [];
  }

  void dispose() {
    _connectivitySubscription?.cancel();
    _syncCompletedController.close();
  }
}
