import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_ble_peripheral/flutter_ble_peripheral.dart';
import 'package:pkmproject/services/android_permission_service.dart';
import 'package:pkmproject/models/sos_message.dart';
import 'package:pkmproject/services/ble_protocol.dart';
import 'package:pkmproject/services/database_helper.dart';
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
    defaultValue: true,
  );

  final FlutterBlePeripheral _peripheral = FlutterBlePeripheral();
  final DatabaseHelper _dbHelper = DatabaseHelper();
  final _isAdvertisingController = StreamController<bool>.broadcast();

  Stream<bool> get onAdvertisingChanged => _isAdvertisingController.stream;

  bool _isAdvertising = false;
  bool get isAdvertising => _isAdvertising;

  String? _currentAdvertisedMessageId;
  int? _currentAckSenderCrc;
  Timer? _watchdogTimer;
  Timer? _ackRestoreTimer;

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
    final success = await _nativeChannel.invokeMethod<bool>(
      'startNativeBleAdvertising',
      {
        'payload': base64Encode(payload),
        'debugVisible': _debugVisibleAdvertising,
      },
    );
    return success == true;
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

  Future<void> startAdvertising({SOSMessage? sosMessage}) async {
    _ackRestoreTimer?.cancel();
    _currentAckSenderCrc = null;

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

    sosMessage ??= await _latestUnsyncedMessage();
    if (sosMessage == null) {
      await stopAdvertising();
      return;
    }

    final payload = BlePacket.packSos(sosMessage);
    _currentAdvertisedMessageId = sosMessage.id;

    try {
      if (await _startNativePayload(payload)) {
        _isAdvertising = true;
        _isAdvertisingController.add(_isAdvertising);
        _startWatchdog();
        print(
          "[BleAdvertiserService] Started native BLE SOS advertising (${payload.length} bytes).",
        );
        return;
      }
    } catch (e) {
      print("[BleAdvertiserService] Native advertising unavailable: $e");
    }

    await _startFlutterFallback();
  }

  Future<void> advertiseAckFor({
    required int senderCrc,
    required int ackTimestampMs,
    SOSMessageStatus status = SOSMessageStatus.resolved,
    Duration duration = const Duration(seconds: 15),
  }) async {
    final payload = BlePacket.packAck(
      senderCrc: senderCrc,
      ackTimestampMs: ackTimestampMs,
      status: status,
    );

    _ackRestoreTimer?.cancel();
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

    final pendingAck = await _takePendingAck();
    if (pendingAck != null) {
      final packet = BlePacket.unpack(pendingAck);
      if (packet != null && packet.isAck) {
        await advertiseAckFor(
          senderCrc: packet.senderCrc,
          ackTimestampMs: packet.timestampMs,
          status: packet.status,
        );
        return;
      }
    }

    final latest = await _latestUnsyncedMessage();
    if (latest == null) {
      await stopAdvertising();
      return;
    }
    await startAdvertising(sosMessage: latest);
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
    _stopWatchdog();

    if (!_isAdvertising) return;

    try {
      await _nativeChannel.invokeMethod('stopNativeBleAdvertising');
    } catch (e) {
      print("[BleAdvertiserService] Native stop failed, trying fallback: $e");
      try {
        await _peripheral.stop();
      } catch (_) {}
    }

    _isAdvertising = false;
    _currentAdvertisedMessageId = null;
    _currentAckSenderCrc = null;
    _isAdvertisingController.add(_isAdvertising);
  }

  Future<SOSMessage?> _latestUnsyncedMessage() async {
    final messages = await _dbHelper.getUnsyncedMessages();
    if (messages.isEmpty) return null;
    messages.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return messages.first;
  }

  Future<void> _startFlutterFallback() async {
    try {
      if (!await _peripheral.isSupported) return;
      final advertiseData = AdvertiseData(
        serviceUuid: kResqMeshServiceUuidString,
        includeDeviceName: false,
      );

      await _peripheral.start(
        advertiseData: advertiseData,
        advertiseSettings: AdvertiseSettings(
          advertiseMode: AdvertiseMode.advertiseModeBalanced,
          txPowerLevel: AdvertiseTxPower.advertiseTxPowerMedium,
          connectable: false,
        ),
      );

      _isAdvertising = true;
      _isAdvertisingController.add(_isAdvertising);
      _startWatchdog();
      print("[BleAdvertiserService] Started Flutter BLE fallback.");
    } catch (e) {
      print("[BleAdvertiserService] Flutter fallback failed: $e");
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
    _stopWatchdog();
    _isAdvertisingController.close();
  }
}
