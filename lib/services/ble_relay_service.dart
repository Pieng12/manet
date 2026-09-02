import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:pkmproject/config/mesh_config.dart';
import 'package:pkmproject/models/ack_apply_result.dart';
import 'package:pkmproject/models/ble_processing_result.dart';
import 'package:pkmproject/models/forwarding_decision.dart';
import 'package:pkmproject/models/sos_message.dart';
import 'package:pkmproject/models/trickle_state.dart';
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
import 'package:pkmproject/utils/sos_state_ordering.dart';

class BleRelayService {
  static final BleRelayService _instance = BleRelayService._internal();
  factory BleRelayService() => _instance;
  BleRelayService._internal();

  static const Duration nativeReceiveFutureTolerance = Duration(seconds: 2);

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
    final now = DateTime.now().millisecondsSinceEpoch;
    await _advertiser.enqueueSosForAdvertising(
      message,
      nextEligibleAt: now,
      preemptCurrent: true,
    );
    if (MeshConfig.forwardingMode == ForwardingMode.trickle) {
      await _logTrickleReset(
        message: message,
        reason: 'local_source_event',
        nowMs: now,
        logInconsistentHeard: false,
        resetPerformed: true,
      );
    }
    await WorkManagerService.registerSyncTask();
    await _tryGatewaySync();
  }

  Future<BleProcessingResult> processIncomingBase64(
    String payloadBase64, {
    int? rssi,
    int? receivedAtMs,
    int? receivedElapsedRealtimeMs,
    String? deviceAddress,
    String? observationId,
    String? observerKey,
    String? sourcePath,
  }) async {
    try {
      final payload = base64Decode(payloadBase64);
      return processIncomingPayload(
        Uint8List.fromList(payload),
        rssi: rssi,
        receivedAtMs: receivedAtMs,
        receivedElapsedRealtimeMs: receivedElapsedRealtimeMs,
        deviceAddress: deviceAddress,
        observationId: observationId,
        observerKey: observerKey,
        sourcePath: sourcePath,
      );
    } on FormatException catch (e) {
      final processingNowMs = DateTime.now().millisecondsSinceEpoch;
      final rxAtMs = effectiveObservationTime(
        receivedAtMs: receivedAtMs,
        processingNowMs: processingNowMs,
      );
      final claimed = await _claimProtocolObservation(
        observationId: observationId,
        packetType: 'invalid',
        rxAtMs: rxAtMs,
        processingNowMs: processingNowMs,
        receivedElapsedRealtimeMs: receivedElapsedRealtimeMs,
        sourcePath: sourcePath,
      );
      if (!claimed) return BleProcessingResult.transportDuplicate;
      await _dbHelper.completeBleObservation(observationId, processingNowMs);
      _log('Invalid BLE payload: $e');
      return BleProcessingResult.invalid;
    }
  }

  Future<BleProcessingResult> processIncomingPayload(
    Uint8List payload, {
    int? rssi,
    int? receivedAtMs,
    int? receivedElapsedRealtimeMs,
    String? deviceAddress,
    String? observationId,
    String? observerKey,
    String? sourcePath,
  }) async {
    final processingNowMs = DateTime.now().millisecondsSinceEpoch;
    final rxAtMs = effectiveObservationTime(
      receivedAtMs: receivedAtMs,
      processingNowMs: processingNowMs,
    );
    final packet = BlePacket.unpack(payload);
    if (packet == null) {
      final claimed = await _claimProtocolObservation(
        observationId: observationId,
        packetType: 'invalid',
        rxAtMs: rxAtMs,
        processingNowMs: processingNowMs,
        receivedElapsedRealtimeMs: receivedElapsedRealtimeMs,
        sourcePath: sourcePath,
      );
      if (!claimed) return BleProcessingResult.transportDuplicate;
      await _dbHelper.completeBleObservation(observationId, processingNowMs);
      _log('Ignored non-ResQMesh BLE packet: ${_hex(payload)}');
      return BleProcessingResult.invalid;
    }

    _log('Received BLE payload ${_hex(payload)} -> ${_describePacket(packet)}');
    final effectiveObserverKey = _trickleObserverKey(
      packet,
      deviceAddress,
      observerKey: observerKey,
    );
    final claimed = await _claimProtocolObservation(
      observationId: observationId,
      packetType: packet.kind.name,
      rxAtMs: rxAtMs,
      processingNowMs: processingNowMs,
      receivedElapsedRealtimeMs: receivedElapsedRealtimeMs,
      observerKey: effectiveObserverKey,
      packet: packet,
      rssi: rssi,
      sourcePath: sourcePath,
    );
    if (!claimed) return BleProcessingResult.transportDuplicate;

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
        if (observationId?.trim().isNotEmpty == true)
          'observation_id': observationId!.trim(),
        'observer_key': effectiveObserverKey,
        if (receivedAtMs != null && receivedAtMs != rxAtMs)
          'receive_time_fallback_reason': 'invalid_or_future_received_at',
      },
    );

    try {
      final result = packet.isAck
          ? await _processAck(
              packet,
              rssi: rssi,
              receivedAtMs: rxAtMs,
              receivedElapsedRealtimeMs: receivedElapsedRealtimeMs,
            )
          : await _processSos(
              packet,
              rssi: rssi,
              receivedAtMs: rxAtMs,
              receivedElapsedRealtimeMs: receivedElapsedRealtimeMs,
              deviceAddress: deviceAddress,
              observationId: observationId,
              observerKey: observerKey,
            );
      if (result.shouldRetryInbox) {
        await _dbHelper.markBleObservationRetryable(
          observationId,
          DateTime.now().millisecondsSinceEpoch,
        );
      } else {
        await _dbHelper.completeBleObservation(
          observationId,
          DateTime.now().millisecondsSinceEpoch,
        );
      }
      return result;
    } catch (e) {
      await _dbHelper.markBleObservationRetryable(
        observationId,
        DateTime.now().millisecondsSinceEpoch,
      );
      _log('Retryable BLE processing failure for ${packet.identity}: $e');
      return BleProcessingResult.failedRetryable;
    }
  }

  Future<bool> _claimProtocolObservation({
    required String? observationId,
    required String packetType,
    required int rxAtMs,
    required int processingNowMs,
    int? receivedElapsedRealtimeMs,
    String? observerKey,
    BlePacket? packet,
    int? rssi,
    String? sourcePath,
  }) async {
    final claim = await _dbHelper.claimBleObservation(
      observationId: observationId,
      packetType: packetType,
      receivedAtMs: rxAtMs,
      processedAtMs: processingNowMs,
      sourcePath: sourcePath,
    );
    if (claim == null || claim.shouldProcess) return true;

    await _experimentLogger.logEvent(
      eventType: ExperimentEventTypes.bleTransportDuplicate,
      deviceId: SyncService().deviceId,
      senderCrc: packet?.senderCrc,
      hopCount: packet?.hopCount,
      hopIn: packet?.hopCount,
      rssi: rssi,
      payloadHash: packet?.identity,
      eventTimestampMs: rxAtMs,
      elapsedRealtimeMs: receivedElapsedRealtimeMs,
      protocolTimestampMs: packet?.timestampMs,
      packetType: packetType,
      status: packet?.status.name,
      detail: {
        'reason': 'OBSERVATION_ALREADY_PROCESSED',
        'observation_id': claim.observationId,
        'observer_key': observerKey,
        'received_at': rxAtMs,
        'processed_at': processingNowMs,
        'processing_delay_ms': processingNowMs - rxAtMs,
        'source_path': sourcePath,
        'existing_state': claim.state,
      },
    );
    return false;
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
    return isSosStateImprovement(incoming, existing);
  }

  static bool isSosStateImprovement(SOSMessage incoming, SOSMessage? existing) {
    if (existing == null) return true;
    return compareSosState(incoming, existing) > 0;
  }

  static bool isPrioritySosStatus(SOSMessageStatus status) {
    return status == SOSMessageStatus.cancelled ||
        status == SOSMessageStatus.resolved;
  }

  static bool shouldDeferSosForCooldown({
    required ForwardingDecision decision,
    required SOSMessage incoming,
    required SOSMessage? existing,
  }) {
    return decision.reason == ForwardingDecisionReason.dropCooldown &&
        decision.nextEligibleAt != null &&
        !isSosStateImprovement(incoming, existing) &&
        !isPrioritySosStatus(incoming.status);
  }

  static bool shouldRelaySosNow({
    required ForwardingDecision decision,
    required SOSMessage incoming,
    required SOSMessage? existing,
  }) {
    return decision.shouldRelay ||
        isSosStateImprovement(incoming, existing) ||
        isPrioritySosStatus(incoming.status);
  }

  static int determineSosNextEligibleAt({
    required int nowMs,
    required ForwardingDecision decision,
    required SOSMessage incoming,
    required SOSMessage? existing,
    required RelayQueueService relayQueue,
  }) {
    if (shouldDeferSosForCooldown(
      decision: decision,
      incoming: incoming,
      existing: existing,
    )) {
      return decision.nextEligibleAt!;
    }
    if (isSosStateImprovement(incoming, existing) ||
        isPrioritySosStatus(incoming.status)) {
      return nowMs;
    }
    return relayQueue.nextSosEligibleAt(nowMs);
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

    await _logSosRelayTerminatedByAck(packet);
    await _advertiser.advertiseLatestOrStop(preemptCurrent: true);
    final nextAckHop = packet.hopCount >= MeshConfig.maxProtocolHop
        ? MeshConfig.maxProtocolHop
        : packet.hopCount + 1;
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
    String? deviceAddress,
    String? observationId,
    String? observerKey,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final rxAtMs = effectiveObservationTime(
      receivedAtMs: receivedAtMs,
      processingNowMs: now,
    );
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
        final observed = await _recordTrickleConsistentHeard(
          existing: existing,
          packet: packet,
          deviceAddress: deviceAddress,
          observationId: observationId,
          observerKey: observerKey,
          nowMs: rxAtMs,
          processedAtMs: now,
          rssi: rssi,
          receivedAtMs: rxAtMs,
          receivedElapsedRealtimeMs: receivedElapsedRealtimeMs,
        );
        await _experimentLogger.logEvent(
          eventType: ExperimentEventTypes.blePacketDuplicate,
          deviceId: SyncService().deviceId,
          messageId: existing.id,
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
          detail: {
            if (MeshConfig.forwardingMode == ForwardingMode.trickle)
              'trickle_observation_recorded': observed,
            if (MeshConfig.forwardingMode == ForwardingMode.trickle &&
                !observed)
              'trickle_observation_ignored_reason':
                  'duplicate_or_delayed_old_interval_observation',
          },
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
          eventTimestampMs: rxAtMs,
          elapsedRealtimeMs: receivedElapsedRealtimeMs,
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
        eventTimestampMs: rxAtMs,
        elapsedRealtimeMs: receivedElapsedRealtimeMs,
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
    final shouldRelayNow = shouldRelaySosNow(
      decision: decision,
      incoming: message,
      existing: existing,
    );
    final isDeferredByCooldown = shouldDeferSosForCooldown(
      decision: decision,
      incoming: message,
      existing: existing,
    );

    if (existing != null && !isNewerState) {
      message.relayCount = existing.relayCount;
      message.duplicateCount = existing.duplicateCount;
      message.lastRelayedAt = existing.lastRelayedAt;
    }

    final nextEligibleAt = determineSosNextEligibleAt(
      nowMs: now,
      decision: decision,
      incoming: message,
      existing: existing,
      relayQueue: _relayQueue,
    );
    final SosQueueStoreResult storeResult;
    try {
      storeResult = await _relayQueue.storeAndQueueSosWithResult(
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
        eventTimestampMs: rxAtMs,
        elapsedRealtimeMs: receivedElapsedRealtimeMs,
        protocolTimestampMs: packet.timestampMs,
        packetType: 'sos',
        status: packet.status.name,
        detail: {'error': e.toString()},
      );
      rethrow;
    }
    if (!storeResult.stored) {
      _log('SOS_TRANSACTION_SKIPPED ${packet.identity}');
      return BleProcessingResult.stale;
    }
    if (MeshConfig.forwardingMode == ForwardingMode.trickle) {
      await _logTrickleReset(
        message: message,
        reason:
            storeResult.trickleReason ??
            (isNewerState ? 'incoming_inconsistent_state' : 'new_state'),
        nowMs: nextEligibleAt,
        packet: packet,
        rssi: rssi,
        receivedAtMs: rxAtMs,
        receivedElapsedRealtimeMs: receivedElapsedRealtimeMs,
        deviceAddress: deviceAddress,
        observationId: observationId,
        observerKey: observerKey,
        logInconsistentHeard: storeResult.trickleInconsistentHeard,
        resetPerformed: storeResult.trickleResetPerformed,
      );
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
      eventTimestampMs: rxAtMs,
      elapsedRealtimeMs: receivedElapsedRealtimeMs,
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

    if (isDeferredByCooldown) {
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

    if (!shouldRelayNow) {
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

  Future<bool> _recordTrickleConsistentHeard({
    required SOSMessage existing,
    required BlePacket packet,
    required int nowMs,
    String? deviceAddress,
    String? observationId,
    String? observerKey,
    int? rssi,
    int? receivedAtMs,
    int? receivedElapsedRealtimeMs,
    int? processedAtMs,
  }) async {
    if (MeshConfig.forwardingMode != ForwardingMode.trickle) return false;
    final effectiveObserverKey = _trickleObserverKey(
      packet,
      deviceAddress,
      observerKey: observerKey,
    );
    final effectiveObservationId = observationId?.trim().isNotEmpty == true
        ? observationId!.trim()
        : '${packet.identity}|$effectiveObserverKey|${receivedAtMs ?? nowMs}';
    final recorded = await _relayQueue.recordConsistentSosObservation(
      messageId: existing.id,
      observationId: effectiveObservationId,
      observerKey: effectiveObserverKey,
      nowMs: nowMs,
    );
    if (recorded) {
      final state = await _relayQueue.trickleStateFor(existing.id);
      await _experimentLogger.logEvent(
        eventType: ExperimentEventTypes.trickleConsistentHeard,
        deviceId: SyncService().deviceId,
        messageId: existing.id,
        senderCrc: packet.senderCrc,
        hopCount: packet.hopCount,
        hopIn: packet.hopCount,
        rssi: rssi,
        payloadHash: packet.identity,
        eventTimestampMs: receivedAtMs,
        elapsedRealtimeMs: receivedElapsedRealtimeMs,
        protocolTimestampMs: packet.timestampMs,
        packetType: 'sos',
        status: packet.status.name,
        detail: {
          'observation_id': effectiveObservationId,
          'observer_key': effectiveObserverKey,
          'received_at': receivedAtMs,
          'processed_at': processedAtMs,
          'processing_delay_ms': processedAtMs != null && receivedAtMs != null
              ? processedAtMs - receivedAtMs
              : null,
          'Imin': MeshConfig.trickleImin.inMilliseconds,
          'Imax': MeshConfig.trickleImax.inMilliseconds,
          'k': MeshConfig.trickleRedundancyConstant,
          if (state != null) 'I': state.intervalMs,
          if (state != null) 'c': state.consistencyCount,
          if (state != null) 'transmit_at': state.transmitAt,
          if (state != null) 'interval_started_at': state.intervalStartedAt,
          if (state != null) 'interval_end_at': state.intervalEndAt,
          if (state != null) 'phase': state.phase,
          'logical_identity':
              '${packet.senderCrc}|${packet.timestampMs}|${packet.status.name}',
        },
      );
    }
    return recorded;
  }

  Future<void> _logTrickleReset({
    required SOSMessage message,
    required String reason,
    required int nowMs,
    bool logInconsistentHeard = true,
    bool resetPerformed = true,
    BlePacket? packet,
    int? rssi,
    int? receivedAtMs,
    int? receivedElapsedRealtimeMs,
    String? deviceAddress,
    String? observationId,
    String? observerKey,
  }) async {
    if (MeshConfig.forwardingMode != ForwardingMode.trickle) return;
    final state = await _relayQueue.trickleStateFor(message.id);
    final detail = {
      'reset_reason': reason,
      'Imin': MeshConfig.trickleImin.inMilliseconds,
      'Imax': MeshConfig.trickleImax.inMilliseconds,
      'k': MeshConfig.trickleRedundancyConstant,
      'reset_performed': resetPerformed,
      'sos_advertise_burst_ms':
          MeshConfig.sosAdvertiseBurstDuration.inMilliseconds,
      if (state != null) 'I': state.intervalMs,
      if (state != null) 'c': state.consistencyCount,
      if (state != null) 'transmit_at': state.transmitAt,
      if (state != null) 'interval_started_at': state.intervalStartedAt,
      if (state != null) 'interval_end_at': state.intervalEndAt,
      if (state != null) 'phase': state.phase,
      if (observationId?.trim().isNotEmpty == true)
        'observation_id': observationId!.trim(),
      if (packet != null)
        'observer_key': _trickleObserverKey(
          packet,
          deviceAddress,
          observerKey: observerKey,
        ),
    };
    if (logInconsistentHeard) {
      await _experimentLogger.logEvent(
        eventType: ExperimentEventTypes.trickleInconsistentHeard,
        deviceId: SyncService().deviceId,
        messageId: message.id,
        senderCrc: message.senderCrc,
        hopCount: message.hopCount,
        hopIn: packet?.hopCount,
        hopOut: message.hopCount,
        rssi: rssi,
        payloadHash: packet?.identity,
        eventTimestampMs: receivedAtMs ?? nowMs,
        elapsedRealtimeMs: receivedElapsedRealtimeMs,
        protocolTimestampMs: packet?.timestampMs ?? message.updatedAt,
        packetType: 'sos',
        status: message.status.name,
        detail: detail,
      );
    }
    if (!resetPerformed) return;
    await _experimentLogger.logEvent(
      eventType: ExperimentEventTypes.trickleReset,
      deviceId: SyncService().deviceId,
      messageId: message.id,
      senderCrc: message.senderCrc,
      hopCount: message.hopCount,
      packetType: 'sos',
      status: message.status.name,
      detail: detail,
    );
    await _experimentLogger.logEvent(
      eventType: ExperimentEventTypes.trickleIntervalStarted,
      deviceId: SyncService().deviceId,
      messageId: message.id,
      senderCrc: message.senderCrc,
      hopCount: message.hopCount,
      packetType: 'sos',
      status: message.status.name,
      detail: detail,
    );
  }

  String _trickleObserverKey(
    BlePacket packet,
    String? deviceAddress, {
    String? observerKey,
  }) {
    final nativeObserverKey = observerKey?.trim();
    if (nativeObserverKey != null && nativeObserverKey.isNotEmpty) {
      return nativeObserverKey;
    }
    final normalized = deviceAddress?.trim();
    if (normalized != null &&
        normalized.isNotEmpty &&
        normalized != 'unknown') {
      return 'ble:$normalized';
    }
    return 'unknown:${packet.senderCrc}:${packet.timestampMs}:${packet.status.name}';
  }

  static int effectiveObservationTime({
    required int? receivedAtMs,
    required int processingNowMs,
    Duration maxFutureSkew = nativeReceiveFutureTolerance,
  }) {
    if (receivedAtMs == null || receivedAtMs <= 0) return processingNowMs;
    if (receivedAtMs > processingNowMs + maxFutureSkew.inMilliseconds) {
      return processingNowMs;
    }
    return receivedAtMs;
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
    final preRecoveryTrickleStateIds =
        MeshConfig.forwardingMode == ForwardingMode.trickle
        ? (await _relayQueue.allTrickleStates())
              .map((state) => state.messageId)
              .toSet()
        : <String>{};
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
    if (MeshConfig.forwardingMode == ForwardingMode.trickle) {
      final states = await _relayQueue.allTrickleStates();
      for (final state in states) {
        final persistedStateFound = preRecoveryTrickleStateIds.contains(
          state.messageId,
        );
        final detail = _trickleStateRecoveryDetail(
          state,
          recoveryReason: persistedStateFound
              ? 'service_or_queue_recovery'
              : 'recovery_state_missing',
          persistedStateFound: persistedStateFound,
        );
        if (persistedStateFound) {
          await _experimentLogger.logEvent(
            eventType: ExperimentEventTypes.trickleStateRecovered,
            deviceId: SyncService().deviceId,
            messageId: state.messageId,
            detail: detail,
          );
        } else {
          await _experimentLogger.logEvent(
            eventType: ExperimentEventTypes.trickleReset,
            deviceId: SyncService().deviceId,
            messageId: state.messageId,
            packetType: 'sos',
            detail: detail,
          );
          await _experimentLogger.logEvent(
            eventType: ExperimentEventTypes.trickleIntervalStarted,
            deviceId: SyncService().deviceId,
            messageId: state.messageId,
            packetType: 'sos',
            detail: detail,
          );
        }
      }
    }
  }

  Map<String, Object?> _trickleStateRecoveryDetail(
    TrickleState state, {
    required String recoveryReason,
    required bool persistedStateFound,
  }) {
    return {
      'message_id': state.messageId,
      'I': state.intervalMs,
      'Imin': MeshConfig.trickleImin.inMilliseconds,
      'Imax': MeshConfig.trickleImax.inMilliseconds,
      'k': MeshConfig.trickleRedundancyConstant,
      'c': state.consistencyCount,
      'transmit_at': state.transmitAt,
      'interval_started_at': state.intervalStartedAt,
      'interval_end_at': state.intervalEndAt,
      'phase': state.phase,
      'reset_reason': state.lastResetReason,
      'recovery_reason': recoveryReason,
      'persisted_state_found': persistedStateFound,
    };
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

  Future<void> _logSosRelayTerminatedByAck(BlePacket packet) async {
    final db = await _dbHelper.database;
    final ackTimestamp = canonicalProtocolTimestamp(packet.timestampMs);
    final rows = await db.query(
      'sos_messages',
      columns: const ['id'],
      where: 'sender_crc = ? AND ack_received_at = ? AND local_state = ?',
      whereArgs: [packet.senderCrc, ackTimestamp, 'acked'],
    );
    if (rows.isEmpty) return;
    for (final row in rows) {
      final messageId = row['id']?.toString();
      if (messageId == null) continue;
      final existing = await db.rawQuery(
        '''
        SELECT COUNT(*) AS count
        FROM experiment_events
        WHERE event_type = ?
          AND message_id = ?
          AND sender_crc = ?
          AND protocol_timestamp_ms = ?
          AND packet_type = ?
          AND status = ?
        ''',
        [
          ExperimentEventTypes.sosRelayTerminatedByAck,
          messageId,
          packet.senderCrc,
          ackTimestamp,
          'ack',
          packet.status.name,
        ],
      );
      final existingCount = existing.first['count'] as int? ?? 0;
      if (existingCount > 0) continue;

      await _advertiser.stopAdvertisingIfCurrentMessage(messageId);
      if (_advertiser.currentAdvertisedMessageId == messageId) continue;

      final eventAt = DateTime.now().millisecondsSinceEpoch;
      await _experimentLogger.logEvent(
        eventType: ExperimentEventTypes.sosRelayTerminatedByAck,
        deviceId: SyncService().deviceId,
        messageId: messageId,
        senderCrc: packet.senderCrc,
        hopIn: packet.hopCount,
        rssi: null,
        payloadHash: packet.identity,
        eventTimestampMs: eventAt,
        protocolTimestampMs: packet.timestampMs,
        packetType: 'ack',
        status: packet.status.name,
        detail: {
          'ack_timestamp_ms': ackTimestamp,
          'termination_key':
              'ack|${packet.senderCrc}|$ackTimestamp|${packet.status.name}',
        },
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
