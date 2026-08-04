import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:pkmproject/config/mesh_config.dart';
import 'package:pkmproject/models/ack_apply_result.dart';
import 'package:pkmproject/models/relay_queue_item.dart';
import 'package:pkmproject/models/sos_message.dart';
import 'package:pkmproject/services/android_permission_service.dart';
import 'package:pkmproject/services/background_service_manager.dart';
import 'package:pkmproject/services/ble_protocol.dart';
import 'package:pkmproject/services/database_helper.dart';
import 'package:pkmproject/services/experiment_logger.dart';
import 'package:pkmproject/services/native_bridge_service.dart';
import 'package:pkmproject/services/relay_queue_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class BleAdvertiserService {
  static final BleAdvertiserService _instance =
      BleAdvertiserService._internal();
  factory BleAdvertiserService() => _instance;
  BleAdvertiserService._internal();

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

  final DatabaseHelper _dbHelper = DatabaseHelper();
  final RelayQueueService _relayQueue = RelayQueueService();
  final ExperimentLogger _experimentLogger = ExperimentLogger();
  final _isAdvertisingController = StreamController<bool>.broadcast();

  Stream<bool> get onAdvertisingChanged => _isAdvertisingController.stream;

  bool _isAdvertising = false;
  bool get isAdvertising => _isAdvertising;

  String? _currentAdvertisedMessageId;
  Timer? _watchdogTimer;
  Timer? _ackRestoreTimer;
  Timer? _slotTimer;
  bool _isSchedulerOwner = false;
  bool _isSelecting = false;
  Timer? _queueWakeTimer;
  RelaySchedulerState _schedulerState = RelaySchedulerState.stopped;
  bool get isSchedulerOwner => _isSchedulerOwner;
  RelaySchedulerState get schedulerState => _schedulerState;
  String? get currentAdvertisedMessageId => _currentAdvertisedMessageId;

  void claimSchedulerOwnership() {
    _isSchedulerOwner = true;
  }

  void releaseSchedulerOwnership() {
    _isSchedulerOwner = false;
    _cancelQueueWakeTimer();
  }

  Future<bool> _requestPermissions() async {
    try {
      return AndroidPermissionService.areCriticalPermissionsGranted();
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
    _experimentLogger.logEvent(
      eventType: ExperimentEventTypes.queueWakeCancelled,
      deviceId: 'unknown',
      detail: {'scheduler_state': _schedulerState.name},
    );
  }

  Future<void> _publishPendingRelayWork() async {
    await NativeBridgeService.setHasPendingRelayWork(
      await _relayQueue.hasActiveItems(),
    );
  }

  Future<void> _scheduleNextQueueWake() async {
    _cancelQueueWakeTimer();
    await _publishPendingRelayWork();
    if (_isAdvertising) {
      _setSchedulerState(RelaySchedulerState.advertising);
      return;
    }
    final earliest = await _relayQueue.earliestNextEligibleAt();
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

    final now = DateTime.now().millisecondsSinceEpoch;
    final delayMs = earliest <= now ? 0 : earliest - now;
    _setSchedulerState(RelaySchedulerState.waitingNextSlot);
    if (delayMs > 0) {
      await _experimentLogger.logEvent(
        eventType: ExperimentEventTypes.waitingNextEligible,
        deviceId: 'unknown',
        detail: {
          'next_eligible_at': earliest,
          'delay_ms': delayMs,
          'queue_size': await _relayQueue.queueSize(),
        },
      );
    }
    await _experimentLogger.logEvent(
      eventType: earliest <= now
          ? ExperimentEventTypes.queueWakeTriggered
          : ExperimentEventTypes.queueWakeScheduled,
      deviceId: 'unknown',
      detail: {
        'next_eligible_at': earliest,
        'delay_ms': delayMs,
        'scheduler_state': _schedulerState.name,
        'queue_size': await _relayQueue.queueSize(),
      },
    );

    _queueWakeTimer = Timer(Duration(milliseconds: delayMs), () async {
      await _experimentLogger.logEvent(
        eventType: ExperimentEventTypes.queueWakeTriggered,
        deviceId: 'unknown',
        detail: {'next_eligible_at': earliest},
      );
      await advertiseLatestOrStop(preemptCurrent: true);
    });
  }

  Future<void> startAdvertising({SOSMessage? sosMessage}) async {
    if (sosMessage != null) {
      await enqueueSosForAdvertising(sosMessage, preemptCurrent: true);
      return;
    }
    await advertiseLatestOrStop(preemptCurrent: true);
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
  }) async {
    if (!_isSchedulerOwner) {
      await BackgroundServiceManager.requestSchedulerTick();
      return;
    }

    if (_isSelecting) return;
    _isSelecting = true;
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
          _startSlotTimer();
          return;
        }
        await stopAdvertising();
      }

      if (!await _requestPermissions()) {
        print(
          "[BleAdvertiserService] BLE advertising permissions not granted.",
        );
        _setSchedulerState(RelaySchedulerState.failedPermission);
        await _scheduleNextQueueWake();
        return;
      }

      final queued = await _nextQueuedAdvertisement();
      if (queued?.payload != null) {
        await _startQueuedAck(
          queued!,
          duration: ackSlotDuration ?? _relayQueue.slotDurationForMode(),
        );
        return;
      }

      final message = queued?.message;
      if (message == null) {
        await stopAdvertising();
        await _scheduleNextQueueWake();
        return;
      }
      await _startQueuedSos(queued!);
    } finally {
      _isSelecting = false;
    }
  }

  Future<void> flushPendingAck() => advertiseLatestOrStop();

  Future<void> stopAdvertisingForMessage(String messageId) async {
    if (_currentAdvertisedMessageId == messageId) {
      await stopAdvertising();
      await advertiseLatestOrStop();
    }
  }

  Future<void> stopAdvertising() async {
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

    _isAdvertising = false;
    _currentAdvertisedMessageId = null;
    _isAdvertisingController.add(_isAdvertising);
  }

  Future<_QueuedAdvertisement?> _nextQueuedAdvertisement() async {
    final now = DateTime.now().millisecondsSinceEpoch;
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

      final message = await _dbHelper.getMessageById(item.messageId);
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
    await _experimentLogger.logEvent(
      eventType: ExperimentEventTypes.schedulerPacketSelected,
      deviceId: 'unknown',
      messageId: item.isSos ? item.messageId : null,
      detail: {
        'packet_type': item.packetType,
        'relay_count': item.relayCount,
        'queue_state': item.queueState,
        'forwarding_mode': MeshConfig.forwardingMode.name,
        'ack_queue_size': await _relayQueue.queueSizeByType('ack'),
        'sos_queue_size': await _relayQueue.queueSizeByType('sos'),
      },
    );
  }

  Future<void> _startQueuedSos(_QueuedAdvertisement queued) async {
    final message = queued.message;
    if (message == null) return;

    final now = DateTime.now().millisecondsSinceEpoch;
    await _relayQueue.markAdvertisingStarted(
      queued.item,
      nowMs: now,
      slotDuration: _relayQueue.slotDurationForMode(),
    );

    final payload = BlePacket.packSos(message);
    final packet = BlePacket.unpack(
      payload,
      referenceTime: DateTime.fromMillisecondsSinceEpoch(message.updatedAt),
    );
    final payloadHash = packet?.identity;
    _currentAdvertisedMessageId = message.id;
    await _experimentLogger.logEvent(
      eventType: ExperimentEventTypes.bleAdvertiseRequested,
      deviceId: 'unknown',
      messageId: message.id,
      senderCrc: message.senderCrc,
      hopCount: message.hopCount,
      payloadHash: payloadHash,
    );

    try {
      if (await _startNativePayload(payload)) {
        _isAdvertising = true;
        _setSchedulerState(RelaySchedulerState.advertising);
        _isAdvertisingController.add(_isAdvertising);
        _startWatchdog();
        final succeededAt = DateTime.now().millisecondsSinceEpoch;
        await _relayQueue.markAdvertisingSucceeded(
          queued.item,
          nowMs: succeededAt,
          slotDuration: _relayQueue.slotDurationForMode(),
        );
        await _experimentLogger.logEvent(
          eventType: ExperimentEventTypes.bleAdvertiseStarted,
          deviceId: 'unknown',
          messageId: message.id,
          senderCrc: message.senderCrc,
          hopCount: message.hopCount,
          payloadHash: payloadHash,
        );
        await _experimentLogger.logEvent(
          eventType: ExperimentEventTypes.bleRelayStarted,
          deviceId: 'unknown',
          messageId: message.id,
          senderCrc: message.senderCrc,
          hopCount: message.hopCount,
          payloadHash: payloadHash,
        );
        _startSlotTimer();
        await _scheduleNextQueueWake();
        print(
          "[BleAdvertiserService] Started native BLE SOS advertising (${payload.length} bytes).",
        );
        return;
      }
    } catch (e) {
      print("[BleAdvertiserService] Native advertising unavailable: $e");
    }

    await _relayQueue.markAdvertisingFailed(
      queued.item,
      nowMs: DateTime.now().millisecondsSinceEpoch,
    );
    await _experimentLogger.logEvent(
      eventType: ExperimentEventTypes.bleAdvertiseFailed,
      deviceId: 'unknown',
      messageId: message.id,
      senderCrc: message.senderCrc,
      hopCount: message.hopCount,
      payloadHash: payloadHash,
    );
    _setSchedulerState(RelaySchedulerState.failedRetryable);
    await _scheduleNextQueueWake();
    _markAdvertisingInactive();
  }

  Future<void> _startQueuedAck(
    _QueuedAdvertisement queued, {
    Duration duration = MeshConfig.ackAdvertiseDuration,
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
    await _relayQueue.markAdvertisingStarted(
      queued.item,
      nowMs: DateTime.now().millisecondsSinceEpoch,
      slotDuration: duration,
    );

    try {
      if (await _startNativePayload(payload)) {
        _isAdvertising = true;
        _setSchedulerState(RelaySchedulerState.advertising);
        _currentAdvertisedMessageId = null;
        _isAdvertisingController.add(_isAdvertising);
        _startWatchdog();
        await _relayQueue.markAdvertisingSucceeded(
          queued.item,
          nowMs: DateTime.now().millisecondsSinceEpoch,
          slotDuration: duration,
        );
        await _experimentLogger.logEvent(
          eventType: ExperimentEventTypes.bleAdvertiseStarted,
          deviceId: 'unknown',
          senderCrc: packet.senderCrc,
          hopCount: packet.hopCount,
          payloadHash: packet.identity,
          detail: {'kind': 'ack'},
        );
        await _experimentLogger.logEvent(
          eventType: ExperimentEventTypes.bleRelayStarted,
          deviceId: 'unknown',
          senderCrc: packet.senderCrc,
          hopCount: packet.hopCount,
          payloadHash: packet.identity,
          detail: {'kind': 'ack'},
        );
        print("[BleAdvertiserService] Started queued BLE ACK advertising.");
        _ackRestoreTimer = Timer(duration, () {
          advertiseLatestOrStop(preemptCurrent: true);
        });
        await _scheduleNextQueueWake();
        return;
      }
    } catch (e) {
      print("[BleAdvertiserService] Queued ACK advertising failed: $e");
    }

    await _relayQueue.markAdvertisingFailed(
      queued.item,
      nowMs: DateTime.now().millisecondsSinceEpoch,
    );
    await _experimentLogger.logEvent(
      eventType: ExperimentEventTypes.bleAdvertiseFailed,
      deviceId: 'unknown',
      senderCrc: packet.senderCrc,
      hopCount: packet.hopCount,
      payloadHash: packet.identity,
      detail: {'kind': 'ack'},
    );
    await _persistPendingAck(payload);
    _setSchedulerState(RelaySchedulerState.failedRetryable);
    await _scheduleNextQueueWake();
  }

  void _markAdvertisingInactive() {
    _isAdvertising = false;
    _currentAdvertisedMessageId = null;
    _isAdvertisingController.add(_isAdvertising);
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
