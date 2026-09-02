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

  Future<({bool completed, List<String> acknowledged, List<String> failed})>
  drainOnce({
    required BleRelayService service,
    required String inboxId,
    required String payload,
    required String observationId,
    String observerKey = 'ble:AA',
  }) async {
    final acknowledged = <String>[];
    final failed = <String>[];
    final completed = await const NativeBleInboxDrainService().drain(
      items: [
        {
          'id': inboxId,
          'payload_base64': payload,
          'rssi': -57,
          'received_at': DateTime.now().millisecondsSinceEpoch - 500,
          'observation_id': observationId,
          'observer_key': observerKey,
        },
      ],
      process: service.processIncomingBase64,
      acknowledge: (id) async => acknowledged.add(id),
      fail: (id) async => failed.add(id),
    );
    return (completed: completed, acknowledged: acknowledged, failed: failed);
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
    'active processing retry stays pending and later completed duplicate ACKs',
    () async {
      final service = BleRelayService();
      final db = await DatabaseHelper().database;
      final payload = await sosPayloadBase64(
        senderCrc: 1101,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
      );
      await DatabaseHelper.claimBleObservationInDb(
        db,
        observationId: 'obs-race',
        packetType: 'sos',
        receivedAtMs: 1000,
        processedAtMs: DateTime.now().millisecondsSinceEpoch,
        sourcePath: 'direct_service',
      );

      final inProgress = await drainOnce(
        service: service,
        inboxId: 'inbox-race',
        payload: payload,
        observationId: 'obs-race',
      );
      expect(inProgress.completed, false);
      expect(inProgress.acknowledged, isEmpty);
      expect(inProgress.failed, ['inbox-race']);
      expect(
        BleProcessingResult.transportInProgress.shouldAcknowledgeInbox,
        false,
      );
      expect(BleProcessingResult.transportInProgress.shouldRetryInbox, true);
      expect(
        await eventsOf(ExperimentEventTypes.bleTransportInProgress),
        hasLength(1),
      );
      expect(await eventsOf(ExperimentEventTypes.blePacketReceived), isEmpty);
      expect(await eventsOf(ExperimentEventTypes.blePacketDuplicate), isEmpty);
      expect(await db.query('sos_messages'), isEmpty);
      expect(await db.query('trickle_states'), isEmpty);

      await DatabaseHelper.completeBleObservationInDb(
        db,
        'obs-race',
        DateTime.now().millisecondsSinceEpoch,
      );
      final completedDuplicate = await drainOnce(
        service: service,
        inboxId: 'inbox-race-retry',
        payload: payload,
        observationId: 'obs-race',
      );
      expect(completedDuplicate.completed, true);
      expect(completedDuplicate.acknowledged, ['inbox-race-retry']);
      expect(completedDuplicate.failed, isEmpty);
      expect(
        await eventsOf(ExperimentEventTypes.bleTransportDuplicate),
        hasLength(1),
      );
      expect(await eventsOf(ExperimentEventTypes.blePacketReceived), isEmpty);
      expect(await eventsOf(ExperimentEventTypes.blePacketDuplicate), isEmpty);
    },
  );

  test('stale processing lease lets inbox recover direct crash', () async {
    final service = BleRelayService();
    final db = await DatabaseHelper().database;
    final now = DateTime.now().millisecondsSinceEpoch;
    final payload = await sosPayloadBase64(senderCrc: 1102, timestampMs: now);
    await DatabaseHelper.claimBleObservationInDb(
      db,
      observationId: 'obs-crash',
      packetType: 'sos',
      receivedAtMs: now - 1000,
      processedAtMs:
          now - DatabaseHelper.processedBleObservationLease.inMilliseconds - 1,
      sourcePath: 'direct_service',
    );

    final recovered = await drainOnce(
      service: service,
      inboxId: 'inbox-crash',
      payload: payload,
      observationId: 'obs-crash',
    );

    final rows = await db.query(
      'processed_ble_observations',
      where: 'observation_id = ?',
      whereArgs: ['obs-crash'],
    );
    expect(recovered.completed, true);
    expect(recovered.acknowledged, ['inbox-crash']);
    expect(recovered.failed, isEmpty);
    expect(rows.single['state'], 'completed');
    expect(await db.query('sos_messages'), hasLength(1));
    expect(
      await eventsOf(ExperimentEventTypes.blePacketReceived),
      hasLength(1),
    );
    expect(await eventsOf(ExperimentEventTypes.blePacketDuplicate), isEmpty);
  });

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

  test('active ACK processing retry stays pending until completed', () async {
    final service = BleRelayService();
    final db = await DatabaseHelper().database;
    final payload = base64Encode(
      BlePacket.packAck(
        senderCrc: 2101,
        ackTimestampMs: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    await DatabaseHelper.claimBleObservationInDb(
      db,
      observationId: 'ack-race',
      packetType: 'ack',
      receivedAtMs: 1000,
      processedAtMs: DateTime.now().millisecondsSinceEpoch,
      sourcePath: 'direct_service',
    );

    final inProgress = await service.processIncomingBase64(
      payload,
      rssi: -71,
      receivedAtMs: DateTime.now().millisecondsSinceEpoch - 500,
      observationId: 'ack-race',
      observerKey: 'ble:AA',
      sourcePath: 'native_inbox_drain',
    );

    expect(inProgress, BleProcessingResult.transportInProgress);
    expect(await eventsOf(ExperimentEventTypes.ackReceived), isEmpty);
    expect(
      await eventsOf(ExperimentEventTypes.bleTransportInProgress),
      hasLength(1),
    );

    await DatabaseHelper.completeBleObservationInDb(
      db,
      'ack-race',
      DateTime.now().millisecondsSinceEpoch,
    );
    final duplicate = await service.processIncomingBase64(
      payload,
      rssi: -71,
      receivedAtMs: DateTime.now().millisecondsSinceEpoch - 400,
      observationId: 'ack-race',
      observerKey: 'ble:AA',
      sourcePath: 'native_inbox_drain',
    );

    expect(duplicate, BleProcessingResult.transportDuplicate);
    expect(await eventsOf(ExperimentEventTypes.ackReceived), isEmpty);
    expect(
      await eventsOf(ExperimentEventTypes.bleTransportDuplicate),
      hasLength(1),
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
