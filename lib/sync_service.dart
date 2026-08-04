import 'dart:async';

import 'package:battery_plus/battery_plus.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:pkmproject/config/mesh_config.dart';
import 'package:pkmproject/models/gateway_ack.dart';
import 'package:pkmproject/models/sos_message.dart';
import 'package:pkmproject/services/api_service.dart';
import 'package:pkmproject/services/ble_advertiser_service.dart';
import 'package:pkmproject/services/database_helper.dart';
import 'package:pkmproject/services/experiment_logger.dart';
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
  final ExperimentLogger _experimentLogger = ExperimentLogger();
  final Battery _battery = Battery();
  final _syncCompletedController = StreamController<void>.broadcast();

  Stream<void> get onSyncCompleted => _syncCompletedController.stream;

  StreamSubscription? _connectivitySubscription;
  Timer? _periodicSyncTimer;
  Duration _currentSyncInterval = const Duration(seconds: 15);
  DateTime? _serverBackoffUntil;
  int? gatewayDetectedAt;
  int? gatewayUploadStartedAt;
  int? gatewayUploadCompletedAt;
  bool _isSyncListening = false;
  String _deviceId = 'device-${Uuid().v4().substring(0, 8)}';
  String get deviceId => _deviceId;

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

    final backoffUntil = _serverBackoffUntil;
    if (backoffUntil != null && DateTime.now().isBefore(backoffUntil)) {
      print('[SyncService] Full sync skipped: server backoff is active');
      return;
    }

    print('[SyncService] Full sync initiated');
    await _uploadLatestLocalStates();
    if (_serverBackoffUntil != null) {
      await _bleAdvertiser.advertiseLatestOrStop();
      return;
    }
    await _downloadServerStates();
    await _bleAdvertiser.advertiseLatestOrStop();
    _syncCompletedController.add(null);
    print('[SyncService] Full sync completed');
  }

  Future<void> _uploadLatestLocalStates() async {
    final allLocalMessages = await _databaseHelper.getAllMessages();
    if (allLocalMessages.isEmpty) return;

    final latestByDevice = <String, SOSMessage>{};
    for (final message in allLocalMessages) {
      final key = message.senderCrc?.toString() ?? message.senderId;
      final existing = latestByDevice[key];
      if (existing == null || message.updatedAt > existing.updatedAt) {
        latestByDevice[key] = message;
      }
    }

    final messagesToSync = latestByDevice.values.toList();
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
            GatewayAck.fromJson(Map<String, dynamic>.from(rawAck as Map)),
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

      final ackData = _extractList(response['ack_data']);
      for (final rawAck in ackData) {
        await _processAckData(
          GatewayAck.fromJson(Map<String, dynamic>.from(rawAck as Map)),
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
    final localMessage = await _findLocalMessageForAck(
      senderCrc: ack.senderCrc,
      senderDeviceId: ack.senderDeviceId,
      localMessageId: ack.localMessageId,
    );

    if (localMessage == null) {
      await _bleAdvertiser.advertiseAckFor(
        senderCrc: ack.senderCrc,
        ackTimestampMs: ack.ackTimestampMs,
        status: ack.status,
      );
      return;
    }

    await _acceptAckForLocalMessage(
      localMessage,
      ack.ackTimestampMs,
      shouldBroadcastAck: true,
      ackStatus: ack.status,
    );
  }

  Future<void> _acceptAckForLocalMessage(
    SOSMessage localMessage,
    int ackTimestampMs, {
    required bool shouldBroadcastAck,
    SOSMessageStatus? ackStatus,
  }) async {
    final senderCrc = localMessage.senderCrc ?? crc32(localMessage.senderId);
    if (_isNotNewerThanAck(localMessage.updatedAt, ackTimestampMs)) {
      await _databaseHelper.updateAckStatus(localMessage.id, ackTimestampMs);
      await _bleAdvertiser.stopAdvertisingForMessage(localMessage.id);
      if (shouldBroadcastAck) {
        await _bleAdvertiser.advertiseAckFor(
          senderCrc: senderCrc,
          ackTimestampMs: ackTimestampMs,
          status:
              ackStatus ??
              (localMessage.status == SOSMessageStatus.cancelled
                  ? SOSMessageStatus.cancelled
                  : SOSMessageStatus.resolved),
        );
      }
      return;
    }

    await _bleAdvertiser.startAdvertising(sosMessage: localMessage);
    print('[SyncService] Ignored older ACK for ${localMessage.id}');
  }

  bool _isNotNewerThanAck(int localTimestampMs, int ackTimestampMs) {
    return localTimestampMs ~/ 1000 <= ackTimestampMs ~/ 1000;
  }

  Future<SOSMessage?> _findLocalMessageForAck({
    required int senderCrc,
    String? senderDeviceId,
    String? localMessageId,
  }) async {
    final allMessages = await _databaseHelper.getAllMessages();
    SOSMessage? latestMatch;
    for (final message in allMessages) {
      final idMatches = localMessageId != null && message.id == localMessageId;
      final crcMatches = message.senderCrc == senderCrc;
      final deviceMatches =
          senderDeviceId != null && message.senderId == senderDeviceId;
      if (!idMatches && !crcMatches && !deviceMatches) continue;

      if (latestMatch == null || message.updatedAt > latestMatch.updatedAt) {
        latestMatch = message;
      }
    }
    return latestMatch;
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
        initiateFullSync();
      }
    });

    _connectivitySubscription?.cancel();
    _connectivitySubscription = Connectivity().onConnectivityChanged.listen((
      results,
    ) async {
      final hasConnection = results.any((r) => r != ConnectivityResult.none);
      if (hasConnection && await checkInternetConnection()) {
        await initiateFullSync();
        await _updatePeriodicSyncTimer();
      } else {
        _periodicSyncTimer?.cancel();
      }
    });

    _updatePeriodicSyncTimer();
  }

  Future<void> _updatePeriodicSyncTimer() async {
    _periodicSyncTimer?.cancel();
    _currentSyncInterval = await _calculateAdaptiveSyncInterval();
    _periodicSyncTimer = Timer.periodic(_currentSyncInterval, (_) async {
      if (await checkInternetConnection()) {
        await initiateFullSync();
        final nextInterval = await _calculateAdaptiveSyncInterval();
        if (nextInterval != _currentSyncInterval) {
          await _updatePeriodicSyncTimer();
        }
      }
    });
  }

  Future<Duration> _calculateAdaptiveSyncInterval() async {
    try {
      final batteryLevel = await _battery.batteryLevel;
      final connectivity = await Connectivity().checkConnectivity();

      if (batteryLevel < 20) return const Duration(minutes: 5);
      if (batteryLevel < 50) {
        return connectivity.contains(ConnectivityResult.mobile)
            ? const Duration(minutes: 2)
            : const Duration(minutes: 1);
      }
      return connectivity.contains(ConnectivityResult.wifi)
          ? const Duration(seconds: 15)
          : const Duration(seconds: 30);
    } catch (_) {
      return const Duration(seconds: 30);
    }
  }

  List<dynamic> _extractList(dynamic value) {
    if (value is List) return value;
    return const [];
  }

  void dispose() {
    _connectivitySubscription?.cancel();
    _periodicSyncTimer?.cancel();
    _syncCompletedController.close();
  }
}
