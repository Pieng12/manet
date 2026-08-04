import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:pkmproject/services/android_permission_service.dart';
import 'package:pkmproject/config/mesh_config.dart';
import 'package:pkmproject/models/relay_queue_item.dart';
import 'package:pkmproject/models/sos_message.dart';
import 'package:pkmproject/services/ble_protocol.dart';
import 'package:pkmproject/services/database_helper.dart';
import 'package:pkmproject/services/experiment_logger.dart';
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
    'com.example.pkmproject/mesh',
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
  int? _currentAckSenderCrc;
  Timer? _watchdogTimer;
  Timer? _ackRestoreTimer;
  Timer? _slotTimer;

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
        if (_currentAckSenderCrc != null) {
          await advertiseLatestOrStop();
        } else {
          await startAdvertising();
        }
      }
    });
  }

  void _stopWatchdog() {
    _watchdogTimer?.cancel();
    _watchdogTimer = null;
  }

  void _startSlotTimer() {
    _slotTimer?.cancel();
    _slotTimer = Timer(MeshConfig.relaySlotDuration, advertiseLatestOrStop);
  }

  void _stopSlotTimer() {
    _slotTimer?.cancel();
    _slotTimer = null;
  }

  Future<void> startAdvertising({SOSMessage? sosMessage}) async {
    _ackRestoreTimer?.cancel();
    _stopSlotTimer();
    _currentAckSenderCrc = null;
    RelayQueueItem? queueItem;

    if (_isAdvertising) {
      if (sosMessage != null) {
        await stopAdvertising();
      } else if (await isNativeAdvertising()) {
        return;
      } else {
        _stopWatchdog();
      }
    }

    if (!await _requestPermissions()) {
      print("[BleAdvertiserService] BLE advertising permissions not granted.");
      return;
    }

    if (sosMessage != null) {
      await _relayQueue.enqueueSos(sosMessage);
      queueItem = await _relayQueue.getItem(sosMessage.id, 'sos');
    } else {
      final queued = await _nextQueuedAdvertisement();
      if (queued?.payload != null) {
        await _startQueuedAck(queued!);
        return;
      }
      sosMessage = queued?.message ?? await _latestUnsyncedMessage();
      queueItem = queued?.item;
    }

    if (sosMessage == null) {
      await stopAdvertising();
      return;
    }

    if (sosMessage.isExpired || sosMessage.hopCount > sosMessage.maxHop) {
      await stopAdvertising();
      return;
    }

    final payload = BlePacket.packSos(sosMessage);
    _currentAdvertisedMessageId = sosMessage.id;
    await _experimentLogger.logEvent(
      eventType: ExperimentEventTypes.bleAdvertiseRequested,
      deviceId: 'unknown',
      messageId: sosMessage.id,
      senderCrc: sosMessage.senderCrc,
      hopCount: sosMessage.hopCount,
      payloadHash: BlePacket.packetIdentity(
        BlePacket.unpack(payload) ??
            BlePacket(
              kind: BlePacketKind.sos,
              senderCrc: sosMessage.senderCrc ?? 0,
              timestampMs: sosMessage.updatedAt,
              status: sosMessage.status,
              hopCount: sosMessage.hopCount,
            ),
      ),
    );

    try {
      if (await _startNativePayload(payload)) {
        _isAdvertising = true;
        _isAdvertisingController.add(_isAdvertising);
        _startWatchdog();
        if (queueItem != null) {
          await _relayQueue.markRelayed(
            queueItem,
            nowMs: DateTime.now().millisecondsSinceEpoch,
          );
        }
        _startSlotTimer();
        print(
          "[BleAdvertiserService] Started native BLE SOS advertising (${payload.length} bytes).",
        );
        return;
      }
    } catch (e) {
      print("[BleAdvertiserService] Native advertising unavailable: $e");
    }

    _markAdvertisingInactive();
  }

  Future<void> advertiseAckFor({
    required int senderCrc,
    required int ackTimestampMs,
    SOSMessageStatus status = SOSMessageStatus.resolved,
    int hopCount = 0,
    Duration duration = MeshConfig.ackAdvertiseDuration,
  }) async {
    final payload = BlePacket.packAck(
      senderCrc: senderCrc,
      ackTimestampMs: ackTimestampMs,
      status: status,
      hopCount: hopCount,
    );
    final messageId = RelayQueueService.ackMessageId(
      senderCrc: senderCrc,
      ackTimestampMs: ackTimestampMs,
      statusIndex: status.index,
    );
    await _relayQueue.enqueueAck(
      messageId: messageId,
      payloadBase64: base64Encode(payload),
    );
    final queueItem = await _relayQueue.getItem(messageId, 'ack');

    _ackRestoreTimer?.cancel();
    _stopSlotTimer();
    if (_isAdvertising) {
      await stopAdvertising();
    }

    try {
      if (await _startNativePayload(payload)) {
        _isAdvertising = true;
        _currentAdvertisedMessageId = null;
        _currentAckSenderCrc = senderCrc;
        _isAdvertisingController.add(_isAdvertising);
        _startWatchdog();
        if (queueItem != null) {
          await _relayQueue.markRelayed(
            queueItem,
            nowMs: DateTime.now().millisecondsSinceEpoch,
            slotDuration: duration,
          );
        }
        print("[BleAdvertiserService] Started BLE ACK advertising.");
        _ackRestoreTimer = Timer(duration, advertiseLatestOrStop);
        return;
      }
    } catch (e) {
      print("[BleAdvertiserService] ACK advertising failed: $e");
    }

    await _persistPendingAck(payload);
  }

  Future<void> advertiseLatestOrStop() async {
    _ackRestoreTimer?.cancel();
    _stopSlotTimer();

    final pendingAck = await _takePendingAck();
    if (pendingAck != null) {
      final packet = BlePacket.unpack(pendingAck);
      if (packet != null && packet.isAck) {
        await advertiseAckFor(
          senderCrc: packet.senderCrc,
          ackTimestampMs: packet.timestampMs,
          status: packet.status,
          hopCount: packet.hopCount,
        );
        return;
      }
    }

    final queued = await _nextQueuedAdvertisement();
    if (queued?.payload != null) {
      await _startQueuedAck(queued!);
      return;
    }

    final message = queued?.message ?? await _latestUnsyncedMessage();
    if (message == null) {
      await stopAdvertising();
      return;
    }
    await startAdvertising(sosMessage: message);
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
    _currentAckSenderCrc = null;
    _isAdvertisingController.add(_isAdvertising);
  }

  Future<SOSMessage?> _latestUnsyncedMessage() async {
    final messages = await _dbHelper.getUnsyncedMessages();
    if (messages.isEmpty) return null;
    for (final message in messages) {
      await _relayQueue.enqueueSos(message);
    }
    messages.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return messages.first;
  }

  Future<_QueuedAdvertisement?> _nextQueuedAdvertisement() async {
    final messages = await _dbHelper.getUnsyncedMessages();
    for (final message in messages) {
      await _relayQueue.enqueueSos(message);
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    for (var attempt = 0; attempt < 20; attempt++) {
      final item = await _relayQueue.nextEligible(now);
      if (item == null) return null;

      if (item.isAck) {
        if (item.payloadBase64 == null) {
          await _relayQueue.removeItem(item);
          continue;
        }
        return _QueuedAdvertisement(item: item, payload: item.payloadBase64);
      }

      final message = await _dbHelper.getMessageById(item.messageId);
      if (message == null ||
          message.isExpired ||
          message.hopCount > message.maxHop ||
          message.isSynced == 1) {
        await _relayQueue.removeItem(item);
        continue;
      }
      return _QueuedAdvertisement(item: item, message: message);
    }
    return null;
  }

  Future<void> _startQueuedAck(_QueuedAdvertisement queued) async {
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
    if (_isAdvertising) {
      await stopAdvertising();
    }

    try {
      if (await _startNativePayload(payload)) {
        _isAdvertising = true;
        _currentAdvertisedMessageId = null;
        _currentAckSenderCrc = packet.senderCrc;
        _isAdvertisingController.add(_isAdvertising);
        _startWatchdog();
        await _relayQueue.markRelayed(
          queued.item,
          nowMs: DateTime.now().millisecondsSinceEpoch,
          slotDuration: MeshConfig.ackAdvertiseDuration,
        );
        print("[BleAdvertiserService] Started queued BLE ACK advertising.");
        _ackRestoreTimer = Timer(
          MeshConfig.ackAdvertiseDuration,
          advertiseLatestOrStop,
        );
        return;
      }
    } catch (e) {
      print("[BleAdvertiserService] Queued ACK advertising failed: $e");
    }

    await _persistPendingAck(payload);
  }

  void _markAdvertisingInactive() {
    _isAdvertising = false;
    _currentAdvertisedMessageId = null;
    _currentAckSenderCrc = null;
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
