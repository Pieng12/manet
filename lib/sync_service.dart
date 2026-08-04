import 'dart:async';

import 'package:battery_plus/battery_plus.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:pkmproject/models/sos_message.dart';
import 'package:pkmproject/services/api_service.dart';
import 'package:pkmproject/services/ble_advertiser_service.dart';
import 'package:pkmproject/services/database_helper.dart';
import 'package:pkmproject/utils/hash_utils.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

class SyncService {
  static final SyncService _instance = SyncService._internal();
  factory SyncService() => _instance;
  SyncService._internal();

  static const bool offlineOnly = bool.fromEnvironment(
    'RESQMESH_OFFLINE_ONLY',
    defaultValue: true,
  );

  final DatabaseHelper _databaseHelper = DatabaseHelper();
  final BleAdvertiserService _bleAdvertiser = BleAdvertiserService();
  final Battery _battery = Battery();
  final _syncCompletedController = StreamController<void>.broadcast();

  Stream<void> get onSyncCompleted => _syncCompletedController.stream;

  StreamSubscription? _connectivitySubscription;
  Timer? _periodicSyncTimer;
  Duration _currentSyncInterval = const Duration(seconds: 15);
  DateTime? _serverBackoffUntil;
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

  Future<void> initiateFullSync() async {
    if (offlineOnly) {
      print('[SyncService] Offline-only mode active. Server sync skipped.');
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
      final response = await ApiService.uploadData(
        messagesToSync.map((message) => message.toApiJson()).toList(),
      );

      final ackData = _extractList(response['ack_data']);
      if (ackData.isNotEmpty) {
        for (final rawAck in ackData) {
          await _processAckData(Map<String, dynamic>.from(rawAck as Map));
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
        await _processAckData(Map<String, dynamic>.from(rawAck as Map));
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

  Future<void> _processAckData(Map<String, dynamic> ackData) async {
    final senderDeviceId = (ackData['sender_device_id'] ?? ackData['device_id'])
        ?.toString();
    final localMessageId =
        (ackData['local_message_id'] ?? ackData['message_id'])?.toString();
    final senderCrc =
        _intFrom(ackData['sender_crc']) ??
        (senderDeviceId == null ? null : crc32(senderDeviceId));
    final ackTimestamp = _timestampFrom(
      ackData['occurred_at'] ??
          ackData['updated_at'] ??
          ackData['ack_timestamp'] ??
          ackData['timestamp'],
    );

    if (senderCrc == null || ackTimestamp == null) return;

    final localMessage = await _findLocalMessageForAck(
      senderCrc: senderCrc,
      senderDeviceId: senderDeviceId,
      localMessageId: localMessageId,
    );

    if (localMessage == null) {
      await _bleAdvertiser.advertiseAckFor(
        senderCrc: senderCrc,
        ackTimestampMs: ackTimestamp,
      );
      return;
    }

    await _acceptAckForLocalMessage(
      localMessage,
      ackTimestamp,
      shouldBroadcastAck: true,
    );
  }

  Future<void> _acceptAckForLocalMessage(
    SOSMessage localMessage,
    int ackTimestampMs, {
    required bool shouldBroadcastAck,
  }) async {
    final senderCrc = localMessage.senderCrc ?? crc32(localMessage.senderId);
    if (_isNotNewerThanAck(localMessage.updatedAt, ackTimestampMs)) {
      await _databaseHelper.updateSyncStatus(localMessage.id);
      await _bleAdvertiser.stopAdvertisingForMessage(localMessage.id);
      if (shouldBroadcastAck) {
        await _bleAdvertiser.advertiseAckFor(
          senderCrc: senderCrc,
          ackTimestampMs: ackTimestampMs,
          status: localMessage.status == SOSMessageStatus.cancelled
              ? SOSMessageStatus.cancelled
              : SOSMessageStatus.resolved,
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

  int? _intFrom(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '');
  }

  int? _timestampFrom(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is num) return value.toInt();
    return DateTime.tryParse(value.toString())?.millisecondsSinceEpoch;
  }

  void dispose() {
    _connectivitySubscription?.cancel();
    _periodicSyncTimer?.cancel();
    _syncCompletedController.close();
  }
}
