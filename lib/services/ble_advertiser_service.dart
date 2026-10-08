import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:pkmproject/config/mesh_config.dart';
import 'package:pkmproject/models/ack_apply_result.dart';
import 'package:pkmproject/models/relay_queue_item.dart';
import 'package:pkmproject/models/sos_message.dart';
import 'package:pkmproject/models/message_identity.dart';
import 'package:pkmproject/models/trickle_state.dart';
import 'package:pkmproject/services/android_permission_service.dart';
import 'package:pkmproject/services/background_service_manager.dart';
import 'package:pkmproject/services/ble_protocol.dart';
import 'package:pkmproject/services/database_helper.dart';
import 'package:pkmproject/services/experiment_logger.dart';
import 'package:pkmproject/services/experiment_clock.dart';
import 'package:pkmproject/services/native_bridge_service.dart';
import 'package:pkmproject/services/relay_queue_service.dart';
import 'package:pkmproject/services/neighbor_runtime.dart';
import 'package:pkmproject/services/neighbor_transport.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

class BleAdvertiserService {
  static final BleAdvertiserService _instance =
      BleAdvertiserService._internal();
  factory BleAdvertiserService() => _instance;
  BleAdvertiserService._internal()
    : _relayQueue = RelayQueueService(),
      _experimentLogger = ExperimentLogger(),
      _clock = ExperimentClock.instance,
      _readNeighborInventory = NeighborRuntime.instance.inventoryStates,
      _readMessage = DatabaseHelper().getMessageById;

  BleAdvertiserService.forTesting({
    required RelayQueueService relayQueue,
    required ExperimentLogger experimentLogger,
    required ClockSource clock,
    required Future<SOSMessage?> Function(String) readMessage,
    Future<List<StateIdentity>> Function()? readNeighborInventory,
  }) : _relayQueue = relayQueue,
       _experimentLogger = experimentLogger,
       _clock = clock,
       _readNeighborInventory =
           readNeighborInventory ?? NeighborRuntime.instance.inventoryStates,
       _readMessage = readMessage;

  static const String kResqMeshServiceUuidString =
      "000021FE-0000-1000-8000-00805F9B34FB";
  static const MethodChannel _nativeChannel = MethodChannel(
    'id.ac.usu.resqmesh/mesh',
  );
  static const String _pendingAckPrefsKey = 'pending_ble_ack_packets';
  static const bool _debugVisibleAdvertising = bool.fromEnvironment(
    'RESQMESH_BLE_DEBUG_VISIBLE',
    defaultValue: false,
  );
  static const Duration minTransientRetryDelay = Duration(seconds: 15);

  final RelayQueueService _relayQueue;
  final ExperimentLogger _experimentLogger;
  final ClockSource _clock;
  final Future<SOSMessage?> Function(String) _readMessage;
  final Future<List<StateIdentity>> Function() _readNeighborInventory;
  final _isAdvertisingController = StreamController<bool>.broadcast();

  Stream<bool> get onAdvertisingChanged => _isAdvertisingController.stream;

  bool _isAdvertising = false;
  bool get isAdvertising => _isAdvertising;

  String? _currentAdvertisedMessageId;
  String? _currentBurstId;
  int? _currentBurstStartedWallMs;
  int? _currentBurstStartedMonotonicMs;
  int? _currentBurstTargetDurationMs;
  String? _currentBurstPacketType;
  int? _currentBurstHopOut;
  int? _currentBurstSenderCrc;
  int? _currentBurstProtocolTimestampMs;
  String? _currentBurstMessageKey;
  String? _currentBurstStateIdentity;
  String? _currentBurstStatus;
  NeighborFrame? _currentNeighborFrame;
  Timer? _watchdogTimer;
  Timer? _ackRestoreTimer;
  Timer? _slotTimer;
  bool _isSchedulerOwner = false;
  bool _isSelecting = false;
  bool _pendingTrickleTick = false;
  List<Future<void> Function()>? _schedulerDiagnostics;
  Future<void> Function()? _pendingQueueWakeDiagnostic;
  bool _researchObservationPaused = false;
  Timer? _queueWakeTimer;
  RelaySchedulerState _schedulerState = RelaySchedulerState.stopped;
  int _transientFailureCount = 0;
  bool get isSchedulerOwner => _isSchedulerOwner;
  RelaySchedulerState get schedulerState => _schedulerState;
  bool get researchObservationPaused => _researchObservationPaused;
  String? get currentAdvertisedMessageId => _currentAdvertisedMessageId;

  static bool shouldLogSourceFirstAdvertise(SOSMessage message) =>
      message.hopCount == 1 &&
      (message.trialId?.trim().isNotEmpty == true ||
          message.id.startsWith('research-'));

  void claimSchedulerOwnership() {
    _isSchedulerOwner = true;
  }

  void releaseSchedulerOwnership() {
    _isSchedulerOwner = false;
    _pendingTrickleTick = false;
    _pendingQueueWakeDiagnostic = null;
    _cancelQueueWakeTimer();
  }

  Future<bool> _requestPermissions() async {
    try {
      return await AndroidPermissionService.areCriticalPermissionsGranted();
    } catch (_) {
      return true;
    }
  }

  Future<bool> isNativeAdvertising() async {
    try {
      return await _nativeChannel.invokeMethod<bool>(
            'isNativeBleAdvertising',
          ) ??
          false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _startNativePayload(Uint8List payload) async {
    final success = await _nativeChannel
        .invokeMethod<bool>('startNativeBleAdvertising', {
          'payload': base64Encode(payload),
          'debugVisible': _debugVisibleAdvertising,
          'connectable': MeshConfig.connectableAdvertising,
        });
    return success == true;
  }

  Future<Map<String, dynamic>> nativeAdvertisingStatus() async {
    try {
      final status = await _nativeChannel.invokeMapMethod<String, dynamic>(
        'getNativeBleAdvertisingStatus',
      );
      return status ?? const {'status': 'unknown', 'active': false};
    } catch (_) {
      return const {'status': 'unknown', 'active': false};
    }
  }

  Future<void> reconcileNativeAdvertisingState() async {
    final nativeStatus = await nativeAdvertisingStatus();
    final nativeActive = nativeStatus['active'] == true;
    if (_isAdvertising == nativeActive) return;

    await _experimentLogger.logEvent(
      eventType: ExperimentEventTypes.bleStateReconciled,
      deviceId: 'unknown',
      messageId: _currentAdvertisedMessageId,
      detail: {
        'dart_active': _isAdvertising,
        'native_active': nativeActive,
        'native_state': nativeStatus['status'],
        'scheduler_state': _schedulerState.name,
      },
    );

    if (nativeActive) {
      _isAdvertising = true;
      _setSchedulerState(RelaySchedulerState.advertising);
      _isAdvertisingController.add(_isAdvertising);
      _startSlotTimer();
      return;
    }

    _markAdvertisingInactive();
    _setSchedulerState(RelaySchedulerState.failedRetryable);
    await _scheduleNextQueueWake();
  }

  void _startWatchdog() {
    _watchdogTimer?.cancel();
    _watchdogTimer = Timer.periodic(const Duration(seconds: 30), (_) async {
      if (!_isAdvertising) {
        _stopWatchdog();
        return;
      }

      final actualNative = await isNativeAdvertising();
      if (!actualNative) {
        print("[BleAdvertiserService] Watchdog restarting BLE advertising.");
        await reconcileNativeAdvertisingState();
      }
    });
  }

  void _stopWatchdog() {
    _watchdogTimer?.cancel();
    _watchdogTimer = null;
  }

  void _startSlotTimer() {
    _slotTimer?.cancel();
    if (_researchObservationPaused) return;
    _slotTimer = Timer(
      _relayQueue.slotDurationForMode(),
      () => advertiseLatestOrStop(preemptCurrent: true),
    );
  }

  void _stopSlotTimer() {
    _slotTimer?.cancel();
    _slotTimer = null;
  }

  void _setSchedulerState(RelaySchedulerState state) {
    _schedulerState = state;
  }

  void _cancelQueueWakeTimer() {
    if (_queueWakeTimer == null) return;
    _queueWakeTimer?.cancel();
    _queueWakeTimer = null;
    final state = _schedulerState.name;
    _schedulerDiagnostic(
      (wall, monotonic) => _experimentLogger.logEvent(
        eventType: ExperimentEventTypes.queueWakeCancelled,
        deviceId: 'unknown',
        eventTimestampMs: wall,
        elapsedRealtimeMs: monotonic,
        detail: {'scheduler_state': state},
      ),
    );
  }

  Future<void> _schedulerDiagnostic(
    Future<void> Function(int? wall, int? monotonic) record,
  ) {
    if (!_relayQueue.mode.usesTrickle) return record(null, null);
    final wall = _clock.wallTimeMs();
    final monotonic = _clock.monotonicTimeMs();
    // Defer diagnostics, not protocol writes, through selection/native request.
    final pending = _schedulerDiagnostics;
    if (pending == null) return record(wall, monotonic);
    pending.add(() => record(wall, monotonic));
    return Future<void>.value();
  }

  Future<void> _publishPendingRelayWork() async {
    await NativeBridgeService.setHasPendingRelayWork(
      await _relayQueue.hasActiveItems() ||
          NeighborRuntime.instance.statusEnabled,
    );
  }

  Future<void> _scheduleNextQueueWake() async {
    _cancelQueueWakeTimer();
    await _publishPendingRelayWork();
    if (_researchObservationPaused) {
      _setSchedulerState(RelaySchedulerState.stopped);
      return;
    }
    if (_isBlockedSchedulerState) return;
    if (_isAdvertising) {
      _setSchedulerState(RelaySchedulerState.advertising);
      return;
    }
    var earliest = await _relayQueue.earliestNextEligibleAt();
    final runtime = NeighborRuntime.instance;
    await runtime.load();
    if (runtime.statusEnabled &&
        (earliest == null || runtime.nextStatusAt < earliest)) {
      earliest = runtime.nextStatusAt;
    }
    if (earliest == null) {
      _setSchedulerState(
        _isAdvertising
            ? RelaySchedulerState.advertising
            : RelaySchedulerState.stopped,
      );
      await _experimentLogger.logEvent(
        eventType: ExperimentEventTypes.queueEmpty,
        deviceId: 'unknown',
        detail: {'scheduler_state': _schedulerState.name},
      );
      return;
    }

    final now = _clock.monotonicTimeMs();
    final deadline = earliest;
    final delayMs = earliest <= now ? 0 : earliest - now;
    _setSchedulerState(RelaySchedulerState.waitingNextSlot);
    final schedulerState = _schedulerState.name;
    void armWakeTimer() {
      final delay = _relayQueue.mode.usesTrickle
          ? remainingQueueWakeDelay(
              deadlineMs: deadline,
              nowMs: _clock.monotonicTimeMs(),
            )
          : Duration(milliseconds: delayMs);
      _queueWakeTimer = Timer(delay, () async {
        if (_relayQueue.mode.usesTrickle) {
          _queueWakeTimer = null;
          final wall = _clock.wallTimeMs();
          final monotonic = _clock.monotonicTimeMs();
          _pendingQueueWakeDiagnostic = () => _experimentLogger.logEvent(
            eventType: ExperimentEventTypes.queueWakeTriggered,
            deviceId: 'unknown',
            eventTimestampMs: wall,
            elapsedRealtimeMs: monotonic,
            detail: {'next_eligible_at': earliest},
          );
        } else {
          await _experimentLogger.logEvent(
            eventType: ExperimentEventTypes.queueWakeTriggered,
            deviceId: 'unknown',
            detail: {'next_eligible_at': earliest},
          );
        }
        await advertiseLatestOrStop(preemptCurrent: true);
      });
    }

    if (_relayQueue.mode.usesTrickle) armWakeTimer();
    if (delayMs > 0) {
      await _schedulerDiagnostic(
        (wall, monotonic) async => _experimentLogger.logEvent(
          eventType: ExperimentEventTypes.waitingNextEligible,
          deviceId: 'unknown',
          eventTimestampMs: wall,
          elapsedRealtimeMs: monotonic,
          detail: {
            'next_eligible_at': earliest,
            'delay_ms': delayMs,
            'queue_size': await _relayQueue.queueSize(),
          },
        ),
      );
    }
    await _schedulerDiagnostic(
      (wall, monotonic) async => _experimentLogger.logEvent(
        eventType: deadline <= now
            ? ExperimentEventTypes.queueWakeTriggered
            : ExperimentEventTypes.queueWakeScheduled,
        deviceId: 'unknown',
        eventTimestampMs: wall,
        elapsedRealtimeMs: monotonic,
        detail: {
          'next_eligible_at': earliest,
          'delay_ms': delayMs,
          'scheduler_state': schedulerState,
          'queue_size': await _relayQueue.queueSize(),
        },
      ),
    );
    if (!_relayQueue.mode.usesTrickle) armWakeTimer();
  }

  static Duration remainingQueueWakeDelay({
    required int deadlineMs,
    required int nowMs,
  }) {
    return Duration(milliseconds: deadlineMs > nowMs ? deadlineMs - nowMs : 0);
  }

  bool get _isBlockedSchedulerState =>
      _schedulerState == RelaySchedulerState.failedPermission ||
      _schedulerState == RelaySchedulerState.failedBluetoothDisabled ||
      _schedulerState == RelaySchedulerState.failedUnsupported;

  void _enterBlockedState(RelaySchedulerState state) {
    _cancelQueueWakeTimer();
    _setSchedulerState(state);
    _experimentLogger.logEvent(
      eventType: ExperimentEventTypes.schedulerBlocked,
      deviceId: 'unknown',
      detail: {'scheduler_state': state.name},
    );
  }

  Duration _nextTransientRetryDelay() {
    return transientRetryDelayForAttempt(_transientFailureCount++);
  }

  void _resetTransientRetry() {
    _transientFailureCount = 0;
  }

  Future<String?> _lastNativeAdvertiseErrorCode() async {
    final status = await nativeAdvertisingStatus();
    return status['errorCode'] as String?;
  }

  RelaySchedulerState? _blockedStateForNativeError(String? errorCode) {
    return blockedStateForNativeAdvertiseError(errorCode);
  }

  static Duration transientRetryDelayForAttempt(int failureCount) {
    final shift = failureCount.clamp(0, 8);
    final seconds = minTransientRetryDelay.inSeconds * (1 << shift);
    return Duration(seconds: seconds > 300 ? 300 : seconds);
  }

  static RelaySchedulerState? blockedStateForNativeAdvertiseError(
    String? errorCode,
  ) {
    return switch (errorCode) {
      'MISSING_PERMISSION' => RelaySchedulerState.failedPermission,
      'BLUETOOTH_UNAVAILABLE' ||
      'BLUETOOTH_DISABLED' => RelaySchedulerState.failedBluetoothDisabled,
      'FEATURE_UNSUPPORTED' => RelaySchedulerState.failedUnsupported,
      _ => null,
    };
  }

  Future<void> startAdvertising({SOSMessage? sosMessage}) async {
    if (sosMessage != null) {
      await enqueueSosForAdvertising(sosMessage, preemptCurrent: true);
      return;
    }
    await advertiseLatestOrStop(preemptCurrent: true);
  }

  Future<void> resumeAfterEnvironmentChange() async {
    await _experimentLogger.logEvent(
      eventType: ExperimentEventTypes.schedulerEnvironmentResumed,
      deviceId: 'unknown',
      detail: {'previous_state': _schedulerState.name},
    );
    _resetTransientRetry();
    if (!_isSchedulerOwner) {
      await BackgroundServiceManager.requestSchedulerTick();
      return;
    }
    await advertiseLatestOrStop(preemptCurrent: true);
  }

  void resumeResearchObservationWindow() {
    _researchObservationPaused = false;
  }

  Future<void> pauseResearchObservationWindow() async {
    _researchObservationPaused = true;
    await stopAdvertising(stopReason: 'OBSERVATION_WINDOW_ENDED');
    _setSchedulerState(RelaySchedulerState.stopped);
  }

  Future<bool> advertiseOneHeadlessSlot() async {
    final wasOwner = _isSchedulerOwner;
    claimSchedulerOwnership();
    await advertiseLatestOrStop(
      preemptCurrent: true,
      continueScheduling: false,
    );
    final started = await isNativeAdvertising();
    if (started) {
      await Future<void>.delayed(_relayQueue.slotDurationForMode());
      await stopAdvertising();
    }
    if (!wasOwner) releaseSchedulerOwnership();
    await _publishPendingRelayWork();
    return started;
  }

  Future<void> enqueueSosForAdvertising(
    SOSMessage message, {
    int priority = 0,
    int? nextEligibleAt,
    bool preemptCurrent = false,
  }) async {
    await _relayQueue.storeAndQueueSos(
      message: message,
      priority: priority,
      nextEligibleAt: nextEligibleAt ?? 0,
    );
    await _publishPendingRelayWork();
    await advertiseLatestOrStop(preemptCurrent: preemptCurrent);
  }

  Future<void> advertiseAckFor({
    required int senderCrc,
    required int ackTimestampMs,
    SOSMessageStatus status = SOSMessageStatus.resolved,
    int hopCount = 0,
    Duration? duration,
  }) async {
    final result = await _relayQueue.acceptAndQueueAck(
      senderCrc: senderCrc,
      ackTimestampMs: ackTimestampMs,
      status: status,
      hopCount: hopCount,
    );
    if (result.shouldRelay) {
      await _publishPendingRelayWork();
      await advertiseLatestOrStop(
        preemptCurrent: true,
        ackSlotDuration: duration,
      );
    }
  }

  Future<void> advertiseLatestOrStop({
    bool preemptCurrent = false,
    Duration? ackSlotDuration,
    bool continueScheduling = true,
  }) async {
    if (!_isSchedulerOwner) {
      await BackgroundServiceManager.requestSchedulerTick();
      return;
    }

    if (_researchObservationPaused) {
      await stopAdvertising();
      _setSchedulerState(RelaySchedulerState.stopped);
      return;
    }

    if (_isSelecting) {
      if (_relayQueue.mode.usesTrickle) _pendingTrickleTick = true;
      return;
    }
    _isSelecting = true;
    if (_relayQueue.mode.usesTrickle) {
      _schedulerDiagnostics = [];
      final wakeDiagnostic = _pendingQueueWakeDiagnostic;
      _pendingQueueWakeDiagnostic = null;
      if (wakeDiagnostic != null) _schedulerDiagnostics!.add(wakeDiagnostic);
    }
    _setSchedulerState(RelaySchedulerState.selecting);

    try {
      _cancelQueueWakeTimer();
      _ackRestoreTimer?.cancel();
      _stopSlotTimer();

      final pendingAck = await _takePendingAck();
      if (pendingAck != null) {
        final packet = BlePacket.unpack(pendingAck);
        if (packet != null && packet.isAck) {
          await _relayQueue.enqueueAck(
            messageId: RelayQueueService.ackMessageId(
              senderCrc: packet.senderCrc,
              ackTimestampMs: packet.timestampMs,
              statusIndex: packet.status.index,
            ),
            payloadBase64: base64Encode(pendingAck),
          );
        }
      }

      if (_isAdvertising) {
        if (!preemptCurrent && await isNativeAdvertising()) {
          _setSchedulerState(RelaySchedulerState.advertising);
          if (continueScheduling) _startSlotTimer();
          return;
        }
        await stopAdvertising();
      }

      if (!await _requestPermissions()) {
        print(
          "[BleAdvertiserService] BLE advertising permissions not granted.",
        );
        _enterBlockedState(RelaySchedulerState.failedPermission);
        return;
      }
      if (_researchObservationPaused) {
        await stopAdvertising();
        _setSchedulerState(RelaySchedulerState.stopped);
        return;
      }

      final runtime = NeighborRuntime.instance;
      await runtime.load();
      await runtime.synchronizeStatus(
        _clock.monotonicTimeMs(),
        readInventory: _readNeighborInventory,
      );
      await runtime.emitChanges(_clock.monotonicTimeMs());
      final queued = await _nextQueuedAdvertisement();
      final nextData = await _relayQueue.earliestNextEligibleAt();
      if (runtime.statusEnabled &&
          !runtime.mplEnabled &&
          nextData != null &&
          nextData > _clock.monotonicTimeMs() &&
          nextData <=
              _clock.monotonicTimeMs() +
                  runtime.controller!.parameters.statusBurstMs +
                  250 &&
          runtime.nextStatusAt <= _clock.monotonicTimeMs()) {
        runtime.nextStatusAt =
            nextData + _relayQueue.slotDurationForMode().inMilliseconds;
      }
      if (queued == null &&
          runtime.mplEnabled &&
          _clock.monotonicTimeMs() >= runtime.nextStatusAt &&
          !runtime.controller!.statusHasSlot(
            _clock.monotonicTimeMs(),
            nextData,
          )) {
        runtime.mpl!.controlDue(_clock.monotonicTimeMs(), slot: false);
        await runtime.emitChanges(_clock.monotonicTimeMs());
      }
      if (queued == null &&
          runtime.statusEnabled &&
          _clock.monotonicTimeMs() >= runtime.nextStatusAt &&
          runtime.controller!.statusHasSlot(
            _clock.monotonicTimeMs(),
            nextData,
          )) {
        if (!runtime.mplEnabled ||
            runtime.mpl!.controlDue(_clock.monotonicTimeMs())) {
          await _startStatusBurst();
          return;
        }
      }
      if (_researchObservationPaused) {
        await stopAdvertising();
        _setSchedulerState(RelaySchedulerState.stopped);
        return;
      }
      if (queued?.payload != null) {
        await _startQueuedAck(
          queued!,
          duration: ackSlotDuration ?? _relayQueue.slotDurationForMode(),
          continueScheduling: continueScheduling,
        );
        return;
      }

      final message = queued?.message;
      if (message == null) {
        await stopAdvertising();
        await _scheduleNextQueueWake();
        return;
      }
      await _startQueuedSos(queued!, continueScheduling: continueScheduling);
    } finally {
      final diagnostics = _schedulerDiagnostics;
      _schedulerDiagnostics = null;
      _isSelecting = false;
      if (_pendingTrickleTick) {
        _pendingTrickleTick = false;
        if (continueScheduling &&
            _isSchedulerOwner &&
            !_researchObservationPaused &&
            !_isAdvertising) {
          _queueWakeTimer?.cancel();
          _queueWakeTimer = Timer(Duration.zero, () => advertiseLatestOrStop());
        }
      }
      if (diagnostics != null) {
        for (final record in diagnostics) {
          try {
            await record();
          } catch (error) {
            print('[BleAdvertiserService] Scheduler diagnostic failed: $error');
          }
        }
      }
    }
  }

  Future<void> flushPendingAck() => advertiseLatestOrStop();

  Future<void> stopAdvertisingForMessage(String messageId) async {
    if (_currentAdvertisedMessageId == messageId) {
      await stopAdvertising();
      await advertiseLatestOrStop();
    }
  }

  Future<void> stopAdvertisingIfCurrentMessage(String messageId) async {
    if (_currentAdvertisedMessageId == messageId) {
      await stopAdvertising();
    }
  }

  Future<void> stopAdvertising({String? stopReason}) async {
    _ackRestoreTimer?.cancel();
    _cancelQueueWakeTimer();
    _stopSlotTimer();
    _stopWatchdog();

    if (!_isAdvertising) return;

    try {
      await _nativeChannel.invokeMethod('stopNativeBleAdvertising');
    } catch (e) {
      print("[BleAdvertiserService] Native stop failed: $e");
    }

    await _logCurrentBurstEnded(stopReason: stopReason);

    _isAdvertising = false;
    _currentAdvertisedMessageId = null;
    _isAdvertisingController.add(_isAdvertising);
  }

  Future<_QueuedAdvertisement?> _nextQueuedAdvertisement() async {
    final now = _clock.monotonicTimeMs();
    for (var attempt = 0; attempt < 20; attempt++) {
      final item = await _relayQueue.nextEligible(now);
      if (item == null) return null;

      if (item.isAck) {
        if (item.payloadBase64 == null) {
          await _relayQueue.removeItem(item);
          await _scheduleNextQueueWake();
          continue;
        }
        await _logSchedulerSelection(item);
        return _QueuedAdvertisement(item: item, payload: item.payloadBase64);
      }

      final message = await _readMessage(item.messageId);
      if (message == null ||
          message.ackReceivedAt != null ||
          message.localState == 'acked' ||
          message.localState == 'synced') {
        await _relayQueue.removeItem(item);
        await _scheduleNextQueueWake();
        continue;
      }
      await _logSchedulerSelection(item);
      return _QueuedAdvertisement(item: item, message: message);
    }
    return null;
  }

  Future<void> _logSchedulerSelection(RelayQueueItem item) async {
    await _schedulerDiagnostic(
      (wall, monotonic) async => _experimentLogger.logEvent(
        eventType: ExperimentEventTypes.schedulerPacketSelected,
        deviceId: 'unknown',
        messageId: item.isSos ? item.messageId : null,
        eventTimestampMs: wall,
        elapsedRealtimeMs: monotonic,
        detail: {
          'packet_type': item.packetType,
          'relay_count': item.relayCount,
          'queue_state': item.queueState,
          'forwarding_mode': _relayQueue.mode.logValue,
          'ack_queue_size': await _relayQueue.queueSizeByType('ack'),
          'sos_queue_size': await _relayQueue.queueSizeByType('sos'),
        },
      ),
    );
  }

  Future<void> _logTrickleDecision(
    SOSMessage message,
    TrickleTransmitDecision decision, {
    int? decisionWallMs,
  }) async {
    final state = decision.state;
    final neighborReason =
        _relayQueue.mode == ForwardingMode.trickleNeighborStatus
        ? _relayQueue.neighborDecisionReason(message.id)
        : null;
    final decisionAtMs =
        decisionWallMs ??
        _clock.wallTimeMs() - (_clock.monotonicTimeMs() - state.updatedAt);
    final detail = {
      'suppression_enabled': _relayQueue.mode.suppressionEnabled,
      'decision': switch (decision.type) {
        TrickleTransmitDecisionType.allowTransmit => 'allowed',
        TrickleTransmitDecisionType.suppressTransmit => 'suppressed',
        _ => 'waiting',
      },
      'reason':
          neighborReason ??
          switch (decision.type) {
            TrickleTransmitDecisionType.allowTransmit =>
              _relayQueue.mode.suppressionEnabled
                  ? 'C_LT_K'
                  : 'SUPPRESSION_DISABLED',
            TrickleTransmitDecisionType.suppressTransmit => 'C_GE_K',
            _ => 'INTERVAL_WAIT',
          },
      'I': state.intervalMs,
      'Imin': MeshConfig.trickleImin.inMilliseconds,
      'Imax': MeshConfig.trickleImax.inMilliseconds,
      'k': MeshConfig.trickleRedundancyConstant,
      'c': state.consistencyCount,
      'transmit_at': state.transmitAt,
      'interval_started_at': state.intervalStartedAt,
      'interval_end_at': state.intervalEndAt,
      'phase': state.phase,
      'next_eligible_at': decision.nextEligibleAt,
      'reset_reason': state.lastResetReason,
    };
    if (decision.type == TrickleTransmitDecisionType.allowTransmit ||
        decision.type == TrickleTransmitDecisionType.suppressTransmit) {
      if (neighborReason != null) {
        final knowledge = NeighborRuntime.instance.controller!.snapshot(
          message.stateIdentity,
          state.updatedAt,
        );
        await NeighborRuntime.instance.log(
          decision.shouldAdvertise
              ? 'NEIGHBOR_TX_ALLOWED'
              : 'NEIGHBOR_TX_SUPPRESSED',
          state: message.stateIdentity,
          reason: neighborReason,
          monotonic: state.updatedAt,
          receivedAt: decisionAtMs,
          detail: {
            'have_count': knowledge.values
                .where((v) => v.name == 'have')
                .length,
            'missing_count': knowledge.values
                .where((v) => v.name == 'missing')
                .length,
            'unknown_count': knowledge.values
                .where((v) => v.name == 'unknown')
                .length,
            'neighbors': NeighborRuntime.instance.controller!
                .snapshot(message.stateIdentity, state.updatedAt)
                .map((k, v) => MapEntry(k.toString(), v.name)),
            'neighbor_knowledge': knowledge.map(
              (k, v) => MapEntry(k.toString(), v.name.toUpperCase()),
            ),
          },
        );
      }
      await _experimentLogger.logEvent(
        eventType: ExperimentEventTypes.trickleTxOpportunity,
        deviceId: 'unknown',
        messageId: message.id,
        senderCrc: message.senderCrc,
        protocolTimestampMs: message.updatedAt,
        packetType: 'sos',
        status: message.status.name,
        elapsedRealtimeMs: state.updatedAt,
        eventTimestampMs: decisionAtMs,
        detail: detail,
      );
    }
    final eventType = switch (decision.type) {
      TrickleTransmitDecisionType.allowTransmit =>
        ExperimentEventTypes.trickleTxAllowed,
      TrickleTransmitDecisionType.suppressTransmit =>
        ExperimentEventTypes.trickleTxSuppressed,
      TrickleTransmitDecisionType.intervalAdvanced =>
        ExperimentEventTypes.trickleIntervalDoubled,
      TrickleTransmitDecisionType.wait =>
        ExperimentEventTypes.waitingNextEligible,
    };
    await _experimentLogger.logEvent(
      eventType: eventType,
      deviceId: 'unknown',
      messageId: message.id,
      senderCrc: message.senderCrc,
      hopCount: message.hopCount,
      elapsedRealtimeMs: state.updatedAt,
      eventTimestampMs: decisionAtMs,
      packetType: 'sos',
      status: message.status.name,
      detail: detail,
    );
    if (decision.type == TrickleTransmitDecisionType.intervalAdvanced) {
      await _experimentLogger.logEvent(
        eventType: ExperimentEventTypes.trickleIntervalStarted,
        deviceId: 'unknown',
        messageId: message.id,
        senderCrc: message.senderCrc,
        hopCount: message.hopCount,
        eventTimestampMs: decisionAtMs,
        elapsedRealtimeMs: state.updatedAt,
        packetType: 'sos',
        status: message.status.name,
        detail: detail,
      );
    }
  }

  Future<void> _startQueuedSos(
    _QueuedAdvertisement queued, {
    bool continueScheduling = true,
  }) async {
    final message = queued.message;
    if (message == null) return;

    final now = _clock.monotonicTimeMs();
    final originalNextEligibleAt = queued.item.nextEligibleAt;
    TrickleTransmitDecision? trickleDecision;
    if (_relayQueue.mode.usesTrickle) {
      trickleDecision = await _relayQueue.handleTrickleQueueEvent(
        item: queued.item,
        nowMs: now,
      );
      final decision = trickleDecision;
      if (_relayQueue.mode != ForwardingMode.trickleMpl) {
        await _schedulerDiagnostic(
          (wall, monotonic) => _logTrickleDecision(
            message,
            decision,
            decisionWallMs: wall == null
                ? null
                : wall - (monotonic! - decision.state.updatedAt),
          ),
        );
      }
      if (!trickleDecision.shouldAdvertise) {
        await _scheduleNextQueueWake();
        return;
      }
    }

    final burstId = const Uuid().v4();
    final burstDuration = _relayQueue.slotDurationForMode();
    await _relayQueue.markAdvertisingStarted(
      queued.item,
      nowMs: now,
      slotDuration: burstDuration,
    );

    final inner = BlePacket.packSos(message);
    final runtime = NeighborRuntime.instance;
    await runtime.load();
    final mplToken = runtime.mpl?.data[message.stateIdentity.value]?.generation;
    final frame = runtime.enabled ? await runtime.frame(inner: inner) : null;
    final payload = frame?.encode() ?? inner;
    if (frame != null) {
      await _schedulerDiagnostic(
        (wall, monotonic) => runtime.log(
          'DATA_BURST_REQUESTED',
          frame: frame,
          state: message.stateIdentity,
          receivedAt: wall,
          monotonic: monotonic,
        ),
      );
    }
    final packet = BlePacket.unpack(
      inner,
      referenceTime: DateTime.fromMillisecondsSinceEpoch(message.updatedAt),
    );
    final payloadHash = packet?.identity;
    _currentAdvertisedMessageId = message.id;
    await _schedulerDiagnostic(
      (wall, monotonic) => _experimentLogger.logEvent(
        eventType: ExperimentEventTypes.bleAdvertiseRequested,
        deviceId: 'unknown',
        messageId: message.id,
        senderCrc: message.senderCrc,
        hopCount: message.hopCount,
        hopOut: message.hopCount,
        payloadHash: payloadHash,
        protocolTimestampMs: packet?.timestampMs,
        packetType: 'sos',
        status: message.status.name,
        eventTimestampMs: wall,
        elapsedRealtimeMs: monotonic,
      ),
    );
    await _schedulerDiagnostic(
      (wall, monotonic) => _experimentLogger.logEvent(
        eventType: ExperimentEventTypes.advertiseBurstRequested,
        deviceId: 'unknown',
        messageId: message.id,
        senderCrc: message.senderCrc,
        hopOut: message.hopCount,
        protocolTimestampMs: packet?.timestampMs,
        packetType: 'sos',
        status: message.status.name,
        messageKey: packet?.messageKey.value,
        stateIdentity: packet?.stateIdentity.value,
        burstId: burstId,
        eventTimestampMs: wall,
        elapsedRealtimeMs: monotonic ?? now,
        detail: {'target_duration_ms': burstDuration.inMilliseconds},
      ),
    );

    try {
      if (mplToken != null) {
        final timer = runtime.mpl!.data[message.stateIdentity.value];
        timer?.advance(_clock.monotonicTimeMs());
        if (timer == null ||
            timer.generation != mplToken ||
            !timer.active ||
            !timer.pending) {
          await _relayQueue.markAdvertisingBlocked(
            queued.item,
            restoreNextEligibleAt: timer?.nextAt ?? originalNextEligibleAt,
          );
          await runtime.emitChanges(_clock.monotonicTimeMs());
          await _scheduleNextQueueWake();
          return;
        }
        timer.log('NATIVE_REQUESTED', _clock.monotonicTimeMs());
      }
      if (await _startNativePayload(payload)) {
        final succeededAt = _clock.wallTimeMs();
        final succeededAtMonotonic = _clock.monotonicTimeMs();
        if (mplToken != null) {
          runtime.mpl!.dataResult(
            message.stateIdentity.value,
            mplToken,
            succeededAtMonotonic,
            true,
          );
        }
        _isAdvertising = true;
        if (frame != null) {
          runtime.controller!.started(message.stateIdentity);
          await runtime.dataStarted(
            message.stateIdentity,
            succeededAtMonotonic,
          );
          await runtime.log(
            'DATA_BURST_STARTED',
            frame: frame,
            state: message.stateIdentity,
            receivedAt: succeededAt,
            monotonic: succeededAtMonotonic,
          );
          if (queued.item.relayCount == 0 && runtime.statusEnabled) {
            await runtime.log(
              'INITIAL_FORWARD_STARTED',
              frame: frame,
              state: message.stateIdentity,
              receivedAt: succeededAt,
              monotonic: succeededAtMonotonic,
            );
          }
        }
        _rememberStartedBurst(
          burstId: burstId,
          wallMs: succeededAt,
          monotonicMs: succeededAtMonotonic,
          targetDuration: burstDuration,
          packetType: 'sos',
          hopOut: message.hopCount,
          senderCrc: message.senderCrc,
          protocolTimestampMs: packet?.timestampMs,
          messageKey: packet?.messageKey.value,
          stateIdentity: packet?.stateIdentity.value,
          status: message.status.name,
          neighborFrame: frame,
        );
        _setSchedulerState(RelaySchedulerState.advertising);
        _isAdvertisingController.add(_isAdvertising);
        _startWatchdog();
        await _relayQueue.markAdvertisingSucceeded(
          queued.item,
          nowMs: succeededAtMonotonic,
          slotDuration: _relayQueue.slotDurationForMode(),
          nextEligibleAtOverride:
              runtime.mpl?.data[message.stateIdentity.value]?.nextAt ??
              trickleDecision?.nextEligibleAt,
        );
        _resetTransientRetry();
        await _experimentLogger.logEvent(
          eventType: ExperimentEventTypes.bleAdvertiseStarted,
          deviceId: 'unknown',
          messageId: message.id,
          senderCrc: message.senderCrc,
          hopCount: message.hopCount,
          hopOut: message.hopCount,
          payloadHash: payloadHash,
          eventTimestampMs: succeededAt,
          elapsedRealtimeMs: succeededAtMonotonic,
          protocolTimestampMs: packet?.timestampMs,
          packetType: 'sos',
          status: message.status.name,
        );
        await _experimentLogger.logEvent(
          eventType: ExperimentEventTypes.advertiseBurstStarted,
          deviceId: 'unknown',
          messageId: message.id,
          senderCrc: message.senderCrc,
          hopOut: message.hopCount,
          eventTimestampMs: succeededAt,
          elapsedRealtimeMs: succeededAtMonotonic,
          protocolTimestampMs: packet?.timestampMs,
          packetType: 'sos',
          status: message.status.name,
          messageKey: packet?.messageKey.value,
          stateIdentity: packet?.stateIdentity.value,
          burstId: burstId,
          detail: {'target_duration_ms': burstDuration.inMilliseconds},
        );
        if (shouldLogSourceFirstAdvertise(message)) {
          await _experimentLogger.logEvent(
            eventType: ExperimentEventTypes.sourceFirstAdvertiseStarted,
            deviceId: 'unknown',
            messageId: message.id,
            senderCrc: message.senderCrc,
            eventTimestampMs: succeededAt,
            elapsedRealtimeMs: succeededAtMonotonic,
            protocolTimestampMs: packet?.timestampMs,
            packetType: 'sos',
            status: message.status.name,
            messageKey: packet?.messageKey.value,
            stateIdentity: packet?.stateIdentity.value,
            burstId: burstId,
            eventKey:
                'SOURCE_FIRST_ADVERTISE_STARTED|${packet?.messageKey.value}',
          );
        }
        await _experimentLogger.logEvent(
          eventType: ExperimentEventTypes.bleRelayStarted,
          deviceId: 'unknown',
          messageId: message.id,
          senderCrc: message.senderCrc,
          hopCount: message.hopCount,
          hopOut: message.hopCount,
          payloadHash: payloadHash,
          eventTimestampMs: succeededAt,
          elapsedRealtimeMs: succeededAtMonotonic,
          protocolTimestampMs: packet?.timestampMs,
          packetType: 'sos',
          status: message.status.name,
        );
        if (continueScheduling) {
          _startSlotTimer();
          await _scheduleNextQueueWake();
        } else {
          await _publishPendingRelayWork();
        }
        print(
          "[BleAdvertiserService] Started native BLE SOS advertising (${payload.length} bytes).",
        );
        return;
      }
    } catch (e) {
      print("[BleAdvertiserService] Native advertising unavailable: $e");
    }

    final errorCode = await _lastNativeAdvertiseErrorCode();
    if (mplToken != null) {
      runtime.mpl!.dataResult(
        message.stateIdentity.value,
        mplToken,
        _clock.monotonicTimeMs(),
        false,
      );
      await runtime.emitChanges(_clock.monotonicTimeMs());
    }
    if (frame != null) {
      await runtime.log(
        'DATA_BURST_FAILED',
        frame: frame,
        state: message.stateIdentity,
        reason: errorCode ?? 'NATIVE_START_FAILED',
      );
      if (runtime.statusEnabled && queued.item.relayCount == 0) {
        await runtime.log(
          'INITIAL_FORWARD_FAILED',
          frame: frame,
          state: message.stateIdentity,
          reason: errorCode ?? 'NATIVE_START_FAILED',
          detail: {'first_forward_pending': true},
        );
      }
      await _logScannerRecovery(frame, 'FAILED');
    }
    final blockedState = _blockedStateForNativeError(errorCode);
    if (blockedState == null) {
      await _relayQueue.markAdvertisingFailed(
        queued.item,
        nowMs: _clock.monotonicTimeMs(),
        retryDelay: mplToken == null
            ? _nextTransientRetryDelay()
            : Duration(
                milliseconds:
                    (runtime.mpl!.data[message.stateIdentity.value]!.nextAt -
                            _clock.monotonicTimeMs())
                        .clamp(0, 86400000),
              ),
      );
    } else {
      await _relayQueue.markAdvertisingBlocked(
        queued.item,
        restoreNextEligibleAt: originalNextEligibleAt,
      );
    }
    await _experimentLogger.logEvent(
      eventType: ExperimentEventTypes.bleAdvertiseFailed,
      deviceId: 'unknown',
      messageId: message.id,
      senderCrc: message.senderCrc,
      hopCount: message.hopCount,
      hopOut: message.hopCount,
      payloadHash: payloadHash,
      protocolTimestampMs: packet?.timestampMs,
      packetType: 'sos',
      status: message.status.name,
    );
    await _experimentLogger.logEvent(
      eventType: ExperimentEventTypes.advertiseBurstFailed,
      deviceId: 'unknown',
      messageId: message.id,
      senderCrc: message.senderCrc,
      hopOut: message.hopCount,
      protocolTimestampMs: packet?.timestampMs,
      packetType: 'sos',
      status: message.status.name,
      messageKey: packet?.messageKey.value,
      stateIdentity: packet?.stateIdentity.value,
      burstId: burstId,
      elapsedRealtimeMs: _clock.monotonicTimeMs(),
      detail: {'error_code': errorCode},
    );
    if (blockedState != null) {
      _enterBlockedState(blockedState);
    } else {
      _setSchedulerState(RelaySchedulerState.failedRetryable);
      await _scheduleNextQueueWake();
    }
    _markAdvertisingInactive();
  }

  Future<void> _startStatusBurst() async {
    final runtime = NeighborRuntime.instance;
    final mplToken = runtime.mpl?.control.generation;
    final inventoryToken = runtime.mpl?.inventoryGeneration;
    final frame = await runtime.statusFrame();
    final now = _clock.monotonicTimeMs();
    final inventory = runtime.statusSchedule?.inventory ?? <String>[];
    final statusReason =
        runtime.mpl?.control.reason ??
        runtime.statusSchedule?.reason ??
        'PERIODIC';
    runtime.statusAttempted(now);
    await runtime.log(
      'STATUS_BURST_REQUESTED',
      frame: frame,
      reason: statusReason,
    );
    try {
      if (mplToken != null) {
        final timer = runtime.mpl!.control;
        timer.advance(_clock.monotonicTimeMs());
        if (timer.generation != mplToken ||
            runtime.mpl!.inventoryGeneration != inventoryToken ||
            !timer.active ||
            !timer.pending) {
          await runtime.emitChanges(_clock.monotonicTimeMs());
          await _scheduleNextQueueWake();
          return;
        }
        timer.log('NATIVE_REQUESTED', _clock.monotonicTimeMs());
      }
      if (await _startNativePayload(frame.encode())) {
        final startedWall = _clock.wallTimeMs();
        final startedMonotonic = _clock.monotonicTimeMs();
        _isAdvertising = true;
        _currentAdvertisedMessageId = null;
        final duration = Duration(
          milliseconds: runtime.controller!.parameters.statusBurstMs,
        );
        _rememberStartedBurst(
          burstId: frame.burstIdentity,
          wallMs: startedWall,
          monotonicMs: startedMonotonic,
          targetDuration: duration,
          packetType: 'status',
          hopOut: 0,
          neighborFrame: frame,
        );
        await runtime.log(
          'STATUS_BURST_STARTED',
          frame: frame,
          receivedAt: startedWall,
          monotonic: startedMonotonic,
          reason: statusReason,
        );
        runtime.statusStarted(inventory, startedMonotonic);
        if (mplToken != null) {
          runtime.mpl!.controlResult(
            mplToken,
            inventoryToken!,
            startedMonotonic,
            true,
          );
        }
        await runtime.emitChanges(startedMonotonic);
        _isAdvertisingController.add(true);
        _slotTimer = Timer(duration, () async {
          await stopAdvertising();
          await advertiseLatestOrStop();
        });
        return;
      }
    } catch (_) {
      // Failure must retain the DATA queue and recover via the same owner.
    }
    runtime.statusFailed(_clock.monotonicTimeMs());
    if (mplToken != null) {
      runtime.mpl!.controlResult(
        mplToken,
        inventoryToken!,
        _clock.monotonicTimeMs(),
        false,
      );
    }
    await runtime.log(
      'STATUS_BURST_FAILED',
      frame: frame,
      reason: statusReason,
    );
    await _logScannerRecovery(frame, 'FAILED');
    await _scheduleNextQueueWake();
  }

  Future<void> _startQueuedAck(
    _QueuedAdvertisement queued, {
    Duration duration = MeshConfig.ackAdvertiseDuration,
    bool continueScheduling = true,
  }) async {
    final payloadBase64 = queued.payload;
    if (payloadBase64 == null) return;
    final payload = base64Decode(payloadBase64);
    final packet = BlePacket.unpack(payload);
    if (packet == null || !packet.isAck) {
      await _relayQueue.removeItem(queued.item);
      return;
    }

    _ackRestoreTimer?.cancel();
    _stopSlotTimer();
    final burstId = const Uuid().v4();
    final requestedMonotonic = _clock.monotonicTimeMs();
    final originalNextEligibleAt = queued.item.nextEligibleAt;
    await _relayQueue.markAdvertisingStarted(
      queued.item,
      nowMs: _clock.monotonicTimeMs(),
      slotDuration: duration,
    );
    await _experimentLogger.logEvent(
      eventType: ExperimentEventTypes.advertiseBurstRequested,
      deviceId: 'unknown',
      senderCrc: packet.senderCrc,
      hopOut: packet.hopCount,
      protocolTimestampMs: packet.timestampMs,
      packetType: 'ack',
      status: packet.status.name,
      messageKey: packet.messageKey.value,
      stateIdentity: packet.stateIdentity.value,
      burstId: burstId,
      elapsedRealtimeMs: requestedMonotonic,
      detail: {'target_duration_ms': duration.inMilliseconds},
    );

    try {
      if (await _startNativePayload(payload)) {
        final succeededAt = _clock.wallTimeMs();
        final succeededAtMonotonic = _clock.monotonicTimeMs();
        _isAdvertising = true;
        _setSchedulerState(RelaySchedulerState.advertising);
        _currentAdvertisedMessageId = null;
        _rememberStartedBurst(
          burstId: burstId,
          wallMs: succeededAt,
          monotonicMs: succeededAtMonotonic,
          targetDuration: duration,
          packetType: 'ack',
          hopOut: packet.hopCount,
          senderCrc: packet.senderCrc,
          protocolTimestampMs: packet.timestampMs,
          messageKey: packet.messageKey.value,
          stateIdentity: packet.stateIdentity.value,
          status: packet.status.name,
        );
        _isAdvertisingController.add(_isAdvertising);
        _startWatchdog();
        await _relayQueue.markAdvertisingSucceeded(
          queued.item,
          nowMs: succeededAtMonotonic,
          slotDuration: duration,
        );
        _resetTransientRetry();
        await _experimentLogger.logEvent(
          eventType: ExperimentEventTypes.bleAdvertiseStarted,
          deviceId: 'unknown',
          senderCrc: packet.senderCrc,
          hopCount: packet.hopCount,
          hopOut: packet.hopCount,
          payloadHash: packet.identity,
          eventTimestampMs: succeededAt,
          elapsedRealtimeMs: succeededAtMonotonic,
          protocolTimestampMs: packet.timestampMs,
          packetType: 'ack',
          status: packet.status.name,
          detail: {'kind': 'ack'},
        );
        await _experimentLogger.logEvent(
          eventType: ExperimentEventTypes.advertiseBurstStarted,
          deviceId: 'unknown',
          senderCrc: packet.senderCrc,
          hopOut: packet.hopCount,
          eventTimestampMs: succeededAt,
          elapsedRealtimeMs: succeededAtMonotonic,
          protocolTimestampMs: packet.timestampMs,
          packetType: 'ack',
          status: packet.status.name,
          messageKey: packet.messageKey.value,
          stateIdentity: packet.stateIdentity.value,
          burstId: burstId,
          detail: {'target_duration_ms': duration.inMilliseconds},
        );
        await _experimentLogger.logEvent(
          eventType: ExperimentEventTypes.bleRelayStarted,
          deviceId: 'unknown',
          senderCrc: packet.senderCrc,
          hopCount: packet.hopCount,
          hopOut: packet.hopCount,
          payloadHash: packet.identity,
          eventTimestampMs: succeededAt,
          elapsedRealtimeMs: succeededAtMonotonic,
          protocolTimestampMs: packet.timestampMs,
          packetType: 'ack',
          status: packet.status.name,
          detail: {'kind': 'ack'},
        );
        print("[BleAdvertiserService] Started queued BLE ACK advertising.");
        if (continueScheduling) {
          _ackRestoreTimer = Timer(duration, () {
            advertiseLatestOrStop(preemptCurrent: true);
          });
          await _scheduleNextQueueWake();
        } else {
          await _publishPendingRelayWork();
        }
        return;
      }
    } catch (e) {
      print("[BleAdvertiserService] Queued ACK advertising failed: $e");
    }

    final errorCode = await _lastNativeAdvertiseErrorCode();
    final blockedState = _blockedStateForNativeError(errorCode);
    if (blockedState == null) {
      await _relayQueue.markAdvertisingFailed(
        queued.item,
        nowMs: _clock.monotonicTimeMs(),
        retryDelay: _nextTransientRetryDelay(),
      );
    } else {
      await _relayQueue.markAdvertisingBlocked(
        queued.item,
        restoreNextEligibleAt: originalNextEligibleAt,
      );
    }
    await _experimentLogger.logEvent(
      eventType: ExperimentEventTypes.bleAdvertiseFailed,
      deviceId: 'unknown',
      senderCrc: packet.senderCrc,
      hopCount: packet.hopCount,
      hopOut: packet.hopCount,
      payloadHash: packet.identity,
      protocolTimestampMs: packet.timestampMs,
      packetType: 'ack',
      status: packet.status.name,
      detail: {'kind': 'ack'},
    );
    await _experimentLogger.logEvent(
      eventType: ExperimentEventTypes.advertiseBurstFailed,
      deviceId: 'unknown',
      senderCrc: packet.senderCrc,
      hopOut: packet.hopCount,
      protocolTimestampMs: packet.timestampMs,
      packetType: 'ack',
      status: packet.status.name,
      messageKey: packet.messageKey.value,
      stateIdentity: packet.stateIdentity.value,
      burstId: burstId,
      elapsedRealtimeMs: _clock.monotonicTimeMs(),
      detail: {'error_code': errorCode},
    );
    await _persistPendingAck(payload);
    if (blockedState != null) {
      _enterBlockedState(blockedState);
    } else {
      _setSchedulerState(RelaySchedulerState.failedRetryable);
      await _scheduleNextQueueWake();
    }
  }

  void _markAdvertisingInactive() {
    _isAdvertising = false;
    _currentAdvertisedMessageId = null;
    _isAdvertisingController.add(_isAdvertising);
  }

  void _rememberStartedBurst({
    required String burstId,
    required int wallMs,
    required int monotonicMs,
    required Duration targetDuration,
    required String packetType,
    required int hopOut,
    int? senderCrc,
    int? protocolTimestampMs,
    String? messageKey,
    String? stateIdentity,
    String? status,
    NeighborFrame? neighborFrame,
  }) {
    _currentBurstId = burstId;
    _currentBurstStartedWallMs = wallMs;
    _currentBurstStartedMonotonicMs = monotonicMs;
    _currentBurstTargetDurationMs = targetDuration.inMilliseconds;
    _currentBurstPacketType = packetType;
    _currentBurstHopOut = hopOut;
    _currentBurstSenderCrc = senderCrc;
    _currentBurstProtocolTimestampMs = protocolTimestampMs;
    _currentBurstMessageKey = messageKey;
    _currentBurstStateIdentity = stateIdentity;
    _currentBurstStatus = status;
    _currentNeighborFrame = neighborFrame;
  }

  static String burstStopReason({
    String? requestedReason,
    required int actualDurationMs,
    int? targetDurationMs,
  }) {
    if (requestedReason != null) return requestedReason;
    if (targetDurationMs != null && actualDurationMs >= targetDurationMs) {
      return 'TARGET_DURATION_REACHED';
    }
    return 'STOP_REQUESTED';
  }

  Future<void> _logCurrentBurstEnded({String? stopReason}) async {
    final burstId = _currentBurstId;
    final startedMonotonic = _currentBurstStartedMonotonicMs;
    if (burstId == null || startedMonotonic == null) return;
    final endedMonotonic = _clock.monotonicTimeMs();
    if (_currentNeighborFrame != null) {
      final frame = _currentNeighborFrame!;
      final reason = burstStopReason(
        requestedReason: stopReason,
        actualDurationMs: endedMonotonic - startedMonotonic,
        targetDurationMs: _currentBurstTargetDurationMs,
      );
      await NeighborRuntime.instance.log(
        '${frame.type == NeighborFrameType.data ? 'DATA' : 'STATUS'}_BURST_${reason == 'TARGET_DURATION_REACHED' ? 'ENDED' : 'CANCELLED'}',
        frame: frame,
        receivedAt: _clock.wallTimeMs(),
        monotonic: endedMonotonic,
        reason: reason,
        detail: {
          'actual_duration_ms': endedMonotonic - startedMonotonic,
          'target_duration_ms': _currentBurstTargetDurationMs,
        },
      );
      await _logScannerRecovery(
        frame,
        reason == 'TARGET_DURATION_REACHED' ? 'ENDED' : 'CANCELLED',
      );
    }
    await _experimentLogger.logEvent(
      eventType: ExperimentEventTypes.advertiseBurstEnded,
      deviceId: 'unknown',
      messageId: _currentAdvertisedMessageId,
      senderCrc: _currentBurstSenderCrc,
      hopOut: _currentBurstHopOut,
      eventTimestampMs: _clock.wallTimeMs(),
      elapsedRealtimeMs: endedMonotonic,
      protocolTimestampMs: _currentBurstProtocolTimestampMs,
      packetType: _currentBurstPacketType,
      status: _currentBurstStatus,
      messageKey: _currentBurstMessageKey,
      stateIdentity: _currentBurstStateIdentity,
      burstId: burstId,
      detail: {
        'started_wall_ms': _currentBurstStartedWallMs,
        'target_duration_ms': _currentBurstTargetDurationMs,
        'actual_duration_ms': endedMonotonic - startedMonotonic,
        'stop_reason': burstStopReason(
          requestedReason: stopReason,
          actualDurationMs: endedMonotonic - startedMonotonic,
          targetDurationMs: _currentBurstTargetDurationMs,
        ),
      },
    );
    _currentBurstId = null;
    _currentBurstStartedWallMs = null;
    _currentBurstStartedMonotonicMs = null;
    _currentBurstTargetDurationMs = null;
    _currentBurstPacketType = null;
    _currentBurstHopOut = null;
    _currentBurstSenderCrc = null;
    _currentBurstProtocolTimestampMs = null;
    _currentBurstMessageKey = null;
    _currentBurstStateIdentity = null;
    _currentBurstStatus = null;
    _currentNeighborFrame = null;
  }

  Future<void> _logScannerRecovery(NeighborFrame frame, String outcome) async {
    try {
      final capabilities = await NativeBridgeService.getBleCapabilities();
      await NeighborRuntime.instance.log(
        'SCANNER_RECOVERY_CHECK',
        frame: frame,
        monotonic: _clock.monotonicTimeMs(),
        detail: {
          'burst_outcome': outcome,
          'rx_enabled': true,
          'scanner_registered': capabilities['nativeScanActive'],
          'evidence_basis': 'API_REGISTRATION_NOT_RF_VERIFICATION',
        },
      );
    } catch (error) {
      print('[NeighborRuntime] Scanner diagnostic unavailable: $error');
    }
  }

  Future<void> _persistPendingAck(Uint8List payload) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final pending = prefs.getStringList(_pendingAckPrefsKey) ?? <String>[];
      final encoded = base64Encode(payload);
      if (!pending.contains(encoded)) {
        pending.add(encoded);
        await prefs.setStringList(_pendingAckPrefsKey, pending);
      }
    } catch (e) {
      print("[BleAdvertiserService] Failed to persist pending ACK: $e");
    }
  }

  Future<Uint8List?> _takePendingAck() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final pending = prefs.getStringList(_pendingAckPrefsKey) ?? <String>[];
      if (pending.isEmpty) return null;
      final first = pending.removeAt(0);
      await prefs.setStringList(_pendingAckPrefsKey, pending);
      return base64Decode(first);
    } catch (e) {
      print("[BleAdvertiserService] Failed to read pending ACK: $e");
      return null;
    }
  }

  void dispose() {
    _ackRestoreTimer?.cancel();
    _stopSlotTimer();
    _stopWatchdog();
    _isAdvertisingController.close();
  }
}

class _QueuedAdvertisement {
  final RelayQueueItem item;
  final SOSMessage? message;
  final String? payload;

  const _QueuedAdvertisement({required this.item, this.message, this.payload});
}
