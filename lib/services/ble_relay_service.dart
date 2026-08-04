import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:pkmproject/config/mesh_config.dart';
import 'package:pkmproject/models/forwarding_decision.dart';
import 'package:pkmproject/models/sos_message.dart';
import 'package:pkmproject/services/background_service_manager.dart';
import 'package:pkmproject/services/ble_advertiser_service.dart';
import 'package:pkmproject/services/ble_protocol.dart';
import 'package:pkmproject/services/database_helper.dart';
import 'package:pkmproject/services/experiment_logger.dart';
import 'package:pkmproject/services/forwarding_policy.dart';
import 'package:pkmproject/services/native_bridge_service.dart';
import 'package:pkmproject/services/relay_queue_service.dart';
import 'package:pkmproject/services/workmanager_service.dart';
import 'package:pkmproject/sync_service.dart';
import 'package:pkmproject/utils/hash_utils.dart';

class BleRelayService {
  static final BleRelayService _instance = BleRelayService._internal();
  factory BleRelayService() => _instance;
  BleRelayService._internal();

  final DatabaseHelper _dbHelper = DatabaseHelper();
  final BleAdvertiserService _advertiser = BleAdvertiserService();
  final ForwardingPolicy _forwardingPolicy = const ForwardingPolicy();
  final RelayQueueService _relayQueue = RelayQueueService();
  final ExperimentLogger _experimentLogger = ExperimentLogger();
  final _logController = StreamController<String>.broadcast();

  Stream<String> get logStream => _logController.stream;

  static int sosExpiresAt(BlePacket packet) {
    return 0x7FFFFFFFFFFFFFFF;
  }

  static bool isSosPacketExpired(BlePacket packet, int nowMs) {
    return false;
  }

  static bool canRelaySosPacket(BlePacket packet, int nowMs) {
    final decision = const ForwardingPolicy().decideSos(
      packet: packet,
      nowMs: nowMs,
    );
    return decision.shouldRelay;
  }

  static int ackExpiresAt(BlePacket packet) {
    return 0x7FFFFFFFFFFFFFFF;
  }

  static bool isAckPacketExpired(BlePacket packet, int nowMs) {
    return false;
  }

  static bool canRelayAckPacket(BlePacket packet, int nowMs) {
    return packet.isAck;
  }

  static SOSMessage messageFromSosPacket(BlePacket packet, int receivedAtMs) {
    final expiresAt = sosExpiresAt(packet);
    final nextHopCount = packet.hopCount >= MeshConfig.maxProtocolHop
        ? MeshConfig.maxProtocolHop
        : packet.hopCount + 1;

    return SOSMessage(
      id: 'ble-${packet.senderCrc}-${packet.timestampMs}',
      senderId: 'ble-device-${packet.senderCrc}',
      senderCrc: packet.senderCrc,
      fromServer: packet.fromServer,
      senderName: 'BLE Node',
      content: 'SOS from BLE advertising',
      latitude: packet.latitude ?? 0,
      longitude: packet.longitude ?? 0,
      status: packet.status,
      createdAt: packet.timestampMs,
      updatedAt: packet.timestampMs,
      isSynced: packet.fromServer ? 1 : 0,
      hopCount: nextHopCount,
      maxHop: MeshConfig.defaultMaxHop,
      expiresAt: expiresAt,
      firstSeenAt: receivedAtMs,
      localState: 'pending',
    );
  }

  Future<void> start() async {
    await BackgroundServiceManager.startBackgroundService();
    await NativeBridgeService.startBleWakeUpScan();
    await _advertiser.flushPendingAck();
    _log('BLE relay started');
  }

  Future<void> recoverPersistedRelayState() async {
    await NativeBridgeService.startBleWakeUpScan();
    await _advertiser.advertiseLatestOrStop();
    await _experimentLogger.logEvent(
      eventType: ExperimentEventTypes.relayStateRecovered,
      deviceId: SyncService().deviceId,
    );
    _log('Recovered persisted relay state');
  }

  Future<void> stop() async {
    await NativeBridgeService.stopBleWakeUpScan();
    await _advertiser.stopAdvertising();
    await _experimentLogger.logEvent(
      eventType: ExperimentEventTypes.serviceStopped,
      deviceId: SyncService().deviceId,
    );
    _log('BLE relay stopped');
  }

  Future<void> activateForMessage(SOSMessage message) async {
    await _dbHelper.replaceWithLatestMessage(message);
    await start();
    await _advertiser.enqueueSosForAdvertising(
      message,
      nextEligibleAt: DateTime.now().millisecondsSinceEpoch,
      preemptCurrent: true,
    );
    await WorkManagerService.registerSyncTask();
    await _tryGatewaySync();
  }

  Future<void> processIncomingBase64(String payloadBase64, {int? rssi}) async {
    try {
      final payload = base64Decode(payloadBase64);
      await processIncomingPayload(Uint8List.fromList(payload), rssi: rssi);
    } catch (e) {
      _log('Invalid BLE payload: $e');
    }
  }

  Future<void> processIncomingPayload(Uint8List payload, {int? rssi}) async {
    final packet = BlePacket.unpack(payload);
    if (packet == null) {
      _log('Ignored non-ResQMesh BLE packet: ${_hex(payload)}');
      return;
    }

    _log('Received BLE payload ${_hex(payload)} -> ${_describePacket(packet)}');
    await _experimentLogger.logEvent(
      eventType: ExperimentEventTypes.blePacketReceived,
      deviceId: SyncService().deviceId,
      senderCrc: packet.senderCrc,
      hopCount: packet.hopCount,
      rssi: rssi,
      payloadHash: packet.identity,
      detail: {'kind': packet.kind.name, 'status': packet.status.name},
    );

    if (packet.isAck) {
      await _processAck(packet, rssi: rssi);
    } else {
      await _processSos(packet, rssi: rssi);
    }
  }

  Future<bool> applyAck({
    required int senderCrc,
    required int ackTimestampMs,
    SOSMessageStatus status = SOSMessageStatus.resolved,
    bool relayAck = true,
  }) async {
    final allMessages = await _dbHelper.getAllMessages();
    SOSMessage? latest;
    for (final message in allMessages) {
      if (message.senderCrc == senderCrc) {
        if (latest == null || message.updatedAt > latest.updatedAt) {
          latest = message;
        }
      }
    }

    if (latest == null) {
      if (relayAck) {
        await _advertiser.advertiseAckFor(
          senderCrc: senderCrc,
          ackTimestampMs: ackTimestampMs,
          status: status,
        );
      }
      _log('Relaying ACK for unknown sender CRC $senderCrc');
      return false;
    }

    if (_isNotNewerThanAck(latest.updatedAt, ackTimestampMs)) {
      await _dbHelper.updateAckStatus(latest.id, ackTimestampMs);
      await _relayQueue.removeMessage(latest.id);
      await _advertiser.stopAdvertisingForMessage(latest.id);
      await _experimentLogger.logEvent(
        eventType: ExperimentEventTypes.ackAccepted,
        deviceId: SyncService().deviceId,
        messageId: latest.id,
        senderCrc: senderCrc,
        detail: {'ack_timestamp_ms': ackTimestampMs},
      );
      if (relayAck) {
        await _advertiser.advertiseAckFor(
          senderCrc: senderCrc,
          ackTimestampMs: ackTimestampMs,
          status: status,
        );
      }
      _log('ACK accepted for ${latest.id}');
      return true;
    }

    await _advertiser.enqueueSosForAdvertising(
      latest,
      nextEligibleAt: DateTime.now().millisecondsSinceEpoch,
      preemptCurrent: true,
    );
    _log(
      'ACK ignored for sender CRC $senderCrc because local message is newer',
    );
    return false;
  }

  bool _isNotNewerThanAck(int localTimestampMs, int ackTimestampMs) {
    return localTimestampMs ~/ 1000 <= ackTimestampMs ~/ 1000;
  }

  Future<void> _processAck(BlePacket packet, {int? rssi}) async {
    await _experimentLogger.logEvent(
      eventType: ExperimentEventTypes.ackReceived,
      deviceId: SyncService().deviceId,
      senderCrc: packet.senderCrc,
      hopCount: packet.hopCount,
      rssi: rssi,
      payloadHash: packet.identity,
    );
    final ackQueueId = RelayQueueService.ackMessageId(
      senderCrc: packet.senderCrc,
      ackTimestampMs: packet.timestampMs,
      statusIndex: packet.status.index,
    );
    final alreadyQueued = await _relayQueue.getItem(ackQueueId, 'ack') != null;

    await applyAck(
      senderCrc: packet.senderCrc,
      ackTimestampMs: packet.timestampMs,
      status: packet.status,
      relayAck: false,
    );

    if (alreadyQueued) {
      await _experimentLogger.logEvent(
        eventType: ExperimentEventTypes.blePacketDuplicate,
        deviceId: SyncService().deviceId,
        senderCrc: packet.senderCrc,
        hopCount: packet.hopCount,
        rssi: rssi,
        payloadHash: packet.identity,
        detail: {'kind': 'ack'},
      );
      _log('ACK_DUPLICATE ${packet.identity}');
      return;
    }

    await _advertiser.advertiseAckFor(
      senderCrc: packet.senderCrc,
      ackTimestampMs: packet.timestampMs,
      status: packet.status,
      hopCount: packet.hopCount >= MeshConfig.maxProtocolHop
          ? MeshConfig.maxProtocolHop
          : packet.hopCount + 1,
    );
    final nextAckHop = packet.hopCount >= MeshConfig.maxProtocolHop
        ? MeshConfig.maxProtocolHop
        : packet.hopCount + 1;
    await _experimentLogger.logEvent(
      eventType: ExperimentEventTypes.bleRelayQueued,
      deviceId: SyncService().deviceId,
      senderCrc: packet.senderCrc,
      hopCount: nextAckHop,
      rssi: rssi,
      payloadHash: packet.identity,
      detail: {'kind': 'ack'},
    );
    _log('ACK_RELAY_QUEUED ${packet.identity} hop=$nextAckHop');
  }

  Future<void> _processSos(BlePacket packet, {int? rssi}) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final message = messageFromSosPacket(packet, now);
    final existing = await _dbHelper.getLatestMessageForSender(
      senderId: message.senderId,
      senderCrc: message.senderCrc,
    );
    final decision = _forwardingPolicy.decideSos(
      packet: packet,
      nowMs: now,
      existingMessage: existing,
      ownSenderCrc: crc32(SyncService().deviceId),
    );

    if (!decision.shouldStore) {
      if (decision.reason == ForwardingDecisionReason.dropDuplicate &&
          existing != null) {
        await _dbHelper.incrementDuplicateCount(existing.id);
        await _experimentLogger.logEvent(
          eventType: ExperimentEventTypes.blePacketDuplicate,
          deviceId: SyncService().deviceId,
          messageId: existing.id,
          senderCrc: packet.senderCrc,
          hopCount: packet.hopCount,
          rssi: rssi,
          payloadHash: packet.identity,
        );
      }
      await _experimentLogger.logEvent(
        eventType: ExperimentEventTypes.bleRelayDropped,
        deviceId: SyncService().deviceId,
        messageId: existing?.id,
        senderCrc: packet.senderCrc,
        hopCount: packet.hopCount,
        rssi: rssi,
        payloadHash: packet.identity,
        detail: {'reason': decision.reason.code},
      );
      _log('${decision.reason.code} ${packet.identity}');
      return;
    }

    message.hopCount = decision.nextHopCount ?? message.hopCount;
    if (decision.shouldRelay ||
        decision.reason == ForwardingDecisionReason.dropCooldown) {
      message.localState = 'queued';
    }
    if (existing != null) {
      message.relayCount = existing.relayCount;
      message.duplicateCount = existing.duplicateCount;
      message.lastRelayedAt = existing.lastRelayedAt;
    }

    await _dbHelper.replaceWithLatestMessage(message);
    await _experimentLogger.logEvent(
      eventType: ExperimentEventTypes.blePacketStored,
      deviceId: SyncService().deviceId,
      messageId: message.id,
      senderCrc: message.senderCrc,
      hopCount: message.hopCount,
      rssi: rssi,
      payloadHash: packet.identity,
      detail: {'local_state': message.localState},
    );
    await WorkManagerService.registerSyncTask();

    if (decision.reason == ForwardingDecisionReason.dropCooldown &&
        decision.nextEligibleAt != null) {
      await _relayQueue.enqueueSos(
        message,
        nextEligibleAt: decision.nextEligibleAt,
      );
      await _experimentLogger.logEvent(
        eventType: ExperimentEventTypes.bleRelayQueued,
        deviceId: SyncService().deviceId,
        messageId: message.id,
        senderCrc: message.senderCrc,
        hopCount: message.hopCount,
        rssi: rssi,
        payloadHash: packet.identity,
        detail: {'deferred': true, 'next_eligible_at': decision.nextEligibleAt},
      );
      await _advertiser.advertiseLatestOrStop();
      _log('${decision.reason.code} ${packet.identity}');
      await _tryGatewaySync();
      return;
    }

    if (!decision.shouldRelay) {
      await _experimentLogger.logEvent(
        eventType: ExperimentEventTypes.bleRelayDropped,
        deviceId: SyncService().deviceId,
        messageId: message.id,
        senderCrc: packet.senderCrc,
        hopCount: packet.hopCount,
        rssi: rssi,
        payloadHash: packet.identity,
        detail: {'reason': decision.reason.code},
      );
      _log('${decision.reason.code} ${packet.identity}');
      await _tryGatewaySync();
      return;
    }

    await _relayQueue.enqueueSos(
      message,
      nextEligibleAt: _relayQueue.sosCooldownEligibleAt(
        now,
        relayCount: message.relayCount,
      ),
    );
    await _experimentLogger.logEvent(
      eventType: ExperimentEventTypes.bleRelayQueued,
      deviceId: SyncService().deviceId,
      messageId: message.id,
      senderCrc: message.senderCrc,
      hopCount: message.hopCount,
      rssi: rssi,
      payloadHash: packet.identity,
    );
    await _advertiser.advertiseLatestOrStop();
    _log('${decision.reason.code} ${packet.identity} hop=${message.hopCount}');
    await _tryGatewaySync();
  }

  Future<void> _tryGatewaySync() async {
    if (SyncService.offlineOnly) {
      _log('Offline-only mode active. Gateway sync skipped.');
      return;
    }

    try {
      final connectivity = await Connectivity().checkConnectivity();
      final hasInternet = connectivity.any(
        (result) => result != ConnectivityResult.none,
      );
      if (!hasInternet) return;

      await SyncService().initiateFullSync();
    } catch (e) {
      _log('Gateway sync skipped/failed: $e');
    }
  }

  void _log(String message) {
    print('[BleRelayService] $message');
    if (!_logController.isClosed) {
      _logController.add(message);
    }
  }

  String _hex(Uint8List payload) {
    return payload.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  }

  String _describePacket(BlePacket packet) {
    final type = packet.isAck ? 'ACK' : 'SOS';
    final lat = packet.latitude?.toStringAsFixed(5) ?? '-';
    final lon = packet.longitude?.toStringAsFixed(5) ?? '-';
    return '$type crc=${packet.senderCrc} status=${packet.status.name} '
        'lat=$lat lon=$lon hop=${packet.hopCount}';
  }

  void dispose() {
    _logController.close();
  }
}
