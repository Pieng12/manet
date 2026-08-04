import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:pkmproject/models/sos_message.dart';
import 'package:pkmproject/services/background_service_manager.dart';
import 'package:pkmproject/services/ble_advertiser_service.dart';
import 'package:pkmproject/services/ble_protocol.dart';
import 'package:pkmproject/services/database_helper.dart';
import 'package:pkmproject/services/native_bridge_service.dart';
import 'package:pkmproject/services/workmanager_service.dart';
import 'package:pkmproject/sync_service.dart';

class BleRelayService {
  static final BleRelayService _instance = BleRelayService._internal();
  factory BleRelayService() => _instance;
  BleRelayService._internal();

  final DatabaseHelper _dbHelper = DatabaseHelper();
  final BleAdvertiserService _advertiser = BleAdvertiserService();
  final _logController = StreamController<String>.broadcast();

  Stream<String> get logStream => _logController.stream;

  Future<void> start() async {
    await BackgroundServiceManager.startBackgroundService();
    await NativeBridgeService.startBleWakeUpScan();
    await _advertiser.flushPendingAck();
    _log('BLE relay started');
  }

  Future<void> stop() async {
    await NativeBridgeService.stopBleWakeUpScan();
    await _advertiser.stopAdvertising();
    _log('BLE relay stopped');
  }

  Future<void> activateForMessage(SOSMessage message) async {
    await _dbHelper.replaceWithLatestMessage(message);
    await start();
    await _advertiser.startAdvertising(sosMessage: message);
    await WorkManagerService.registerSyncTask();
    await _tryGatewaySync();
  }

  Future<void> processIncomingBase64(String payloadBase64) async {
    try {
      final payload = base64Decode(payloadBase64);
      await processIncomingPayload(Uint8List.fromList(payload));
    } catch (e) {
      _log('Invalid BLE payload: $e');
    }
  }

  Future<void> processIncomingPayload(Uint8List payload) async {
    final packet = BlePacket.unpack(payload);
    if (packet == null) {
      _log('Ignored non-ResQMesh BLE packet: ${_hex(payload)}');
      return;
    }

    _log('Received BLE payload ${_hex(payload)} -> ${_describePacket(packet)}');

    if (packet.isAck) {
      await _processAck(packet);
    } else {
      await _processSos(packet);
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
      await _dbHelper.updateSyncStatus(latest.id);
      await _advertiser.stopAdvertisingForMessage(latest.id);
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

    await _advertiser.startAdvertising(sosMessage: latest);
    _log(
      'ACK ignored for sender CRC $senderCrc because local message is newer',
    );
    return false;
  }

  bool _isNotNewerThanAck(int localTimestampMs, int ackTimestampMs) {
    return localTimestampMs ~/ 1000 <= ackTimestampMs ~/ 1000;
  }

  Future<void> _processAck(BlePacket packet) async {
    await applyAck(
      senderCrc: packet.senderCrc,
      ackTimestampMs: packet.timestampMs,
      status: packet.status,
      relayAck: true,
    );
  }

  Future<void> _processSos(BlePacket packet) async {
    final message = SOSMessage(
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
    );

    final isNewer = await _dbHelper.isMessageNewer(message);
    if (!isNewer) {
      _log('Ignored older BLE SOS from ${message.senderCrc}');
      return;
    }

    await _dbHelper.replaceWithLatestMessage(message);
    await _advertiser.startAdvertising(sosMessage: message);
    await WorkManagerService.registerSyncTask();
    _log('Stored and relayed BLE SOS ${message.id}');
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
