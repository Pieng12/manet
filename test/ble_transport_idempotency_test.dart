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
import 'package:pkmproject/services/research_metrics_service.dart';
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
    BleRelayService.resetFailureHooksForTesting();
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
    BleRelayService.resetFailureHooksForTesting();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(nativeChannel, null);
    await DatabaseHelper.resetForTesting();
  });

  Future<String> sosPayloadBase64({
    required int senderCrc,
    required int timestampMs,
    int hopCount = 0,
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
    return base64Encode(BlePacket.packSos(message, hopCount: hopCount));
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

  Future<String?> processedState(String observationId) async {
    final db = await DatabaseHelper().database;
    final rows = await db.query(
      'processed_ble_observations',
      columns: ['state'],
      where: 'observation_id = ?',
      whereArgs: [observationId],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.single['state'] as String?;
  }

  Future<int> trickleConsistencyCount() async {
    final db = await DatabaseHelper().database;
    final rows = await db.query('trickle_states');
    if (rows.isEmpty) return 0;
    return rows.single['consistency_count'] as int;
  }

  Future<void> expectPhysicalSosSamples({
    required int receivedCount,
    required int rssiCount,
    required int hopInCount,
  }) async {
    final events = await ExperimentLogger().events();
    final metrics = ResearchMetricsService().calculate(
      events: events,
      trials: const [],
    );
    expect(
      await eventsOf(ExperimentEventTypes.blePacketReceived),
      hasLength(receivedCount),
    );
    expect(metrics.rssiStats.count, rssiCount);
    expect(metrics.hopInStats.count, hopInCount);
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
    expect(await eventsOf(ExperimentEventTypes.blePacketReceived), isEmpty);
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
        await eventsOf(ExperimentEventTypes.blePacketReceived),
        hasLength(2),
      );
      expect(
        await eventsOf(ExperimentEventTypes.bleTransportDuplicate),
        isEmpty,
      );
    },
  );

  test(
    'SOS durable commit survives post-commit failure and retry is transport duplicate',
    () async {
      final service = BleRelayService();
      final payload = await sosPayloadBase64(
        senderCrc: 1201,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
      );
      BleRelayService.failAfterSosDurableCommitForTest = true;

      final first = await service.processIncomingBase64(
        payload,
        rssi: -63,
        receivedAtMs: DateTime.now().millisecondsSinceEpoch - 1000,
        observationId: 'obs-sos-postcommit',
        observerKey: 'ble:AA',
        sourcePath: 'direct_service',
      );
      final db = await DatabaseHelper().database;
      final second = await service.processIncomingBase64(
        payload,
        rssi: -63,
        receivedAtMs: DateTime.now().millisecondsSinceEpoch - 900,
        observationId: 'obs-sos-postcommit',
        observerKey: 'ble:AA',
        sourcePath: 'native_inbox_drain',
      );

      final sos = await onlySos();
      expect(first, BleProcessingResult.accepted);
      expect(second, BleProcessingResult.transportDuplicate);
      expect(await processedState('obs-sos-postcommit'), 'completed');
      expect(await db.query('relay_queue'), hasLength(1));
      expect(await db.query('trickle_states'), hasLength(1));
      expect(sos['duplicate_count'], 0);
      expect(await trickleConsistencyCount(), 0);
      expect(await eventsOf(ExperimentEventTypes.blePacketDuplicate), isEmpty);
    },
  );

  test('SOS durable commit survives WorkManager post-commit failure', () async {
    final service = BleRelayService();
    final payload = await sosPayloadBase64(
      senderCrc: 1204,
      timestampMs: DateTime.now().millisecondsSinceEpoch,
    );
    BleRelayService.failWorkManagerPostCommitForTest = true;

    final first = await service.processIncomingBase64(
      payload,
      rssi: -63,
      receivedAtMs: DateTime.now().millisecondsSinceEpoch - 1000,
      observationId: 'obs-sos-workmanager-postcommit',
      observerKey: 'ble:AA',
      sourcePath: 'direct_service',
    );
    final second = await service.processIncomingBase64(
      payload,
      rssi: -63,
      receivedAtMs: DateTime.now().millisecondsSinceEpoch - 900,
      observationId: 'obs-sos-workmanager-postcommit',
      observerKey: 'ble:AA',
      sourcePath: 'native_inbox_drain',
    );
    final db = await DatabaseHelper().database;

    expect(first, BleProcessingResult.accepted);
    expect(second, BleProcessingResult.transportDuplicate);
    expect(await processedState('obs-sos-workmanager-postcommit'), 'completed');
    expect(await db.query('sos_messages'), hasLength(1));
    expect(await db.query('relay_queue'), hasLength(1));
    expect(await eventsOf(ExperimentEventTypes.blePacketDuplicate), isEmpty);
  });

  test('SOS durable commit survives gateway post-commit failure', () async {
    final service = BleRelayService();
    final payload = await sosPayloadBase64(
      senderCrc: 1205,
      timestampMs: DateTime.now().millisecondsSinceEpoch,
    );
    BleRelayService.failGatewayPostCommitForTest = true;

    final first = await service.processIncomingBase64(
      payload,
      rssi: -63,
      receivedAtMs: DateTime.now().millisecondsSinceEpoch - 1000,
      observationId: 'obs-sos-gateway-postcommit',
      observerKey: 'ble:AA',
      sourcePath: 'direct_service',
    );
    final second = await service.processIncomingBase64(
      payload,
      rssi: -63,
      receivedAtMs: DateTime.now().millisecondsSinceEpoch - 900,
      observationId: 'obs-sos-gateway-postcommit',
      observerKey: 'ble:AA',
      sourcePath: 'native_inbox_drain',
    );
    final db = await DatabaseHelper().database;

    expect(first, BleProcessingResult.accepted);
    expect(second, BleProcessingResult.transportDuplicate);
    expect(await processedState('obs-sos-gateway-postcommit'), 'completed');
    expect(await db.query('sos_messages'), hasLength(1));
    expect(await db.query('relay_queue'), hasLength(1));
    expect(await eventsOf(ExperimentEventTypes.blePacketDuplicate), isEmpty);
  });

  test('SOS pre-commit transaction failure stays retryable', () async {
    final service = BleRelayService();
    final payload = await sosPayloadBase64(
      senderCrc: 1202,
      timestampMs: DateTime.now().millisecondsSinceEpoch,
    );
    BleRelayService.failSosTransactionForTest = true;

    final failed = await service.processIncomingBase64(
      payload,
      rssi: -64,
      receivedAtMs: DateTime.now().millisecondsSinceEpoch - 1000,
      observationId: 'obs-sos-precommit',
      observerKey: 'ble:AA',
      sourcePath: 'direct_service',
    );
    final db = await DatabaseHelper().database;
    expect(failed, BleProcessingResult.failedRetryable);
    expect(await processedState('obs-sos-precommit'), 'failed_retryable');
    expect(await db.query('sos_messages'), isEmpty);
    expect(await db.query('relay_queue'), isEmpty);
    expect(
      await eventsOf(ExperimentEventTypes.blePacketReceived),
      hasLength(1),
    );

    BleRelayService.failSosTransactionForTest = false;
    final retried = await service.processIncomingBase64(
      payload,
      rssi: -64,
      receivedAtMs: DateTime.now().millisecondsSinceEpoch - 900,
      observationId: 'obs-sos-precommit',
      observerKey: 'ble:AA',
      sourcePath: 'native_inbox_drain',
    );

    expect(retried, BleProcessingResult.accepted);
    expect(await processedState('obs-sos-precommit'), 'completed');
    expect(await db.query('sos_messages'), hasLength(1));
    expect(
      await eventsOf(ExperimentEventTypes.blePacketReceived),
      hasLength(1),
    );
  });

  test(
    'failed_retryable SOS retries keep one physical RX RSSI and hop sample',
    () async {
      final service = BleRelayService();
      final payload = await sosPayloadBase64(
        senderCrc: 1206,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        hopCount: 2,
      );
      BleRelayService.failSosTransactionForTest = true;

      final first = await service.processIncomingBase64(
        payload,
        rssi: -61,
        receivedAtMs: DateTime.now().millisecondsSinceEpoch - 1000,
        observationId: 'obs-rx-once',
        observerKey: 'ble:AA',
        sourcePath: 'direct_service',
      );
      final second = await service.processIncomingBase64(
        payload,
        rssi: -61,
        receivedAtMs: DateTime.now().millisecondsSinceEpoch - 900,
        observationId: 'obs-rx-once',
        observerKey: 'ble:AA',
        sourcePath: 'native_inbox_drain',
      );
      BleRelayService.failSosTransactionForTest = false;
      final third = await service.processIncomingBase64(
        payload,
        rssi: -61,
        receivedAtMs: DateTime.now().millisecondsSinceEpoch - 800,
        observationId: 'obs-rx-once',
        observerKey: 'ble:AA',
        sourcePath: 'native_inbox_drain',
      );

      expect(first, BleProcessingResult.failedRetryable);
      expect(second, BleProcessingResult.failedRetryable);
      expect(third, BleProcessingResult.accepted);
      expect(await processedState('obs-rx-once'), 'completed');
      await expectPhysicalSosSamples(
        receivedCount: 1,
        rssiCount: 1,
        hopInCount: 1,
      );
    },
  );

  test(
    'direct pre-commit failure then inbox retry logs one physical RX',
    () async {
      final service = BleRelayService();
      final payload = await sosPayloadBase64(
        senderCrc: 1207,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
      );
      BleRelayService.failSosTransactionForTest = true;

      final failed = await service.processIncomingBase64(
        payload,
        rssi: -64,
        receivedAtMs: DateTime.now().millisecondsSinceEpoch - 1000,
        observationId: 'obs-direct-inbox-retry',
        observerKey: 'ble:AA',
        sourcePath: 'direct_service',
      );
      BleRelayService.failSosTransactionForTest = false;
      final recovered = await drainOnce(
        service: service,
        inboxId: 'inbox-direct-inbox-retry',
        payload: payload,
        observationId: 'obs-direct-inbox-retry',
      );

      expect(failed, BleProcessingResult.failedRetryable);
      expect(recovered.completed, true);
      expect(recovered.acknowledged, ['inbox-direct-inbox-retry']);
      expect(await processedState('obs-direct-inbox-retry'), 'completed');
      expect(
        await eventsOf(ExperimentEventTypes.blePacketReceived),
        hasLength(1),
      );
    },
  );

  test(
    'inbox pre-commit failure then direct retry logs one physical RX',
    () async {
      final service = BleRelayService();
      final payload = await sosPayloadBase64(
        senderCrc: 1208,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
      );
      BleRelayService.failSosTransactionForTest = true;

      final failed = await drainOnce(
        service: service,
        inboxId: 'inbox-direct-retry',
        payload: payload,
        observationId: 'obs-inbox-direct-retry',
      );
      BleRelayService.failSosTransactionForTest = false;
      final recovered = await service.processIncomingBase64(
        payload,
        rssi: -64,
        receivedAtMs: DateTime.now().millisecondsSinceEpoch - 900,
        observationId: 'obs-inbox-direct-retry',
        observerKey: 'ble:AA',
        sourcePath: 'direct_service',
      );

      expect(failed.completed, false);
      expect(failed.failed, ['inbox-direct-retry']);
      expect(recovered, BleProcessingResult.accepted);
      expect(await processedState('obs-inbox-direct-retry'), 'completed');
      expect(
        await eventsOf(ExperimentEventTypes.blePacketReceived),
        hasLength(1),
      );
    },
  );

  test(
    'expired processing lease retry does not log another physical RX',
    () async {
      final service = BleRelayService();
      final db = await DatabaseHelper().database;
      final now = DateTime.now().millisecondsSinceEpoch;
      final payload = await sosPayloadBase64(senderCrc: 1209, timestampMs: now);
      await DatabaseHelper.claimBleObservationInDb(
        db,
        observationId: 'obs-lease-rx-once',
        packetType: 'sos',
        receivedAtMs: now - 1000,
        processedAtMs:
            now -
            DatabaseHelper.processedBleObservationLease.inMilliseconds -
            1,
        sourcePath: 'direct_service',
      );
      await ExperimentLogger().logEvent(
        eventType: ExperimentEventTypes.blePacketReceived,
        deviceId: 'test-device',
        senderCrc: 1209,
        hopCount: 0,
        hopIn: 0,
        rssi: -60,
        payloadHash: 'manual-first-rx',
        packetType: 'sos',
        status: SOSMessageStatus.active.name,
        detail: {'observation_id': 'obs-lease-rx-once'},
      );

      final recovered = await service.processIncomingBase64(
        payload,
        rssi: -60,
        receivedAtMs: now,
        observationId: 'obs-lease-rx-once',
        observerKey: 'ble:AA',
        sourcePath: 'native_inbox_drain',
      );

      expect(recovered, BleProcessingResult.accepted);
      expect(await processedState('obs-lease-rx-once'), 'completed');
      await expectPhysicalSosSamples(
        receivedCount: 1,
        rssiCount: 1,
        hopInCount: 1,
      );
    },
  );

  test(
    'logical duplicate post-commit failure is exactly once per observation id',
    () async {
      final service = BleRelayService();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final payload = await sosPayloadBase64(
        senderCrc: 1203,
        timestampMs: timestamp,
      );
      final first = await service.processIncomingBase64(
        payload,
        rssi: -65,
        receivedAtMs: timestamp - 1000,
        observationId: 'obs-dup-A',
        observerKey: 'ble:AA',
        sourcePath: 'direct_service',
      );
      BleRelayService.failAfterLogicalDuplicateCommitForTest = true;
      final duplicateReceiveTime = DateTime.now().millisecondsSinceEpoch;
      final duplicate = await service.processIncomingBase64(
        payload,
        rssi: -66,
        receivedAtMs: duplicateReceiveTime,
        observationId: 'obs-dup-B',
        observerKey: 'ble:AA',
        sourcePath: 'native_inbox_drain',
      );
      final retry = await service.processIncomingBase64(
        payload,
        rssi: -66,
        receivedAtMs: duplicateReceiveTime + 1,
        observationId: 'obs-dup-B',
        observerKey: 'ble:AA',
        sourcePath: 'native_inbox_drain',
      );

      var sos = await onlySos();
      expect(first, BleProcessingResult.accepted);
      expect(duplicate, BleProcessingResult.duplicate);
      expect(retry, BleProcessingResult.transportDuplicate);
      expect(await processedState('obs-dup-B'), 'completed');
      expect(sos['duplicate_count'], 1);
      expect(await trickleConsistencyCount(), 1);

      BleRelayService.failAfterLogicalDuplicateCommitForTest = false;
      final third = await service.processIncomingBase64(
        payload,
        rssi: -67,
        receivedAtMs: DateTime.now().millisecondsSinceEpoch,
        observationId: 'obs-dup-C',
        observerKey: 'ble:AA',
        sourcePath: 'native_inbox_drain',
      );
      sos = await onlySos();
      expect(third, BleProcessingResult.duplicate);
      expect(sos['duplicate_count'], 2);
      expect(await trickleConsistencyCount(), 2);
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
    expect(
      await eventsOf(ExperimentEventTypes.blePacketReceived),
      hasLength(1),
    );
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

  test('failed_retryable ACK retry logs BLE and ACK receive once', () async {
    final service = BleRelayService();
    final payload = base64Encode(
      BlePacket.packAck(
        senderCrc: 2002,
        ackTimestampMs: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    BleRelayService.failAckTransactionForTest = true;

    final first = await service.processIncomingBase64(
      payload,
      rssi: -70,
      receivedAtMs: DateTime.now().millisecondsSinceEpoch - 1000,
      observationId: 'ack-obs-precommit',
      observerKey: 'ble:AA',
      sourcePath: 'direct_service',
    );
    final second = await service.processIncomingBase64(
      payload,
      rssi: -70,
      receivedAtMs: DateTime.now().millisecondsSinceEpoch - 900,
      observationId: 'ack-obs-precommit',
      observerKey: 'ble:AA',
      sourcePath: 'native_inbox_drain',
    );
    BleRelayService.failAckTransactionForTest = false;
    final third = await service.processIncomingBase64(
      payload,
      rssi: -70,
      receivedAtMs: DateTime.now().millisecondsSinceEpoch - 800,
      observationId: 'ack-obs-precommit',
      observerKey: 'ble:AA',
      sourcePath: 'native_inbox_drain',
    );
    final db = await DatabaseHelper().database;

    expect(first, BleProcessingResult.failedRetryable);
    expect(second, BleProcessingResult.failedRetryable);
    expect(third, BleProcessingResult.accepted);
    expect(await processedState('ack-obs-precommit'), 'completed');
    expect(await db.query('ack_tombstones'), hasLength(1));
    expect(
      await eventsOf(ExperimentEventTypes.blePacketReceived),
      hasLength(1),
    );
    expect(await eventsOf(ExperimentEventTypes.ackReceived), hasLength(1));
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
    'ACK durable commit survives post-commit failure and retry is transport duplicate',
    () async {
      final service = BleRelayService();
      final payload = base64Encode(
        BlePacket.packAck(
          senderCrc: 2201,
          ackTimestampMs: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      BleRelayService.failAfterAckDurableCommitForTest = true;

      final first = await service.processIncomingBase64(
        payload,
        rssi: -72,
        receivedAtMs: DateTime.now().millisecondsSinceEpoch - 1000,
        observationId: 'ack-postcommit',
        observerKey: 'ble:AA',
        sourcePath: 'direct_service',
      );
      final second = await service.processIncomingBase64(
        payload,
        rssi: -72,
        receivedAtMs: DateTime.now().millisecondsSinceEpoch - 900,
        observationId: 'ack-postcommit',
        observerKey: 'ble:AA',
        sourcePath: 'native_inbox_drain',
      );
      final db = await DatabaseHelper().database;

      expect(first, BleProcessingResult.accepted);
      expect(second, BleProcessingResult.transportDuplicate);
      expect(await processedState('ack-postcommit'), 'completed');
      expect(await db.query('ack_tombstones'), hasLength(1));
      expect(
        await db.query(
          'relay_queue',
          where: 'packet_type = ?',
          whereArgs: ['ack'],
        ),
        hasLength(1),
      );
      expect(await eventsOf(ExperimentEventTypes.ackReceived), hasLength(1));
    },
  );

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
