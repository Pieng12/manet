import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pkmproject/models/ble_processing_result.dart';
import 'package:pkmproject/models/sos_message.dart';
import 'package:pkmproject/services/ble_protocol.dart';
import 'package:pkmproject/services/ble_relay_service.dart';
import 'package:pkmproject/services/database_helper.dart';
import 'package:pkmproject/services/experiment_logger.dart';
import 'package:pkmproject/services/native_ble_inbox_drain_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const nativeChannel = MethodChannel('id.ac.usu.resqmesh/mesh');

  setUpAll(() {
    sqfliteFfiInit();
    sqflite.databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await DatabaseHelper.resetForTesting();
    final dbPath = p.join(await sqflite.getDatabasesPath(), 'pkm_database.db');
    await sqflite.deleteDatabase(dbPath);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(nativeChannel, (call) async {
          return switch (call.method) {
            'startNativeBleAdvertising' => true,
            'stopNativeBleAdvertising' => true,
            'setHasPendingRelayWork' => null,
            'isNativeBleAdvertising' => false,
            'getNativeBleAdvertisingStatus' => <String, Object>{
              'status': 'stopped',
              'active': false,
            },
            _ => null,
          };
        });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(nativeChannel, null);
    await DatabaseHelper.resetForTesting();
  });

  Future<String> sosPayloadBase64({
    required int senderCrc,
    required int timestampMs,
  }) async {
    final message = SOSMessage(
      id: 'source-$senderCrc-$timestampMs',
      senderId: 'source-$senderCrc',
      senderCrc: senderCrc,
      content: 'SOS',
      latitude: -6.2,
      longitude: 106.8,
      status: SOSMessageStatus.active,
      createdAt: timestampMs,
      updatedAt: timestampMs,
    );
    return base64Encode(BlePacket.packSos(message, hopCount: 0));
  }

  Future<List<Map<String, Object?>>> eventsOf(String type) async {
    final db = await DatabaseHelper().database;
    return db.query(
      'experiment_events',
      where: 'event_type = ?',
      whereArgs: [type],
      orderBy: 'id ASC',
    );
  }

  Future<Map<String, Object?>> onlySos() async {
    final db = await DatabaseHelper().database;
    final rows = await db.query('sos_messages');
    expect(rows, hasLength(1));
    return rows.single;
  }

  test(
    'direct delivery then inbox retry is transport duplicate only',
    () async {
      final service = BleRelayService();
      final payload = await sosPayloadBase64(
        senderCrc: 1001,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
      );

      final first = await service.processIncomingBase64(
        payload,
        rssi: -51,
        receivedAtMs: DateTime.now().millisecondsSinceEpoch - 1000,
        observationId: 'obs-123',
        observerKey: 'ble:AA',
        sourcePath: 'direct_service',
      );
      expect(first, BleProcessingResult.accepted);

      final acknowledged = <String>[];
      final completed = await const NativeBleInboxDrainService().drain(
        items: [
          {
            'id': 'inbox-123',
            'payload_base64': payload,
            'rssi': -51,
            'received_at': DateTime.now().millisecondsSinceEpoch - 900,
            'observation_id': 'obs-123',
            'observer_key': 'ble:AA',
          },
        ],
        process: service.processIncomingBase64,
        acknowledge: (id) async => acknowledged.add(id),
        fail: (_) async {},
      );

      final sos = await onlySos();
      final trickleRows = await (await DatabaseHelper().database).query(
        'trickle_states',
      );
      expect(completed, true);
      expect(acknowledged, ['inbox-123']);
      expect(sos['duplicate_count'], 0);
      expect(trickleRows.single['consistency_count'], 0);
      expect(
        await eventsOf(ExperimentEventTypes.blePacketReceived),
        hasLength(1),
      );
      expect(await eventsOf(ExperimentEventTypes.blePacketDuplicate), isEmpty);
      expect(
        await eventsOf(ExperimentEventTypes.bleTransportDuplicate),
        hasLength(1),
      );
    },
  );

  test(
    'inbox delivery then direct retry is transport duplicate only',
    () async {
      final service = BleRelayService();
      final payload = await sosPayloadBase64(
        senderCrc: 1002,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
      );

      await const NativeBleInboxDrainService().drain(
        items: [
          {
            'id': 'inbox-456',
            'payload_base64': payload,
            'rssi': -59,
            'received_at': DateTime.now().millisecondsSinceEpoch - 1000,
            'observation_id': 'obs-456',
            'observer_key': 'ble:AA',
          },
        ],
        process: service.processIncomingBase64,
        acknowledge: (_) async {},
        fail: (_) async {},
      );

      final second = await service.processIncomingBase64(
        payload,
        rssi: -59,
        receivedAtMs: DateTime.now().millisecondsSinceEpoch - 900,
        observationId: 'obs-456',
        observerKey: 'ble:AA',
        sourcePath: 'direct_service',
      );

      final sos = await onlySos();
      final trickleRows = await (await DatabaseHelper().database).query(
        'trickle_states',
      );
      expect(second, BleProcessingResult.transportDuplicate);
      expect(sos['duplicate_count'], 0);
      expect(trickleRows.single['consistency_count'], 0);
      expect(
        await eventsOf(ExperimentEventTypes.blePacketReceived),
        hasLength(1),
      );
      expect(await eventsOf(ExperimentEventTypes.blePacketDuplicate), isEmpty);
    },
  );

  test(
    'different observation id for same SOS remains logical duplicate',
    () async {
      final service = BleRelayService();
      final firstReceiveTime = DateTime.now().millisecondsSinceEpoch - 1500;
      final payload = await sosPayloadBase64(
        senderCrc: 1003,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
      );

      final first = await service.processIncomingBase64(
        payload,
        rssi: -61,
        receivedAtMs: firstReceiveTime,
        observationId: 'obs-A',
        observerKey: 'ble:AA',
        sourcePath: 'direct_service',
      );
      final secondReceiveTime = DateTime.now().millisecondsSinceEpoch;
      final second = await service.processIncomingBase64(
        payload,
        rssi: -62,
        receivedAtMs: secondReceiveTime,
        observationId: 'obs-B',
        observerKey: 'ble:AA',
        sourcePath: 'native_inbox_drain',
      );

      final sos = await onlySos();
      final trickleRows = await (await DatabaseHelper().database).query(
        'trickle_states',
      );
      final duplicateEvents = await eventsOf(
        ExperimentEventTypes.blePacketDuplicate,
      );
      expect(first, BleProcessingResult.accepted);
      expect(second, BleProcessingResult.duplicate);
      expect(sos['duplicate_count'], 1);
      expect(trickleRows.single['consistency_count'], 1);
      expect(duplicateEvents, hasLength(1));
      expect(duplicateEvents.single['event_timestamp_ms'], secondReceiveTime);
      expect(
        await eventsOf(ExperimentEventTypes.bleTransportDuplicate),
        isEmpty,
      );
    },
  );

  test('same ACK observation id is processed once', () async {
    final service = BleRelayService();
    final payload = base64Encode(
      BlePacket.packAck(
        senderCrc: 2001,
        ackTimestampMs: DateTime.now().millisecondsSinceEpoch,
      ),
    );

    final first = await service.processIncomingBase64(
      payload,
      rssi: -70,
      receivedAtMs: DateTime.now().millisecondsSinceEpoch - 1000,
      observationId: 'ack-obs',
      observerKey: 'ble:AA',
      sourcePath: 'direct_service',
    );
    final second = await service.processIncomingBase64(
      payload,
      rssi: -70,
      receivedAtMs: DateTime.now().millisecondsSinceEpoch - 900,
      observationId: 'ack-obs',
      observerKey: 'ble:AA',
      sourcePath: 'native_inbox_drain',
    );

    expect(first, BleProcessingResult.accepted);
    expect(second, BleProcessingResult.transportDuplicate);
    expect(await eventsOf(ExperimentEventTypes.ackReceived), hasLength(1));
    expect(
      await eventsOf(ExperimentEventTypes.bleTransportDuplicate),
      hasLength(1),
    );
    expect(
      await (await DatabaseHelper().database).query('trickle_states'),
      isEmpty,
    );
  });

  test(
    'invalid observation is completed and retried as transport duplicate',
    () async {
      final service = BleRelayService();
      final first = await service.processIncomingBase64(
        'not-base64',
        receivedAtMs: DateTime.now().millisecondsSinceEpoch - 1000,
        observationId: 'invalid-obs',
        sourcePath: 'direct_service',
      );
      final second = await service.processIncomingBase64(
        'not-base64',
        receivedAtMs: DateTime.now().millisecondsSinceEpoch - 900,
        observationId: 'invalid-obs',
        sourcePath: 'native_inbox_drain',
      );

      expect(first, BleProcessingResult.invalid);
      expect(second, BleProcessingResult.transportDuplicate);
      expect(await eventsOf(ExperimentEventTypes.blePacketReceived), isEmpty);
      expect(
        await eventsOf(ExperimentEventTypes.bleTransportDuplicate),
        hasLength(1),
      );
    },
  );
}
