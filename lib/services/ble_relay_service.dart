import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:pkmproject/config/mesh_config.dart';
import 'package:pkmproject/models/ack_apply_result.dart';
import 'package:pkmproject/models/ble_processing_result.dart';
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
import 'package:pkmproject/utils/protocol_timestamp.dart';
import 'package:pkmproject/utils/sos_status_priority.dart';

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
    final timestampMs = canonicalProtocolTimestamp(packet.timestampMs);
    final nextHopCount = packet.hopCount >= MeshConfig.maxProtocolHop
        ? MeshConfig.maxProtocolHop
        : packet.hopCount + 1;

    return SOSMessage(
      id: 'ble-${packet.senderCrc}-$timestampMs',
      senderId: 'ble-device-${packet.senderCrc}',
      senderCrc: packet.senderCrc,
      fromServer: packet.fromServer,
      senderName: 'BLE Node',
      content: 'SOS from BLE advertising',
      latitude: packet.latitude ?? 0,
      longitude: packet.longitude ?? 0,
      status: packet.status,
      createdAt: timestampMs,
      updatedAt: timestampMs,
      isSynced: packet.fromServer ? 1 : 0,
      hopCount: nextHopCount,
      maxHop: MeshConfig.legacyHopMetadata,
      expiresAt: expiresAt,
      firstSeenAt: receivedAtMs,
      localState: 'pending',
    );
  }

  Future<void> start() async {
    await BackgroundServiceManager.startBackgroundService();
    await NativeBridgeService.startBleWakeUpScan();
    await _recoverQueues();
    await _advertiser.flushPendingAck();
    _log('BLE relay started');
  }

  Future<void> recoverPersistedRelayState() async {
    await NativeBridgeService.startBleWakeUpScan();
    await _recoverQueues();
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
    await _dbHelper.ensureMonotonicStateTimestamp(message);
    await start();
    await _advertiser.enqueueSosForAdvertising(
      message,
      nextEligibleAt: DateTime.now().millisecondsSinceEpoch,
      preemptCurrent: true,
    );
    await WorkManagerService.registerSyncTask();
    await _tryGatewaySync();
  }

  Future<BleProcessingResult> processIncomingBase64(
    String payloadBase64, {
    int? rssi,
  }) async {
    try {
      final payload = base64Decode(payloadBase64);
      return processIncomingPayload(Uint8List.fromList(payload), rssi: rssi);
    } on FormatException catch (e) {
      _log('Invalid BLE payload: $e');
      return BleProcessingResult.invalid;
    }
  }

  Future<BleProcessingResult> processIncomingPayload(
    Uint8List payload, {
    int? rssi,
  }) async {
    final packet = BlePacket.unpack(payload);
    if (packet == null) {
      _log('Ignored non-ResQMesh BLE packet: ${_hex(payload)}');
      return BleProcessingResult.invalid;
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

    try {
      if (packet.isAck) {
        return await _processAck(packet, rssi: rssi);
      } else {
        return await _processSos(packet, rssi: rssi);
      }
    } catch (e) {
      _log('Retryable BLE processing failure for ${packet.identity}: $e');
      return BleProcessingResult.failedRetryable;
    }
  }

  Future<bool> applyAck({
    required int senderCrc,
    required int ackTimestampMs,
    SOSMessageStatus status = SOSMessageStatus.resolved,
    bool relayAck = true,
  }) async {
    final result = await _relayQueue.acceptAndQueueAck(
      senderCrc: senderCrc,
      ackTimestampMs: ackTimestampMs,
      status: status,
      nowMs: DateTime.now().millisecondsSinceEpoch,
    );
    if (result.shouldRelay && relayAck) {
      await _advertiser.advertiseLatestOrStop(preemptCurrent: true);
    }
    await _logAckResult(
      result,
      senderCrc: senderCrc,
      ackTimestampMs: ackTimestampMs,
      status: status,
    );
    return result.shouldRelay;
  }

  bool _isNewerState(SOSMessage incoming, SOSMessage? existing) {
    if (existing == null) return true;
    if (incoming.updatedAt > existing.updatedAt) return true;
    if (incoming.updatedAt < existing.updatedAt) return false;
    return sosStatusPriority(incoming.status) >
        sosStatusPriority(existing.status);
  }

  Future<BleProcessingResult> _processAck(BlePacket packet, {int? rssi}) async {
    if (packet.status == SOSMessageStatus.active) {
      await _experimentLogger.logEvent(
        eventType: ExperimentEventTypes.bleRelayDropped,
        deviceId: SyncService().deviceId,
        senderCrc: packet.senderCrc,
        hopCount: packet.hopCount,
        rssi: rssi,
        payloadHash: packet.identity,
        detail: {'reason': 'ACK_ACTIVE_REJECTED'},
      );
      _log('ACK_ACTIVE_REJECTED ${packet.identity}');
      return BleProcessingResult.invalid;
    }

    await _experimentLogger.logEvent(
      eventType: ExperimentEventTypes.ackReceived,
      deviceId: SyncService().deviceId,
      senderCrc: packet.senderCrc,
      hopCount: packet.hopCount,
      rssi: rssi,
      payloadHash: packet.identity,
    );
    final AckApplyResult result;
    try {
      result = await _relayQueue.acceptAndQueueAck(
        senderCrc: packet.senderCrc,
        ackTimestampMs: packet.timestampMs,
        status: packet.status,
        hopCount: packet.hopCount >= MeshConfig.maxProtocolHop
            ? MeshConfig.maxProtocolHop
            : packet.hopCount + 1,
        nowMs: DateTime.now().millisecondsSinceEpoch,
      );
    } catch (e) {
      await _experimentLogger.logEvent(
        eventType: ExperimentEventTypes.ackTransactionRolledBack,
        deviceId: SyncService().deviceId,
        senderCrc: packet.senderCrc,
        rssi: rssi,
        payloadHash: packet.identity,
        detail: {'error': e.toString()},
      );
      rethrow;
    }
    await _logAckResult(
      result,
      senderCrc: packet.senderCrc,
      ackTimestampMs: packet.timestampMs,
      status: packet.status,
      rssi: rssi,
      payloadHash: packet.identity,
    );

    if (!result.shouldRelay) {
      await _experimentLogger.logEvent(
        eventType: ExperimentEventTypes.blePacketDuplicate,
        deviceId: SyncService().deviceId,
        senderCrc: packet.senderCrc,
        hopCount: packet.hopCount,
        rssi: rssi,
        payloadHash: packet.identity,
        detail: {'kind': 'ack'},
      );
      _log('${result.name.toUpperCase()} ${packet.identity}');
      return switch (result) {
        AckApplyResult.duplicate => BleProcessingResult.duplicate,
        AckApplyResult.rejectedOlder => BleProcessingResult.stale,
        AckApplyResult.rejectedInvalid ||
        AckApplyResult.rejectedFuture => BleProcessingResult.invalid,
        _ => BleProcessingResult.duplicate,
      };
    }

    await _advertiser.advertiseLatestOrStop(preemptCurrent: true);
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
    return BleProcessingResult.accepted;
  }

  Future<BleProcessingResult> _processSos(BlePacket packet, {int? rssi}) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final suppressedByAck = await _dbHelper.isSuppressedByAckTombstone(
      senderCrc: packet.senderCrc,
      sosTimestampMs: packet.timestampMs,
    );
    if (suppressedByAck) {
      await _experimentLogger.logEvent(
        eventType: ExperimentEventTypes.bleRelayDropped,
        deviceId: SyncService().deviceId,
        senderCrc: packet.senderCrc,
        hopCount: packet.hopCount,
        rssi: rssi,
        payloadHash: packet.identity,
        detail: {'reason': 'ACK_TOMBSTONE_SUPPRESSED'},
      );
      _log('ACK_TOMBSTONE_SUPPRESSED ${packet.identity}');
      return BleProcessingResult.suppressedByAck;
    }

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
      return switch (decision.reason) {
        ForwardingDecisionReason.dropInvalid => BleProcessingResult.invalid,
        ForwardingDecisionReason.dropAcked =>
          BleProcessingResult.suppressedByAck,
        ForwardingDecisionReason.dropOwnPacket ||
        ForwardingDecisionReason.dropDuplicate => BleProcessingResult.duplicate,
        _ => BleProcessingResult.stale,
      };
    }

    message.hopCount = decision.nextHopCount ?? message.hopCount;
    if (decision.shouldRelay ||
        decision.reason == ForwardingDecisionReason.dropCooldown) {
      message.localState = 'queued';
    }
    final isNewerState = _isNewerState(message, existing);
    final isPriorityStatus =
        message.status == SOSMessageStatus.cancelled ||
        message.status == SOSMessageStatus.resolved;

    if (existing != null && !isNewerState) {
      message.relayCount = existing.relayCount;
      message.duplicateCount = existing.duplicateCount;
      message.lastRelayedAt = existing.lastRelayedAt;
    }

    final nextEligibleAt =
        decision.reason == ForwardingDecisionReason.dropCooldown &&
            decision.nextEligibleAt != null
        ? decision.nextEligibleAt!
        : isNewerState || isPriorityStatus
        ? now
        : _relayQueue.sosCooldownEligibleAt(
            now,
            relayCount: message.relayCount,
          );
    final bool stored;
    try {
      stored = await _relayQueue.storeAndQueueSos(
        message: message,
        priority: RelayQueueService.priorityForSosStatus(message.status),
        nextEligibleAt: nextEligibleAt,
      );
    } catch (e) {
      await _experimentLogger.logEvent(
        eventType: ExperimentEventTypes.sosTransactionRolledBack,
        deviceId: SyncService().deviceId,
        messageId: message.id,
        senderCrc: message.senderCrc,
        rssi: rssi,
        payloadHash: packet.identity,
        detail: {'error': e.toString()},
      );
      rethrow;
    }
    if (!stored) {
      _log('SOS_TRANSACTION_SKIPPED ${packet.identity}');
      return BleProcessingResult.stale;
    }
    await _experimentLogger.logEvent(
      eventType: ExperimentEventTypes.sosTransactionCommitted,
      deviceId: SyncService().deviceId,
      messageId: message.id,
      senderCrc: message.senderCrc,
      hopCount: message.hopCount,
      rssi: rssi,
      payloadHash: packet.identity,
      detail: {
        'status': message.status.name,
        'next_eligible_at': nextEligibleAt,
        'relay_count': message.relayCount,
      },
    );
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
      return BleProcessingResult.accepted;
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
      return BleProcessingResult.accepted;
    }

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
    return BleProcessingResult.accepted;
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

      await WorkManagerService.registerSyncTask();
    } catch (e) {
      _log('Gateway sync scheduling skipped/failed: $e');
    }
  }

  Future<void> _recoverQueues() async {
    final ackRecovered = await _relayQueue.recoverAckQueueFromTombstones();
    final sosRecovered = await _relayQueue.recoverSosQueueFromMessages();
    if (ackRecovered > 0) {
      await _experimentLogger.logEvent(
        eventType: ExperimentEventTypes.ackQueueRecovered,
        deviceId: SyncService().deviceId,
        detail: {'queue_size': ackRecovered},
      );
    }
    if (sosRecovered > 0) {
      await _experimentLogger.logEvent(
        eventType: ExperimentEventTypes.sosQueueRecovered,
        deviceId: SyncService().deviceId,
        detail: {'queue_size': sosRecovered},
      );
    }
  }

  Future<void> _logAckResult(
    AckApplyResult result, {
    required int senderCrc,
    required int ackTimestampMs,
    required SOSMessageStatus status,
    int? rssi,
    String? payloadHash,
  }) async {
    final eventType = switch (result) {
      AckApplyResult.inserted => ExperimentEventTypes.ackTransactionCommitted,
      AckApplyResult.replacedNewerTimestamp =>
        ExperimentEventTypes.ackReplacedNewerTimestamp,
      AckApplyResult.replacedHigherStatus =>
        ExperimentEventTypes.ackReplacedHigherStatus,
      AckApplyResult.duplicate => ExperimentEventTypes.ackDuplicate,
      AckApplyResult.rejectedOlder => ExperimentEventTypes.ackRejectedOlder,
      AckApplyResult.rejectedInvalid => ExperimentEventTypes.bleRelayDropped,
      AckApplyResult.rejectedFuture => ExperimentEventTypes.ackRejectedFuture,
    };
    await _experimentLogger.logEvent(
      eventType: eventType,
      deviceId: SyncService().deviceId,
      senderCrc: senderCrc,
      rssi: rssi,
      payloadHash: payloadHash,
      detail: {
        'ack_timestamp_ms': canonicalProtocolTimestamp(ackTimestampMs),
        'status': status.name,
        'result': result.name,
      },
    );
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
