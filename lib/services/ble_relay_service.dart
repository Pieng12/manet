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
import 'package:pkmproject/services/experiment_clock.dart';
import 'package:pkmproject/services/forwarding_policy.dart';
import 'package:pkmproject/services/native_bridge_service.dart';
import 'package:pkmproject/services/relay_queue_service.dart';
import 'package:pkmproject/services/research_session_service.dart';
import 'package:pkmproject/services/topology_policy.dart';
import 'package:pkmproject/services/workmanager_service.dart';
import 'package:pkmproject/sync_service.dart';
import 'package:pkmproject/utils/hash_utils.dart';
import 'package:pkmproject/utils/protocol_timestamp.dart';
import 'package:pkmproject/utils/sos_state_ordering.dart';

class _ProtocolObservationClaim {
  const _ProtocolObservationClaim({required this.claim, this.blockedResult});

  final ProcessedBleObservationClaim? claim;
  final BleProcessingResult? blockedResult;
}

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
  final ClockSource _clock = ExperimentClock.instance;
  final TopologyPolicy _topologyPolicy = const TopologyPolicy();
  final _logController = StreamController<String>.broadcast();

  Stream<String> get logStream => _logController.stream;

  static bool failSosTransactionForTest = false;
  static bool failAckTransactionForTest = false;
  static bool failAfterSosDurableCommitForTest = false;
  static bool failAfterLogicalDuplicateCommitForTest = false;
  static bool failAfterAckDurableCommitForTest = false;
  static bool failWorkManagerPostCommitForTest = false;
  static bool failGatewayPostCommitForTest = false;

  static void resetFailureHooksForTesting() {
    failSosTransactionForTest = false;
    failAckTransactionForTest = false;
    failAfterSosDurableCommitForTest = false;
    failAfterLogicalDuplicateCommitForTest = false;
    failAfterAckDurableCommitForTest = false;
    failWorkManagerPostCommitForTest = false;
    failGatewayPostCommitForTest = false;
  }

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
      protocolTimestampMs: timestampMs,
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
    final now = _clock.monotonicTimeMs();
    await _advertiser.enqueueSosForAdvertising(
      message,
      nextEligibleAt: now,
      preemptCurrent: true,
    );
    if (_relayQueue.mode == ForwardingMode.trickle) {
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
      return await processIncomingPayload(
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
      final claimResult = await _claimProtocolObservation(
        observationId: observationId,
        packetType: 'invalid',
        rxAtMs: rxAtMs,
        processingNowMs: processingNowMs,
        receivedElapsedRealtimeMs: receivedElapsedRealtimeMs,
        sourcePath: sourcePath,
      );
      if (claimResult.blockedResult != null) {
        return claimResult.blockedResult!;
      }
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
      final claimResult = await _claimProtocolObservation(
        observationId: observationId,
        packetType: 'invalid',
        rxAtMs: rxAtMs,
        processingNowMs: processingNowMs,
        receivedElapsedRealtimeMs: receivedElapsedRealtimeMs,
        sourcePath: sourcePath,
      );
      if (claimResult.blockedResult != null) {
        return claimResult.blockedResult!;
      }
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
    final claimResult = await _claimProtocolObservation(
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
    if (claimResult.blockedResult != null) {
      if (claimResult.blockedResult == BleProcessingResult.transportDuplicate) {
        await _ensureCanonicalPhysicalReceiveEvents(
          packet: packet,
          observationId: observationId,
          effectiveObserverKey: effectiveObserverKey,
          rssi: rssi,
          receivedAtMs: claimResult.claim?.firstReceivedAt ?? rxAtMs,
          receivedElapsedRealtimeMs: receivedElapsedRealtimeMs,
          receiveTimeFallbackApplied:
              receivedAtMs != null && receivedAtMs != rxAtMs,
        );
      }
      return claimResult.blockedResult!;
    }

    await _ensureCanonicalPhysicalReceiveEvents(
      packet: packet,
      observationId: observationId,
      effectiveObserverKey: effectiveObserverKey,
      rssi: rssi,
      receivedAtMs: claimResult.claim?.firstReceivedAt ?? rxAtMs,
      receivedElapsedRealtimeMs: receivedElapsedRealtimeMs,
      receiveTimeFallbackApplied:
          receivedAtMs != null && receivedAtMs != rxAtMs,
    );

    try {
      final result = packet.isAck
          ? await _processAck(
              packet,
              rssi: rssi,
              receivedAtMs: rxAtMs,
              receivedElapsedRealtimeMs: receivedElapsedRealtimeMs,
              observationId: observationId,
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

  Future<_ProtocolObservationClaim> _claimProtocolObservation({
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
    final researchSessions = ResearchSessionService();
    final researchSession = await researchSessions.currentSession();
    final researchTrial = researchSession == null
        ? null
        : await researchSessions.currentTrial(
            sessionId: researchSession.sessionId,
          );
    final claim = await _dbHelper.claimBleObservation(
      observationId: observationId,
      packetType: packetType,
      receivedAtMs: rxAtMs,
      processedAtMs: processingNowMs,
      sourcePath: sourcePath,
      trialId: researchTrial?.trialId,
    );
    if (claim == null || claim.shouldProcess) {
      return _ProtocolObservationClaim(claim: claim);
    }

    final completed = claim.isCompleted;
    await _runPostCommitEffect(
      completed ? 'transport_duplicate_log' : 'transport_in_progress_log',
      () => _experimentLogger.logEvent(
        eventType: completed
            ? ExperimentEventTypes.bleTransportDuplicate
            : ExperimentEventTypes.bleTransportInProgress,
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
          'reason': completed
              ? 'OBSERVATION_ALREADY_PROCESSED'
              : 'OBSERVATION_PROCESSING_IN_PROGRESS',
          'observation_id': claim.observationId,
          'observer_key': observerKey,
          'received_at': rxAtMs,
          'processed_at': processingNowMs,
          'processing_delay_ms': processingNowMs - rxAtMs,
          'source_path': sourcePath,
          'existing_state': claim.state,
        },
      ),
    );
    return _ProtocolObservationClaim(
      claim: claim,
      blockedResult: completed
          ? BleProcessingResult.transportDuplicate
          : BleProcessingResult.transportInProgress,
    );
  }

  Future<void> _ensureCanonicalPhysicalReceiveEvents({
    required BlePacket packet,
    required String? observationId,
    required String effectiveObserverKey,
    required int receivedAtMs,
    required bool receiveTimeFallbackApplied,
    int? receivedElapsedRealtimeMs,
    int? rssi,
  }) async {
    final trimmedObservationId = observationId?.trim();
    final hasObservationId =
        trimmedObservationId != null && trimmedObservationId.isNotEmpty;
    final physicalRxEventKey = hasObservationId
        ? '${ExperimentEventTypes.blePacketReceived}|$trimmedObservationId'
        : null;

    await _runPostCommitEffect(
      'ble_packet_received_log',
      () => _experimentLogger.logEvent(
        eventType: ExperimentEventTypes.blePacketReceived,
        deviceId: SyncService().deviceId,
        senderCrc: packet.senderCrc,
        hopCount: packet.hopCount,
        hopIn: packet.hopCount,
        rssi: rssi,
        payloadHash: packet.identity,
        eventTimestampMs: receivedAtMs,
        elapsedRealtimeMs: receivedElapsedRealtimeMs,
        protocolTimestampMs: packet.timestampMs,
        packetType: packet.kind.name,
        status: packet.status.name,
        eventKey: physicalRxEventKey,
        messageKey: packet.messageKey.value,
        stateIdentity: packet.stateIdentity.value,
        observationId: hasObservationId ? trimmedObservationId : null,
        detail: {
          'kind': packet.kind.name,
          'status': packet.status.name,
          'from_server': packet.fromServer,
          if (hasObservationId) 'observation_id': trimmedObservationId,
          'observer_key': effectiveObserverKey,
          if (receiveTimeFallbackApplied)
            'receive_time_fallback_reason': 'invalid_or_future_received_at',
        },
      ),
    );

    if (!packet.isAck || packet.status == SOSMessageStatus.active) return;

    final ackReceivedEventKey = hasObservationId
        ? '${ExperimentEventTypes.ackReceived}|$trimmedObservationId'
        : null;
    await _runPostCommitEffect(
      'ack_received_log',
      () => _experimentLogger.logEvent(
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
        eventKey: ackReceivedEventKey,
        messageKey: packet.messageKey.value,
        stateIdentity: packet.stateIdentity.value,
        observationId: hasObservationId ? trimmedObservationId : null,
      ),
    );
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
    String? observationId,
  }) async {
    final researchSessions = ResearchSessionService();
    final researchSession = await researchSessions.currentSession();
    if (researchSession != null && !researchSession.ackEnabled) {
      await _dbHelper.completeBleObservation(
        observationId,
        DateTime.now().millisecondsSinceEpoch,
      );
      await _experimentLogger.logEvent(
        eventType: ExperimentEventTypes.experimentConfigViolation,
        deviceId: SyncService().deviceId,
        senderCrc: packet.senderCrc,
        protocolTimestampMs: packet.timestampMs,
        packetType: 'ack',
        status: packet.status.name,
        messageKey: packet.messageKey.value,
        stateIdentity: packet.stateIdentity.value,
        observationId: observationId,
        detail: {'reason': 'ACK_DURING_MAIN_TRIAL'},
      );
      return BleProcessingResult.invalid;
    }
    if (packet.status == SOSMessageStatus.active) {
      await _dbHelper.completeBleObservation(
        observationId,
        DateTime.now().millisecondsSinceEpoch,
      );
      await _runPostCommitEffect(
        'ack_active_rejected_log',
        () => _experimentLogger.logEvent(
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
        ),
      );
      _log('ACK_ACTIVE_REJECTED ${packet.identity}');
      return BleProcessingResult.invalid;
    }
    final researchTrial = researchSession == null
        ? null
        : await researchSessions.currentTrial(
            sessionId: researchSession.sessionId,
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
        schedulerNowMs: _clock.monotonicTimeMs(),
        processedObservationId: observationId,
        trialId: researchTrial?.trialId,
        failAfterTombstoneForTest: failAckTransactionForTest,
      );
    } catch (e) {
      await _runPostCommitEffect(
        'ack_transaction_rolled_back_log',
        () => _experimentLogger.logEvent(
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
        ),
      );
      rethrow;
    }
    await _dbHelper.completeBleObservation(
      observationId,
      DateTime.now().millisecondsSinceEpoch,
    );
    await _runPostCommitEffect('simulated_ack_post_commit_failure', () async {
      if (failAfterAckDurableCommitForTest) {
        throw StateError('Simulated ACK post-commit failure');
      }
    });
    await _runPostCommitEffect(
      'ack_result_log',
      () => _logAckResult(
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
      ),
    );

    final genericAckEventType = genericAckPacketEventTypeForResult(result);
    if (!result.shouldRelay) {
      if (genericAckEventType != null) {
        await _runPostCommitEffect(
          'ack_generic_result_log',
          () => _experimentLogger.logEvent(
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
          ),
        );
      }
      _log('${result.name.toUpperCase()} ${packet.identity}');
      return processingResultForAckApplyResult(result);
    }

    await _runPostCommitEffect('sos_relay_terminated_by_ack_log', () async {
      await _logSosRelayTerminatedByAck(packet);
    });
    await _runPostCommitEffect('ack_advertise_latest_or_stop', () async {
      await _advertiser.advertiseLatestOrStop(preemptCurrent: true);
    });
    final nextAckHop = packet.hopCount >= MeshConfig.maxProtocolHop
        ? MeshConfig.maxProtocolHop
        : packet.hopCount + 1;
    await _runPostCommitEffect(
      'ack_relay_queued_log',
      () => _experimentLogger.logEvent(
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
      ),
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
    final researchSessions = ResearchSessionService();
    final researchSession = await researchSessions.currentSession();
    final researchTrial = researchSession == null
        ? null
        : await researchSessions.currentTrial(
            sessionId: researchSession.sessionId,
          );
    final message = messageFromSosPacket(packet, rxAtMs);
    final existing = await _dbHelper.getLatestMessageForSender(
      senderId: message.senderId,
      senderCrc: message.senderCrc,
    );
    final topologyDecision = _topologyPolicy.evaluate(
      packet: packet,
      session: researchSession,
      existingMessage: existing,
      observerKey: observerKey,
      trialStartedAt: researchTrial?.startedAt,
    );
    if (topologyDecision.isTopologyIgnored) {
      await _dbHelper.completeBleObservation(observationId, now);
      await _experimentLogger.logEvent(
        eventType: ExperimentEventTypes.topologyIgnored,
        deviceId: SyncService().deviceId,
        senderCrc: packet.senderCrc,
        hopIn: packet.hopCount,
        rssi: rssi,
        payloadHash: packet.identity,
        eventTimestampMs: rxAtMs,
        elapsedRealtimeMs: receivedElapsedRealtimeMs,
        protocolTimestampMs: packet.timestampMs,
        packetType: 'sos',
        status: packet.status.name,
        messageKey: packet.messageKey.value,
        stateIdentity: packet.stateIdentity.value,
        observationId: observationId,
        detail: {'reason': topologyDecision.reason},
      );
      return BleProcessingResult.stale;
    }
    final suppressedByAck = await _dbHelper.isSuppressedByAckTombstone(
      senderCrc: packet.senderCrc,
      sosTimestampMs: packet.timestampMs,
    );
    if (suppressedByAck) {
      await _dbHelper.completeBleObservation(observationId, now);
      await _runPostCommitEffect(
        'ack_tombstone_suppressed_log',
        () => _experimentLogger.logEvent(
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
        ),
      );
      _log('ACK_TOMBSTONE_SUPPRESSED ${packet.identity}');
      return BleProcessingResult.suppressedByAck;
    }

    if (topologyDecision.countAsLogicalDuplicate && existing != null) {
      final duplicateRecord = await _relayQueue
          .recordLogicalDuplicateObservation(
            messageId: existing.id,
            observationId: observationId,
            observerKey: _trickleObserverKey(
              packet,
              deviceAddress,
              observerKey: observerKey,
            ),
            nowMs: _clock.monotonicTimeMs(),
            completedAtMs: now,
          );
      await _runPostCommitEffect(
        'parallel_relay_duplicate_log',
        () => _experimentLogger.logEvent(
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
          messageKey: packet.messageKey.value,
          stateIdentity: packet.stateIdentity.value,
          observationId: observationId,
          detail: {
            'reason': topologyDecision.reason,
            'trickle_consistency_eligible':
                topologyDecision.countAsTrickleConsistency,
            'trickle_observation_recorded': duplicateRecord.trickleRecorded,
          },
        ),
      );
      return BleProcessingResult.duplicate;
    }

    if (topologyDecision.countAsTrickleInconsistency && existing != null) {
      final inconsistency = await _relayQueue.recordTopologyInconsistency(
        messageId: existing.id,
        nowMs: _clock.monotonicTimeMs(),
        observationId: observationId,
        completedAtMs: now,
      );
      await _runPostCommitEffect(
        'parallel_relay_inconsistent_log',
        () => _logTrickleReset(
          message: existing,
          reason: inconsistency?.reason ?? 'parallel_relay_inconsistent_state',
          nowMs: _clock.monotonicTimeMs(),
          packet: packet,
          rssi: rssi,
          receivedAtMs: rxAtMs,
          receivedElapsedRealtimeMs: receivedElapsedRealtimeMs,
          deviceAddress: deviceAddress,
          observationId: observationId,
          observerKey: observerKey,
          resetPerformed: inconsistency?.resetPerformed ?? false,
        ),
      );
      return BleProcessingResult.stale;
    }

    final decision = _forwardingPolicy.decideSos(
      packet: packet,
      nowMs: now,
      existingMessage: existing,
      ownSenderCrc: crc32(SyncService().deviceId),
    );

    if (!decision.shouldStore) {
      if (decision.reason == ForwardingDecisionReason.dropDuplicate &&
          existing != null) {
        final duplicateRecord = await _relayQueue
            .recordLogicalDuplicateObservation(
              messageId: existing.id,
              observationId: observationId,
              observerKey: _trickleObserverKey(
                packet,
                deviceAddress,
                observerKey: observerKey,
              ),
              nowMs: _clock.monotonicTimeMs(),
              completedAtMs: now,
            );
        await _runPostCommitEffect(
          'simulated_logical_duplicate_post_commit_failure',
          () async {
            if (failAfterLogicalDuplicateCommitForTest) {
              throw StateError(
                'Simulated logical duplicate post-commit failure',
              );
            }
          },
        );
        await _runPostCommitEffect(
          'ble_packet_duplicate_log',
          () => _experimentLogger.logEvent(
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
              if (_relayQueue.mode == ForwardingMode.trickle)
                'trickle_observation_recorded': duplicateRecord.trickleRecorded,
              if (_relayQueue.mode == ForwardingMode.trickle &&
                  !duplicateRecord.trickleRecorded)
                'trickle_observation_ignored_reason':
                    'duplicate_or_delayed_old_interval_observation',
            },
          ),
        );
      } else if (decision.reason == ForwardingDecisionReason.dropStale) {
        await _dbHelper.completeBleObservation(observationId, now);
        await _runPostCommitEffect(
          'ble_packet_stale_log',
          () => _experimentLogger.logEvent(
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
          ),
        );
      } else {
        await _dbHelper.completeBleObservation(observationId, now);
      }
      await _runPostCommitEffect(
        'ble_relay_dropped_log',
        () => _experimentLogger.logEvent(
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
        ),
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
      nowMs: _clock.monotonicTimeMs(),
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
        processedObservationId: observationId,
        failAfterStoreForTest: failSosTransactionForTest,
        queueForRelay: topologyDecision.relay,
      );
    } catch (e) {
      await _runPostCommitEffect(
        'sos_transaction_rolled_back_log',
        () => _experimentLogger.logEvent(
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
        ),
      );
      rethrow;
    }
    if (!storeResult.stored) {
      await _dbHelper.completeBleObservation(observationId, now);
      _log('SOS_TRANSACTION_SKIPPED ${packet.identity}');
      return BleProcessingResult.stale;
    }
    await _dbHelper.completeBleObservation(observationId, now);
    await _runPostCommitEffect('simulated_sos_post_commit_failure', () async {
      if (failAfterSosDurableCommitForTest) {
        throw StateError('Simulated SOS post-commit failure');
      }
    });
    if (_relayQueue.mode == ForwardingMode.trickle) {
      await _runPostCommitEffect(
        'trickle_reset_log',
        () => _logTrickleReset(
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
        ),
      );
    }
    await _runPostCommitEffect(
      'sos_transaction_committed_log',
      () => _experimentLogger.logEvent(
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
      ),
    );
    await _runPostCommitEffect(
      'ble_packet_accepted_log',
      () => _experimentLogger.logEvent(
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
      ),
    );
    await _runPostCommitEffect(
      'ble_packet_stored_log',
      () => _experimentLogger.logEvent(
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
      ),
    );
    if (!topologyDecision.relay) {
      if (researchSession?.nodeRole?.toUpperCase() == 'DESTINATION') {
        await _experimentLogger.logEvent(
          eventType: ExperimentEventTypes.destinationFirstValidReceive,
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
          status: message.status.name,
          messageKey: packet.messageKey.value,
          stateIdentity: packet.stateIdentity.value,
          observationId: observationId,
          eventKey:
              'DESTINATION_FIRST_VALID_RECEIVE|${packet.messageKey.value}',
        );
      }
      return BleProcessingResult.accepted;
    }
    await _runPostCommitEffect('workmanager_register_sync_task', () async {
      if (failWorkManagerPostCommitForTest) {
        throw StateError('Simulated WorkManager post-commit failure');
      }
      await WorkManagerService.registerSyncTask();
    });

    if (isDeferredByCooldown) {
      await _runPostCommitEffect(
        'deferred_ble_relay_queued_log',
        () => _experimentLogger.logEvent(
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
          detail: {
            'deferred': true,
            'next_eligible_at': decision.nextEligibleAt,
          },
        ),
      );
      await _runPostCommitEffect(
        'deferred_advertise_latest_or_stop',
        _advertiser.advertiseLatestOrStop,
      );
      _log('${decision.reason.code} ${packet.identity}');
      await _runPostCommitEffect('gateway_sync_schedule', _tryGatewaySync);
      return BleProcessingResult.accepted;
    }

    if (!shouldRelayNow) {
      await _runPostCommitEffect(
        'sos_not_relayed_log',
        () => _experimentLogger.logEvent(
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
        ),
      );
      _log('${decision.reason.code} ${packet.identity}');
      await _runPostCommitEffect('gateway_sync_schedule', _tryGatewaySync);
      return BleProcessingResult.accepted;
    }

    await _runPostCommitEffect(
      'ble_relay_queued_log',
      () => _experimentLogger.logEvent(
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
      ),
    );
    await _runPostCommitEffect(
      'advertise_latest_or_stop',
      _advertiser.advertiseLatestOrStop,
    );
    _log('${decision.reason.code} ${packet.identity} hop=${message.hopCount}');
    await _runPostCommitEffect('gateway_sync_schedule', _tryGatewaySync);
    return BleProcessingResult.accepted;
  }

  Future<void> _runPostCommitEffect(
    String operation,
    Future<void> Function() effect,
  ) async {
    try {
      await effect();
    } catch (e) {
      _log('Post-commit BLE side effect failed ($operation): $e');
    }
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
    if (_relayQueue.mode != ForwardingMode.trickle) return;
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
    if (failGatewayPostCommitForTest) {
      throw StateError('Simulated gateway post-commit failure');
    }
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
        _relayQueue.mode == ForwardingMode.trickle
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
    if (_relayQueue.mode == ForwardingMode.trickle) {
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
