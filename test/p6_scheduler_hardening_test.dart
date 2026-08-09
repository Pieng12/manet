import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:pkmproject/config/mesh_config.dart';
import 'package:pkmproject/database_schema.dart';
import 'package:pkmproject/models/sos_message.dart';
import 'package:pkmproject/services/ble_advertiser_service.dart';
import 'package:pkmproject/services/relay_queue_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  test('native advertiser hard failures map to blocked scheduler states', () {
    expect(
      BleAdvertiserService.blockedStateForNativeAdvertiseError(
        'MISSING_PERMISSION',
      ),
      RelaySchedulerState.failedPermission,
    );
    expect(
      BleAdvertiserService.blockedStateForNativeAdvertiseError(
        'BLUETOOTH_DISABLED',
      ),
      RelaySchedulerState.failedBluetoothDisabled,
    );
    expect(
      BleAdvertiserService.blockedStateForNativeAdvertiseError(
        'FEATURE_UNSUPPORTED',
      ),
      RelaySchedulerState.failedUnsupported,
    );
    expect(
      BleAdvertiserService.blockedStateForNativeAdvertiseError('TRANSIENT_IO'),
      isNull,
    );
  });

  test(
    'transient advertising retry starts at 15 seconds and caps at 5 minutes',
    () {
      expect(
        BleAdvertiserService.transientRetryDelayForAttempt(0),
        const Duration(seconds: 15),
      );
      expect(
        BleAdvertiserService.transientRetryDelayForAttempt(1),
        const Duration(seconds: 30),
      );
      expect(
        BleAdvertiserService.transientRetryDelayForAttempt(99),
        const Duration(minutes: 5),
      );
    },
  );

  test(
    'failed advertising uses explicit retry delay without zero loop',
    () async {
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      addTearDown(db.close);
      await db.execute(createSosMessagesTableSql);
      await db.execute(createRelayQueueTableSql);
      await db.execute(createAckTombstonesTableSql);

      final now = DateTime.utc(2026, 8, 4, 12).millisecondsSinceEpoch;
      final queue = RelayQueueService(database: db, random: Random(1));
      final message = SOSMessage(
        id: 'retry-sos',
        senderId: 'device-retry',
        senderCrc: 123,
        content: 'SOS',
        latitude: -6.2,
        longitude: 106.8,
        createdAt: now,
        updatedAt: now,
        expiresAt: now + MeshConfig.defaultMessageLifetime.inMilliseconds,
      );
      await db.insert('sos_messages', message.toDbMap());
      await queue.enqueueSos(message, nextEligibleAt: now);

      final item = (await queue.nextEligible(now))!;
      await queue.markAdvertisingFailed(
        item,
        nowMs: now,
        retryDelay: BleAdvertiserService.minTransientRetryDelay,
      );

      final failed = (await queue.getItem(message.id, 'sos'))!;
      expect(failed.queueState, RelayQueueService.stateFailed);
      expect(
        failed.nextEligibleAt,
        now + BleAdvertiserService.minTransientRetryDelay.inMilliseconds,
      );
      expect(await queue.nextEligible(now), isNull);
    },
  );

  test(
    'blocked advertising preserves eligibility for event-driven recovery',
    () async {
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      addTearDown(db.close);
      await db.execute(createSosMessagesTableSql);
      await db.execute(createRelayQueueTableSql);
      await db.execute(createAckTombstonesTableSql);

      final now = DateTime.utc(2026, 8, 4, 12).millisecondsSinceEpoch;
      final queue = RelayQueueService(database: db, random: Random(1));
      final message = SOSMessage(
        id: 'blocked-sos',
        senderId: 'device-blocked',
        senderCrc: 321,
        content: 'SOS',
        latitude: -6.2,
        longitude: 106.8,
        createdAt: now,
        updatedAt: now,
        expiresAt: now + MeshConfig.defaultMessageLifetime.inMilliseconds,
      );
      await db.insert('sos_messages', message.toDbMap());
      await queue.enqueueSos(message, nextEligibleAt: now);

      final item = (await queue.nextEligible(now))!;
      await queue.markAdvertisingBlocked(item);

      final blocked = (await queue.getItem(message.id, 'sos'))!;
      expect(blocked.queueState, RelayQueueService.stateFailed);
      expect(blocked.nextEligibleAt, now);
      expect((await queue.nextEligible(now + 10000))!.messageId, message.id);
    },
  );
}
