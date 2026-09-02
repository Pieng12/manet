import 'package:flutter_test/flutter_test.dart';
import 'package:pkmproject/models/ble_processing_result.dart';
import 'package:pkmproject/database_schema.dart';
import 'package:pkmproject/services/database_helper.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Database db;

  setUp(() async {
    sqfliteFfiInit();
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await db.execute(createProcessedBleObservationsTableSql);
    await db.execute(createProcessedBleObservationsStateIndexSql);
  });

  tearDown(() async {
    await db.close();
  });

  test('completed observation claim blocks transport retry', () async {
    final first = await DatabaseHelper.claimBleObservationInDb(
      db,
      observationId: 'obs-1',
      packetType: 'sos',
      receivedAtMs: 1000,
      processedAtMs: 1100,
      sourcePath: 'direct_service',
    );
    await DatabaseHelper.completeBleObservationInDb(db, 'obs-1', 1200);

    final second = await DatabaseHelper.claimBleObservationInDb(
      db,
      observationId: 'obs-1',
      packetType: 'sos',
      receivedAtMs: 1300,
      processedAtMs: 1400,
      sourcePath: 'native_inbox_drain',
    );

    expect(first.shouldProcess, true);
    expect(first.isFirstClaim, true);
    expect(first.isRetryClaim, false);
    expect(second.shouldProcess, false);
    expect(second.state, 'completed');
    expect(second.isFirstClaim, false);
    expect(second.isRetryClaim, false);
    expect(second.isTransportDuplicate, true);
    expect(BleProcessingResult.transportDuplicate.shouldAcknowledgeInbox, true);
  });

  test('active processing claim is not safe to acknowledge', () async {
    final first = await DatabaseHelper.claimBleObservationInDb(
      db,
      observationId: 'obs-processing',
      packetType: 'sos',
      receivedAtMs: 1000,
      processedAtMs: 1000,
    );
    final second = await DatabaseHelper.claimBleObservationInDb(
      db,
      observationId: 'obs-processing',
      packetType: 'sos',
      receivedAtMs: 1500,
      processedAtMs: 2000,
    );

    expect(first.shouldProcess, true);
    expect(first.isFirstClaim, true);
    expect(first.isRetryClaim, false);
    expect(second.shouldProcess, false);
    expect(second.state, 'processing');
    expect(second.isFirstClaim, false);
    expect(second.isRetryClaim, false);
    expect(second.isInProgress, true);
    expect(second.isTransportDuplicate, false);
    expect(
      BleProcessingResult.transportInProgress.shouldAcknowledgeInbox,
      false,
    );
    expect(BleProcessingResult.transportInProgress.shouldRetryInbox, true);
  });

  test('retryable failure can be claimed again', () async {
    await DatabaseHelper.claimBleObservationInDb(
      db,
      observationId: 'obs-retry',
      packetType: 'sos',
      receivedAtMs: 1000,
      processedAtMs: 1100,
    );
    await DatabaseHelper.markBleObservationRetryableInDb(db, 'obs-retry', 1200);

    final retry = await DatabaseHelper.claimBleObservationInDb(
      db,
      observationId: 'obs-retry',
      packetType: 'sos',
      receivedAtMs: 1300,
      processedAtMs: 1400,
    );

    expect(retry.shouldProcess, true);
    expect(retry.isFirstClaim, false);
    expect(retry.isRetryClaim, true);
    final rows = await db.query('processed_ble_observations');
    expect(rows.single['state'], 'processing');
  });

  test('completed observation cannot become retryable again', () async {
    await DatabaseHelper.claimBleObservationInDb(
      db,
      observationId: 'obs-monotonic',
      packetType: 'sos',
      receivedAtMs: 1000,
      processedAtMs: 1100,
    );
    await DatabaseHelper.completeBleObservationInDb(db, 'obs-monotonic', 1200);
    await DatabaseHelper.markBleObservationRetryableInDb(
      db,
      'obs-monotonic',
      1300,
    );

    final rows = await db.query(
      'processed_ble_observations',
      where: 'observation_id = ?',
      whereArgs: ['obs-monotonic'],
    );
    expect(rows.single['state'], 'completed');
    expect(rows.single['processed_at'], 1200);
  });

  test('stale processing lease can be retried after timeout', () async {
    await DatabaseHelper.claimBleObservationInDb(
      db,
      observationId: 'obs-stale-processing',
      packetType: 'sos',
      receivedAtMs: 1000,
      processedAtMs: 1100,
    );

    final beforeLease = await DatabaseHelper.claimBleObservationInDb(
      db,
      observationId: 'obs-stale-processing',
      packetType: 'sos',
      receivedAtMs: 1000,
      processedAtMs:
          1100 + DatabaseHelper.processedBleObservationLease.inMilliseconds - 1,
    );
    final retry = await DatabaseHelper.claimBleObservationInDb(
      db,
      observationId: 'obs-stale-processing',
      packetType: 'sos',
      receivedAtMs: 1000,
      processedAtMs:
          1100 + DatabaseHelper.processedBleObservationLease.inMilliseconds + 1,
    );

    expect(beforeLease.shouldProcess, false);
    expect(beforeLease.state, 'processing');
    expect(beforeLease.isFirstClaim, false);
    expect(beforeLease.isRetryClaim, false);
    expect(retry.shouldProcess, true);
    expect(retry.isFirstClaim, false);
    expect(retry.isRetryClaim, true);
  });

  test('cleanup keeps retention bounded without deleting fresh rows', () async {
    await db.insert('processed_ble_observations', {
      'observation_id': 'old-completed',
      'packet_type': 'sos',
      'state': 'completed',
      'first_received_at': 1,
      'processed_at': 1,
      'updated_at': 1,
    });
    await db.insert('processed_ble_observations', {
      'observation_id': 'fresh-completed',
      'packet_type': 'sos',
      'state': 'completed',
      'first_received_at': 100,
      'processed_at': 100,
      'updated_at': 100,
    });

    final deleted = await DatabaseHelper.cleanupProcessedBleObservationsInDb(
      db,
      beforeMs: 50,
    );

    final ids = (await db.query(
      'processed_ble_observations',
    )).map((row) => row['observation_id']).toSet();
    expect(deleted, 1);
    expect(ids, {'fresh-completed'});
  });
}
