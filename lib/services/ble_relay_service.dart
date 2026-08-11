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

  static BleProcessingResult processingResultForAckApplyResult(
    AckApplyResult result,
  ) {
    return switch (result) {
      AckApplyResult.duplicate => BleProcessingResult.duplicate,
      AckApplyResult.rejectedOlder => BleProcessingResult.stale,
      AckApplyResult.rejectedInvalid ||
      AckApplyResult.rejectedFuture => BleProcessingResult.invalid,
      _ => BleProcessingResult.accepted,
    };
  }

  static String? genericAckPacketEventTypeForResult(AckApplyResult result) {
    return switch (result) {
      AckApplyResult.duplicate => ExperimentEventTypes.blePacketDuplicate,
      AckApplyResult.rejectedOlder => ExperimentEventTypes.blePacketStale,
      AckApplyResult.rejectedInvalid ||
      AckApplyResult.rejectedFuture => ExperimentEventTypes.bleRelayDropped,
      _ => null,
    };
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
    int? receivedAtMs,
    int? receivedElapsedRealtimeMs,
  }) async {
    try {
      final payload = base64Decode(payloadBase64);
      return processIncomingPayload(
        Uint8List.fromList(payload),
        rssi: rssi,
        receivedAtMs: receivedAtMs,
        receivedElapsedRealtimeMs: receivedElapsedRealtimeMs,
      );
    } on FormatException catch (e) {
      _log('Invalid BLE payload: $e');
      return BleProcessingResult.invalid;
    }
  }

  Future<BleProcessingResult> processIncomingPayload(
    Uint8List payload, {
    int? rssi,
    int? receivedAtMs,
    int? receivedElapsedRealtimeMs,
  }) async {
    final packet = BlePacket.unpack(payload);
    if (packet == null) {
      _log('Ignored non-ResQMesh BLE packet: ${_hex(payload)}');
      return BleProcessingResult.invalid;
    }

    _log('Received BLE payload ${_hex(payload)} -> ${_describePacket(packet)}');
    final rxAtMs = receivedAtMs ?? DateTime.now().millisecondsSinceEpoch;
    await _experimentLogger.logEvent(
      eventType: ExperimentEventTypes.blePacketReceived,
      deviceId: SyncService().deviceId,
      senderCrc: packet.senderCrc,
      hopCount: packet.hopCount,
      hopIn: packet.hopCount,
      rssi: rssi,
      payloadHash: packet.identity,
      eventTimestampMs: rxAtMs,
      elapsedRealtimeMs: receivedElapsedRealtimeMs,
      protocolTimestampMs: packet.timestampMs,
      packetType: packet.kind.name,
      status: packet.status.name,
      detail: {
        'kind': packet.kind.name,
        'status': packet.status.name,
        'from_server': packet.fromServer,
      },
    );

    try {
      if (packet.isAck) {
        return await _processAck(
          packet,
          rssi: rssi,
          receivedAtMs: rxAtMs,
          receivedElapsedRealtimeMs: receivedElapsedRealtimeMs,
        );
      } else {
        return await _processSos(
          packet,
          rssi: rssi,
          receivedAtMs: rxAtMs,
          receivedElapsedRealtimeMs: receivedElapsedRealtimeMs,
        );
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

  Future<BleProcessingResult> _processAck(
    BlePacket packet, {
    int? rssi,
    int? receivedAtMs,
    int? receivedElapsedRealtimeMs,
  }) async {
    if (packet.status == SOSMessageStatus.active) {
      await _experimentLogger.logEvent(
        eventType: ExperimentEventTypes.bleRelayDropped,
        deviceId: SyncService().deviceId,
        senderCrc: packet.senderCrc,
        hopCount: packet.hopCount,
        hopIn: packet.hopCount,
        rssi: rssi,
        payloadHash: packet.identity,
        eventTimestampMs: receivedAtMs,
        elapsedRealtimeMs: receivedElapsedRealtimeMs,
        protocolTimestampMs: packet.timestampMs,
        packetType: 'ack',
        status: packet.status.name,
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
      hopIn: packet.hopCount,
      rssi: rssi,
      payloadHash: packet.identity,
      eventTimestampMs: receivedAtMs,
      elapsedRealtimeMs: receivedElapsedRealtimeMs,
      protocolTimestampMs: packet.timestampMs,
      packetType: 'ack',
      status: packet.status.name,
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
        hopIn: packet.hopCount,
        rssi: rssi,
        payloadHash: packet.identity,
        eventTimestampMs: receivedAtMs,
        elapsedRealtimeMs: receivedElapsedRealtimeMs,
        protocolTimestampMs: packet.timestampMs,
        packetType: 'ack',
        status: packet.status.name,
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
      hopIn: packet.hopCount,
      hopOut: packet.hopCount >= MeshConfig.maxProtocolHop
          ? MeshConfig.maxProtocolHop
          : packet.hopCount + 1,
    );

    final genericAckEventType = genericAckPacketEventTypeForResult(result);
    if (!result.shouldRelay) {
      if (genericAckEventType != null) {
        await _experimentLogger.logEvent(
          eventType: genericAckEventType,
          deviceId: SyncService().deviceId,
          senderCrc: packet.senderCrc,
          hopCount: packet.hopCount,
          hopIn: packet.hopCount,
          rssi: rssi,
          payloadHash: packet.identity,
          eventTimestampMs: receivedAtMs,
          elapsedRealtimeMs: receivedElapsedRealtimeMs,
          protocolTimestampMs: packet.timestampMs,
          packetType: 'ack',
          status: packet.status.name,
          detail: {
            'kind': 'ack',
            if (genericAckEventType == ExperimentEventTypes.bleRelayDropped)
              'reason': result.name,
          },
        );
      }
      _log('${result.name.toUpperCase()} ${packet.identity}');
      return processingResultForAckApplyResult(result);
    }

    await _advertiser.advertiseLatestOrStop(preemptCurrent: true);
    final nextAckHop = packet.hopCount >= MeshConfig.maxProtocolHop
        ? MeshConfig.maxProtocolHop
        : packet.hopCount + 1;
    await _logSosRelayTerminatedByAck(packet, receivedAtMs: receivedAtMs);
    await _experimentLogger.logEvent(
      eventType: ExperimentEventTypes.bleRelayQueued,
      deviceId: SyncService().deviceId,
      senderCrc: packet.senderCrc,
      hopCount: nextAckHop,
      hopIn: packet.hopCount,
      hopOut: nextAckHop,
      rssi: rssi,
      payloadHash: packet.identity,
      protocolTimestampMs: packet.timestampMs,
      packetType: 'ack',
      status: packet.status.name,
      detail: {'kind': 'ack'},
    );
    _log('ACK_RELAY_QUEUED ${packet.identity} hop=$nextAckHop');
    return BleProcessingResult.accepted;
  }

  Future<BleProcessingResult> _processSos(
    BlePacket packet, {
    int? rssi,
    int? receivedAtMs,
    int? receivedElapsedRealtimeMs,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final rxAtMs = receivedAtMs ?? now;
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
        hopIn: packet.hopCount,
        rssi: rssi,
        payloadHash: packet.identity,
        eventTimestampMs: rxAtMs,
        elapsedRealtimeMs: receivedElapsedRealtimeMs,
        protocolTimestampMs: packet.timestampMs,
        packetType: 'sos',
        status: packet.status.name,
        detail: {'reason': 'ACK_TOMBSTONE_SUPPRESSED'},
      );
      _log('ACK_TOMBSTONE_SUPPRESSED ${packet.identity}');
      return BleProcessingResult.suppressedByAck;
    }

    final message = messageFromSosPacket(packet, rxAtMs);
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
          hopIn: packet.hopCount,
          rssi: rssi,
          payloadHash: packet.identity,
          protocolTimestampMs: packet.timestampMs,
          packetType: 'sos',
          status: packet.status.name,
        );
      } else if (decision.reason == ForwardingDecisionReason.dropStale) {
        await _experimentLogger.logEvent(
          eventType: ExperimentEventTypes.blePacketStale,
          deviceId: SyncService().deviceId,
          messageId: existing?.id,
          senderCrc: packet.senderCrc,
          hopCount: packet.hopCount,
          hopIn: packet.hopCount,
          rssi: rssi,
          payloadHash: packet.identity,
          protocolTimestampMs: packet.timestampMs,
          packetType: 'sos',
          status: packet.status.name,
          detail: {'latest_state': existing?.status.name},
        );
      }
      await _experimentLogger.logEvent(
        eventType: ExperimentEventTypes.bleRelayDropped,
        deviceId: SyncService().deviceId,
        messageId: existing?.id,
        senderCrc: packet.senderCrc,
        hopCount: packet.hopCount,
        hopIn: packet.hopCount,
        rssi: rssi,
        payloadHash: packet.identity,
        protocolTimestampMs: packet.timestampMs,
        packetType: 'sos',
        status: packet.status.name,
        detail: {'reason': decision.reason.code},
      );
      _log('${decision.reason.code} ${packet.identity}');
      return switch (decision.reason) {
        ForwardingDecisionReason.dropInvalid => BleProcessingResult.invalid,
        ForwardingDecisionReason.dropAcked =>
          BleProcessingResult.suppressedByAck,
        ForwardingDecisionReason.dropStale => BleProcessingResult.stale,
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
        hopIn: packet.hopCount,
        rssi: rssi,
        payloadHash: packet.identity,
        protocolTimestampMs: packet.timestampMs,
        packetType: 'sos',
        status: packet.status.name,
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
      hopIn: packet.hopCount,
      hopOut: message.hopCount,
      rssi: rssi,
      payloadHash: packet.identity,
      protocolTimestampMs: packet.timestampMs,
      packetType: 'sos',
      status: message.status.name,
      detail: {
        'status': message.status.name,
        'next_eligible_at': nextEligibleAt,
        'relay_count': message.relayCount,
      },
    );
    await _experimentLogger.logEvent(
      eventType: ExperimentEventTypes.blePacketAccepted,
      deviceId: SyncService().deviceId,
      messageId: message.id,
      senderCrc: message.senderCrc,
      hopCount: message.hopCount,
      hopIn: packet.hopCount,
      hopOut: message.hopCount,
      rssi: rssi,
      payloadHash: packet.identity,
      protocolTimestampMs: packet.timestampMs,
      packetType: 'sos',
      status: message.status.name,
    );
    await _experimentLogger.logEvent(
      eventType: ExperimentEventTypes.blePacketStored,
      deviceId: SyncService().deviceId,
      messageId: message.id,
      senderCrc: message.senderCrc,
      hopCount: message.hopCount,
      hopIn: packet.hopCount,
      hopOut: message.hopCount,
      rssi: rssi,
      payloadHash: packet.identity,
      protocolTimestampMs: packet.timestampMs,
      packetType: 'sos',
      status: message.status.name,
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
        hopIn: packet.hopCount,
        hopOut: message.hopCount,
        rssi: rssi,
        payloadHash: packet.identity,
        protocolTimestampMs: packet.timestampMs,
        packetType: 'sos',
        status: message.status.name,
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
        hopIn: packet.hopCount,
        rssi: rssi,
        payloadHash: packet.identity,
        protocolTimestampMs: packet.timestampMs,
        packetType: 'sos',
        status: packet.status.name,
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
      hopIn: packet.hopCount,
      hopOut: message.hopCount,
      rssi: rssi,
      payloadHash: packet.identity,
      protocolTimestampMs: packet.timestampMs,
      packetType: 'sos',
      status: message.status.name,
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
    int? hopIn,
    int? hopOut,
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
      hopCount: hopOut,
      hopIn: hopIn,
      hopOut: hopOut,
      rssi: rssi,
      payloadHash: payloadHash,
      protocolTimestampMs: ackTimestampMs,
      packetType: 'ack',
      status: status.name,
      detail: {
        'ack_timestamp_ms': canonicalProtocolTimestamp(ackTimestampMs),
        'status': status.name,
        'result': result.name,
      },
    );
  }

  Future<void> _logSosRelayTerminatedByAck(
    BlePacket packet, {
    int? receivedAtMs,
  }) async {
    final db = await _dbHelper.database;
    final ackTimestamp = canonicalProtocolTimestamp(packet.timestampMs);
    final rows = await db.query(
      'sos_messages',
      columns: const ['id'],
      where: 'sender_crc = ? AND ack_received_at = ? AND local_state = ?',
      whereArgs: [packet.senderCrc, ackTimestamp, 'acked'],
    );
    if (rows.isEmpty) return;
    final eventAt = receivedAtMs ?? DateTime.now().millisecondsSinceEpoch;
    for (final row in rows) {
      await _experimentLogger.logEvent(
        eventType: ExperimentEventTypes.sosRelayTerminatedByAck,
        deviceId: SyncService().deviceId,
        messageId: row['id']?.toString(),
        senderCrc: packet.senderCrc,
        hopIn: packet.hopCount,
        rssi: null,
        payloadHash: packet.identity,
        eventTimestampMs: eventAt,
        protocolTimestampMs: packet.timestampMs,
        packetType: 'ack',
        status: packet.status.name,
        detail: {'ack_timestamp_ms': ackTimestamp},
      );
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
