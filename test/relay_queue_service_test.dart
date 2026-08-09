import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:pkmproject/config/mesh_config.dart';
import 'package:pkmproject/database_schema.dart';
import 'package:pkmproject/models/ack_apply_result.dart';
import 'package:pkmproject/models/forwarding_decision.dart';
import 'package:pkmproject/models/sos_message.dart';
import 'package:pkmproject/services/ble_protocol.dart';
import 'package:pkmproject/services/database_helper.dart';
import 'package:pkmproject/services/forwarding_policy.dart';
import 'package:pkmproject/services/relay_queue_service.dart';
import 'package:pkmproject/utils/protocol_timestamp.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Database db;
  late RelayQueueService queue;
  late int now;

  setUp(() async {
    sqfliteFfiInit();
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await db.execute(createSosMessagesTableSql);
    await db.execute(createRelayQueueTableSql);
    await db.execute(createAckTombstonesTableSql);
    queue = RelayQueueService(database: db, random: Random(1));
    now = DateTime.utc(2026, 8, 4, 12).millisecondsSinceEpoch;
  });

  tearDown(() async {
    await db.close();
  });

  SOSMessage message(
    String id, {
    int offsetSeconds = 0,
    bool expired = false,
    SOSMessageStatus status = SOSMessageStatus.active,
    int? senderCrc,
    int? updatedAt,
  }) {
    final createdAt =
        updatedAt ?? now + Duration(seconds: offsetSeconds).inMilliseconds;
    return SOSMessage(
      id: id,
      senderId: 'device-$id',
      senderCrc: senderCrc ?? id.hashCode,
      content: 'SOS',
      latitude: -6.2,
      longitude: 106.8,
      status: status,
      createdAt: createdAt,
      updatedAt: createdAt,
      expiresAt: expired
          ? now - const Duration(seconds: 1).inMilliseconds
          : now + MeshConfig.defaultMessageLifetime.inMilliseconds,
    );
  }

  Future<void> insertMessage(SOSMessage message) async {
    await db.insert('sos_messages', message.toDbMap());
  }

  test('three active SOS messages all receive advertising slots', () async {
    final messages = [message('a'), message('b'), message('c')];
    for (final item in messages) {
      await insertMessage(item);
      await queue.enqueueSos(item);
    }

    final selected = <String>[];
    for (var i = 0; i < messages.length; i++) {
      final item = await queue.nextEligible(now);
      expect(item, isNotNull);
      selected.add(item!.messageId);
      await queue.markRelayed(item, nowMs: now);
    }

    expect(selected.toSet(), {'a', 'b', 'c'});
  });

  test(
    'round robin returns oldest relayed item after adaptive backoff and jitter',
    () async {
      final messages = [message('a'), message('b'), message('c')];
      for (final item in messages) {
        await insertMessage(item);
        await queue.enqueueSos(item);
      }

      final first = await queue.nextEligible(now);
      await queue.markRelayed(first!, nowMs: now);
      final second = await queue.nextEligible(now);
      await queue.markRelayed(second!, nowMs: now + 1);
      final third = await queue.nextEligible(now);
      await queue.markRelayed(third!, nowMs: now + 2);

      final afterSlot = now + MeshConfig.relaySlotDuration.inMilliseconds;
      expect(await queue.nextEligible(afterSlot), isNull);

      final afterCooldown =
          now +
          queue.adaptiveBackoffForRelayCount(1).inMilliseconds +
          MeshConfig.relayJitterMax.inMilliseconds +
          1;
      final next = await queue.nextEligible(afterCooldown);

      expect(next, isNotNull);
      expect(next!.messageId, first.messageId);
    },
  );

  test('advertising start does not increment relay counters', () async {
    final sos = message('stateful');
    await insertMessage(sos);
    await queue.enqueueSos(sos);

    final item = await queue.nextEligible(now);
    await queue.markAdvertisingStarted(item!, nowMs: now);

    final queued = await queue.getItem(sos.id, 'sos');
    final stored = SOSMessage.fromDbMap(
      (await db.query(
        'sos_messages',
        where: 'id = ?',
        whereArgs: [sos.id],
      )).single,
    );

    expect(queued!.queueState, RelayQueueService.stateAdvertising);
    expect(queued.relayCount, 0);
    expect(stored.relayCount, 0);
    expect(stored.lastRelayedAt, 0);
  });

  test(
    'advertising success increments queue and SOS counters with backoff jitter',
    () async {
      final sos = message('success');
      await insertMessage(sos);
      await queue.enqueueSos(sos);

      final item = await queue.nextEligible(now);
      await queue.markAdvertisingStarted(item!, nowMs: now);
      await queue.markAdvertisingSucceeded(item, nowMs: now);

      final queued = await queue.getItem(sos.id, 'sos');
      final stored = SOSMessage.fromDbMap(
        (await db.query(
          'sos_messages',
          where: 'id = ?',
          whereArgs: [sos.id],
        )).single,
      );

      expect(queued!.queueState, RelayQueueService.stateRelayed);
      expect(queued.relayCount, 1);
      expect(stored.relayCount, 1);
      expect(stored.lastRelayedAt, now);
      expect(
        queued.nextEligibleAt,
        greaterThanOrEqualTo(
          now +
              queue.adaptiveBackoffForRelayCount(1).inMilliseconds +
              MeshConfig.relayJitterMin.inMilliseconds,
        ),
      );
      expect(
        queued.nextEligibleAt,
        lessThanOrEqualTo(
          now +
              queue.adaptiveBackoffForRelayCount(1).inMilliseconds +
              MeshConfig.relayJitterMax.inMilliseconds,
        ),
      );
    },
  );

  test('relay count does not remove persistent SOS at any count', () async {
    final sos = message('max-relay')
      ..relayCount = MeshConfig.relayCountMetricSample - 1;
    await insertMessage(sos);
    await queue.enqueueSos(sos);

    final item = await queue.nextEligible(now);
    await queue.markAdvertisingStarted(item!, nowMs: now);
    await queue.markAdvertisingSucceeded(item, nowMs: now);

    expect(await queue.getItem(sos.id, 'sos'), isNotNull);
    final stored = SOSMessage.fromDbMap(
      (await db.query(
        'sos_messages',
        where: 'id = ?',
        whereArgs: [sos.id],
      )).single,
    );
    expect(stored.relayCount, MeshConfig.relayCountMetricSample);
  });

  test('adaptive backoff increases but never disables message', () async {
    final first = queue.adaptiveBackoffForRelayCount(0);
    final later = queue.adaptiveBackoffForRelayCount(4);
    final capped = queue.adaptiveBackoffForRelayCount(99);

    expect(later, greaterThan(first));
    expect(capped, MeshConfig.adaptiveBackoffMax);

    final sos = message('backoff')..relayCount = 99;
    await insertMessage(sos);
    await queue.enqueueSos(sos);
    final item = await queue.nextEligible(now);
    await queue.markAdvertisingStarted(item!, nowMs: now);
    await queue.markAdvertisingSucceeded(item, nowMs: now);

    expect(await queue.getItem(sos.id, 'sos'), isNotNull);
  });

  test('ACK gets priority over SOS queue items', () async {
    final sos = message('sos-1');
    await insertMessage(sos);
    await queue.enqueueSos(sos);

    final ackPayload = BlePacket.packAck(senderCrc: 12345, ackTimestampMs: now);
    await queue.enqueueAck(
      messageId: 'ack-12345-$now',
      payloadBase64: base64Encode(ackPayload),
      nextEligibleAt: now,
    );

    final next = await queue.nextEligible(now);

    expect(next, isNotNull);
    expect(next!.isAck, true);
    expect(next.priority, greaterThan(0));
  });

  test('ACK stops SOS by removing matching persistent queue item', () async {
    final sos = message('acked-sos');
    await insertMessage(sos);
    await queue.enqueueSos(sos);

    expect(await queue.getItem(sos.id, 'sos'), isNotNull);
    await queue.removeMessage(sos.id);

    expect(await queue.getItem(sos.id, 'sos'), isNull);
  });

  test('queue remains fair with multiple SOS and ACK items', () async {
    final sosA = message('fair-a');
    final sosB = message('fair-b');
    await insertMessage(sosA);
    await insertMessage(sosB);
    await queue.enqueueSos(sosA);
    await queue.enqueueSos(sosB);

    for (final crc in [111, 222]) {
      final ackPayload = BlePacket.packAck(senderCrc: crc, ackTimestampMs: now);
      await queue.enqueueAck(
        messageId: 'ack-$crc-$now',
        payloadBase64: base64Encode(ackPayload),
        nextEligibleAt: now,
      );
    }

    final selected = <String>[];
    for (var i = 0; i < 4; i++) {
      final item = await queue.nextEligible(now);
      expect(item, isNotNull);
      selected.add(item!.packetType);
      await queue.markAdvertisingStarted(item, nowMs: now + i);
      await queue.markAdvertisingSucceeded(item, nowMs: now + i);
    }

    expect(selected.take(2).every((type) => type == 'ack'), true);
    expect(selected.skip(2).toSet(), {'sos'});
  });

  test('duplicate ACK queue item is not inserted twice', () async {
    final ackPayload = BlePacket.packAck(senderCrc: 12345, ackTimestampMs: now);
    final messageId = 'ack-12345-$now-2';

    await queue.enqueueAck(
      messageId: messageId,
      payloadBase64: base64Encode(ackPayload),
    );
    await queue.enqueueAck(
      messageId: messageId,
      payloadBase64: base64Encode(ackPayload),
    );

    expect(await queue.queueSize(), 1);
  });

  test('new ACK replaces older ACK for same sender', () async {
    final oldPayload = BlePacket.packAck(senderCrc: 12345, ackTimestampMs: now);
    final newPayload = BlePacket.packAck(
      senderCrc: 12345,
      ackTimestampMs: now + 1000,
    );

    await queue.enqueueAck(
      messageId: 'ack-12345-old',
      payloadBase64: base64Encode(oldPayload),
    );
    await queue.enqueueAck(
      messageId: 'ack-12345-new',
      payloadBase64: base64Encode(newPayload),
    );

    final rows = await db.query('relay_queue', where: "packet_type = 'ack'");
    final tombstone = await db.query('ack_tombstones');

    expect(rows, hasLength(1));
    expect(rows.single['message_id'], 'ack-12345');
    final packet = BlePacket.unpack(
      base64Decode(rows.single['payload_base64'] as String),
      referenceTime: DateTime.fromMillisecondsSinceEpoch(now + 1000),
    );
    expect(packet!.timestampMs, now + 1000);
    expect(tombstone, hasLength(1));
    expect(tombstone.single['ack_timestamp_ms'], now + 1000);
  });

  test('ACK with ACTIVE status is rejected', () async {
    final activeAck = BlePacket.packAck(
      senderCrc: 12345,
      ackTimestampMs: now,
      status: SOSMessageStatus.active,
    );

    final inserted = await queue.enqueueAck(
      messageId: 'ack-active',
      payloadBase64: base64Encode(activeAck),
    );

    expect(inserted, 0);
    expect(await queue.queueSize(), 0);
    expect(await db.query('ack_tombstones'), isEmpty);
  });

  test('queue ACK remains bounded per sender', () async {
    for (var i = 0; i < 20; i++) {
      final payload = BlePacket.packAck(
        senderCrc: 54321,
        ackTimestampMs: now + i * 1000,
      );
      await queue.enqueueAck(
        messageId: 'ack-54321-$i',
        payloadBase64: base64Encode(payload),
      );
    }

    final rows = await db.query('relay_queue', where: "packet_type = 'ack'");
    expect(rows, hasLength(1));
    expect(rows.single['message_id'], 'ack-54321');
  });

  test('old ACK item remains in persistent queue', () async {
    final oldAckTimestamp = now - MeshConfig.ackLifetime.inMilliseconds;
    final ackPayload = BlePacket.packAck(
      senderCrc: 12345,
      ackTimestampMs: oldAckTimestamp,
    );
    await queue.enqueueAck(
      messageId: 'ack-12345-$oldAckTimestamp-2',
      payloadBase64: base64Encode(ackPayload),
      nextEligibleAt: now,
    );

    final next = await queue.nextEligible(now);

    expect(next, isNotNull);
    expect(next!.isAck, true);
    expect(await queue.queueSize(), 1);
  });

  test('old SOS item remains eligible while not ACKed', () async {
    final expired = message('expired', expired: true);
    await insertMessage(expired);
    await queue.enqueueSos(expired);

    final next = await queue.nextEligible(now);
    final size = await queue.queueSize();

    expect(size, 1);
    expect(next, isNotNull);
  });

  test(
    'basic flooding and controlled epidemic produce different schedules',
    () {
      final basic = RelayQueueService(
        database: db,
        random: Random(1),
        mode: ForwardingMode.basicFlooding,
      );
      final controlled = RelayQueueService(
        database: db,
        random: Random(1),
        mode: ForwardingMode.controlledEpidemic,
      );

      final basicNext = basic.sosCooldownEligibleAt(now, relayCount: 5);
      final controlledNext = controlled.sosCooldownEligibleAt(
        now,
        relayCount: 5,
      );

      expect(basicNext, isNot(controlledNext));
      expect(
        basicNext,
        lessThan(
          now +
              MeshConfig.adaptiveBackoffBase.inMilliseconds +
              MeshConfig.relayJitterMax.inMilliseconds,
        ),
      );
    },
  );

  test('ACK tombstone suppresses older SOS but not newer SOS', () async {
    await DatabaseHelper.upsertAckTombstoneInDb(
      db,
      senderCrc: 12345,
      ackTimestampMs: now,
      status: SOSMessageStatus.resolved,
    );

    expect(
      await DatabaseHelper.isSuppressedByAckTombstoneInDb(
        db,
        senderCrc: 12345,
        sosTimestampMs: now - 1,
      ),
      true,
    );
    expect(
      await DatabaseHelper.isSuppressedByAckTombstoneInDb(
        db,
        senderCrc: 12345,
        sosTimestampMs: now + 1,
      ),
      false,
    );
  });

  test('new SOS after tombstone remains relay eligible', () async {
    await DatabaseHelper.upsertAckTombstoneInDb(
      db,
      senderCrc: 12345,
      ackTimestampMs: now,
      status: SOSMessageStatus.resolved,
    );

    final sos = message(
      'new-after-ack',
      senderCrc: 12345,
      updatedAt: now + 1000,
    );
    await insertMessage(sos);
    await queue.enqueueSos(sos, nextEligibleAt: now);

    expect(
      await DatabaseHelper.isSuppressedByAckTombstoneInDb(
        db,
        senderCrc: 12345,
        sosTimestampMs: sos.updatedAt,
      ),
      false,
    );
    final next = await queue.nextEligible(now);
    expect(next, isNotNull);
    expect(next!.messageId, sos.id);
  });

  test(
    'crash recovery rebuilds ACK queue from tombstone without queue',
    () async {
      await DatabaseHelper.upsertAckTombstoneInDb(
        db,
        senderCrc: 24680,
        ackTimestampMs: now,
        status: SOSMessageStatus.resolved,
      );

      expect(await queue.queueSize(), 0);
      final restored = await queue.recoverAckQueueFromTombstones(nowMs: now);

      expect(restored, 1);
      final item = await queue.getItem('ack-24680', 'ack');
      expect(item, isNotNull);
      expect(item!.payloadBase64, isNotNull);
      final packet = BlePacket.unpack(
        base64Decode(item.payloadBase64!),
        referenceTime: DateTime.fromMillisecondsSinceEpoch(now),
      );
      expect(packet, isNotNull);
      expect(packet!.senderCrc, 24680);
      expect(packet.status, SOSMessageStatus.resolved);
    },
  );

  test('duplicate ACK restores missing queue item', () async {
    final payload = BlePacket.packAck(senderCrc: 13579, ackTimestampMs: now);
    await queue.enqueueAck(
      messageId: 'ack-13579-first',
      payloadBase64: base64Encode(payload),
    );
    await db.delete('relay_queue', where: "packet_type = 'ack'");

    final inserted = await queue.enqueueAck(
      messageId: 'ack-13579-duplicate',
      payloadBase64: base64Encode(payload),
    );

    expect(inserted, greaterThan(0));
    expect(await queue.getItem('ack-13579', 'ack'), isNotNull);
    expect(await queue.queueSize(), 1);
  });

  test('SOS and ACK in the same second are not wrongly suppressed', () async {
    await DatabaseHelper.upsertAckTombstoneInDb(
      db,
      senderCrc: 11223,
      ackTimestampMs: now,
      status: SOSMessageStatus.resolved,
    );
    final sameSecondSos = now + 500;

    expect(
      await DatabaseHelper.isSuppressedByAckTombstoneInDb(
        db,
        senderCrc: 11223,
        sosTimestampMs: sameSecondSos,
      ),
      false,
    );

    final sos = message(
      'same-second-new',
      senderCrc: 11223,
      updatedAt: sameSecondSos,
    );
    await DatabaseHelper.ensureMonotonicStateTimestampInDb(db, sos);

    expect(sos.updatedAt, now + 1000);
  });

  test(
    'new ACK resets queue relay metrics and becomes immediately eligible',
    () async {
      final oldPayload = BlePacket.packAck(
        senderCrc: 99887,
        ackTimestampMs: now,
      );
      await queue.enqueueAck(
        messageId: 'ack-99887-old',
        payloadBase64: base64Encode(oldPayload),
      );
      final oldItem = (await queue.getItem('ack-99887', 'ack'))!;
      await queue.markAdvertisingStarted(oldItem, nowMs: now);
      await queue.markAdvertisingSucceeded(oldItem, nowMs: now);

      final before = DateTime.now().millisecondsSinceEpoch;
      final newPayload = BlePacket.packAck(
        senderCrc: 99887,
        ackTimestampMs: now + 1000,
      );
      await queue.enqueueAck(
        messageId: 'ack-99887-new',
        payloadBase64: base64Encode(newPayload),
      );
      final after = DateTime.now().millisecondsSinceEpoch;

      final item = (await queue.getItem('ack-99887', 'ack'))!;
      expect(item.relayCount, 0);
      expect(item.lastRelayedAt, 0);
      expect(item.nextEligibleAt, inInclusiveRange(before, after));
      expect(item.queueState, RelayQueueService.stateQueued);
    },
  );

  test(
    'same timestamp tombstone upsert keeps existing payload when new payload is null',
    () async {
      final payload = base64Encode(
        BlePacket.packAck(
          senderCrc: 55667,
          ackTimestampMs: now,
          status: SOSMessageStatus.cancelled,
        ),
      );
      await DatabaseHelper.upsertAckTombstoneInDb(
        db,
        senderCrc: 55667,
        ackTimestampMs: now,
        status: SOSMessageStatus.cancelled,
        payloadBase64: payload,
      );
      await DatabaseHelper.upsertAckTombstoneInDb(
        db,
        senderCrc: 55667,
        ackTimestampMs: now,
        status: SOSMessageStatus.cancelled,
      );

      final tombstone = (await db.query('ack_tombstones')).single;
      expect(tombstone['payload_base64'], payload);
    },
  );

  test('newer or terminal state resets relay metadata', () async {
    final active = message('state-active', senderCrc: 777, updatedAt: now)
      ..relayCount = 7
      ..lastRelayedAt = now - const Duration(minutes: 1).inMilliseconds;
    await insertMessage(active);
    await queue.enqueueSos(active, nextEligibleAt: now + 60000);

    final cancelled = message(
      'state-cancelled',
      senderCrc: 777,
      updatedAt: now,
      status: SOSMessageStatus.cancelled,
    )..lastRelayedAt = now - const Duration(minutes: 1).inMilliseconds;

    await DatabaseHelper.replaceWithLatestMessageInDb(db, cancelled);
    await queue.enqueueSos(cancelled, priority: 50, nextEligibleAt: now);

    final stored = SOSMessage.fromDbMap(
      (await db.query('sos_messages')).single,
    );
    final queued = await queue.getItem(cancelled.id, 'sos');

    expect(stored.status, SOSMessageStatus.cancelled);
    expect(stored.relayCount, 0);
    expect(stored.lastRelayedAt, 0);
    expect(queued!.priority, 50);
    expect(queued.nextEligibleAt, now);
  });

  test(
    'ACTIVE does not replace terminal state at same timestamp in database',
    () async {
      final cancelled = message(
        'terminal-state',
        senderCrc: 888,
        updatedAt: now,
        status: SOSMessageStatus.cancelled,
      );
      await insertMessage(cancelled);

      final active = message('active-state', senderCrc: 888, updatedAt: now);
      await DatabaseHelper.replaceWithLatestMessageInDb(db, active);

      final stored = SOSMessage.fromDbMap(
        (await db.query('sos_messages')).single,
      );

      expect(stored.id, 'terminal-state');
      expect(stored.status, SOSMessageStatus.cancelled);
    },
  );

  test('RESOLVED replaces CANCELLED at same timestamp in database', () async {
    final cancelled = message(
      'cancelled-state',
      senderCrc: 889,
      updatedAt: now,
      status: SOSMessageStatus.cancelled,
    );
    await insertMessage(cancelled);

    final resolved = message(
      'resolved-state',
      senderCrc: 889,
      updatedAt: now,
      status: SOSMessageStatus.resolved,
    );
    await DatabaseHelper.replaceWithLatestMessageInDb(db, resolved);

    final stored = SOSMessage.fromDbMap(
      (await db.query('sos_messages')).single,
    );

    expect(stored.id, 'resolved-state');
    expect(stored.status, SOSMessageStatus.resolved);
  });

  test('duplicate queue item is not inserted twice', () async {
    final sos = message('same');
    await insertMessage(sos);
    await queue.enqueueSos(sos);
    await queue.enqueueSos(sos);

    expect(await queue.queueSize(), 1);
  });

  test('DROP_COOLDOWN decision is stored as deferred queue item', () async {
    final sos = message('cooldown');
    sos.hopCount = 3;
    sos.lastRelayedAt = now - const Duration(seconds: 2).inMilliseconds;
    await insertMessage(sos);

    final packet = BlePacket(
      kind: BlePacketKind.sos,
      senderCrc: sos.senderCrc!,
      timestampMs: sos.updatedAt,
      latitude: sos.latitude,
      longitude: sos.longitude,
      status: sos.status,
      hopCount: 0,
    );
    final decision = const ForwardingPolicy().decideSos(
      packet: packet,
      nowMs: now,
      existingMessage: sos,
    );

    expect(decision.reason, ForwardingDecisionReason.dropCooldown);
    await queue.enqueueSos(sos, nextEligibleAt: decision.nextEligibleAt);

    final item = await queue.getItem(sos.id, 'sos');
    expect(item, isNotNull);
    expect(item!.nextEligibleAt, decision.nextEligibleAt);
    expect(await queue.nextEligible(now), isNull);
  });

  test(
    'ACK transaction atomically tombstones, ACKs SOS, removes SOS queue, and queues ACK',
    () async {
      final sos = message('ack-transaction', senderCrc: 7001);
      await queue.storeAndQueueSos(message: sos, nextEligibleAt: now);

      final result = await queue.acceptAndQueueAck(
        senderCrc: 7001,
        ackTimestampMs: now + 123,
        status: SOSMessageStatus.resolved,
        nowMs: now,
      );

      final storedSos = SOSMessage.fromDbMap(
        (await db.query(
          'sos_messages',
          where: 'id = ?',
          whereArgs: [sos.id],
        )).single,
      );
      final tombstone = (await db.query('ack_tombstones')).single;

      expect(result, AckApplyResult.inserted);
      expect(storedSos.localState, 'acked');
      expect(storedSos.ackReceivedAt, canonicalProtocolTimestamp(now + 123));
      expect(await queue.getItem(sos.id, 'sos'), isNull);
      expect(await queue.getItem('ack-7001', 'ack'), isNotNull);
      expect(
        tombstone['ack_timestamp_ms'],
        canonicalProtocolTimestamp(now + 123),
      );
    },
  );

  test('ACK transaction rollback leaves no partial state', () async {
    final sos = message('ack-rollback', senderCrc: 7002);
    await queue.storeAndQueueSos(message: sos, nextEligibleAt: now);

    expect(
      () => queue.acceptAndQueueAck(
        senderCrc: 7002,
        ackTimestampMs: now,
        status: SOSMessageStatus.resolved,
        nowMs: now,
        failAfterTombstoneForTest: true,
      ),
      throwsStateError,
    );

    final storedSos = SOSMessage.fromDbMap(
      (await db.query(
        'sos_messages',
        where: 'id = ?',
        whereArgs: [sos.id],
      )).single,
    );
    expect(await db.query('ack_tombstones'), isEmpty);
    expect(storedSos.localState, 'pending');
    expect(await queue.getItem(sos.id, 'sos'), isNotNull);
    expect(await queue.getItem('ack-7002', 'ack'), isNull);
  });

  test(
    'ACK transaction handles unknown sender and duplicate queue recovery',
    () async {
      final first = await queue.acceptAndQueueAck(
        senderCrc: 7003,
        ackTimestampMs: now,
        status: SOSMessageStatus.resolved,
        nowMs: now,
      );
      await db.delete('relay_queue', where: "packet_type = 'ack'");
      final duplicate = await queue.acceptAndQueueAck(
        senderCrc: 7003,
        ackTimestampMs: now,
        status: SOSMessageStatus.resolved,
        nowMs: now,
      );

      expect(first, AckApplyResult.inserted);
      expect(duplicate, AckApplyResult.duplicate);
      expect(await db.query('ack_tombstones'), hasLength(1));
      expect(await queue.getItem('ack-7003', 'ack'), isNotNull);
    },
  );

  test('duplicate ACK does not reset relay metadata', () async {
    await queue.acceptAndQueueAck(
      senderCrc: 7004,
      ackTimestampMs: now,
      status: SOSMessageStatus.resolved,
      nowMs: now,
    );
    final item = (await queue.getItem('ack-7004', 'ack'))!;
    await queue.markAdvertisingStarted(item, nowMs: now);
    await queue.markAdvertisingSucceeded(item, nowMs: now);
    final before = (await queue.getItem('ack-7004', 'ack'))!;

    final duplicate = await queue.acceptAndQueueAck(
      senderCrc: 7004,
      ackTimestampMs: now,
      status: SOSMessageStatus.resolved,
      nowMs: now,
    );
    final after = (await queue.getItem('ack-7004', 'ack'))!;

    expect(duplicate, AckApplyResult.duplicate);
    expect(after.relayCount, before.relayCount);
    expect(after.lastRelayedAt, before.lastRelayedAt);
    expect(after.nextEligibleAt, before.nextEligibleAt);
    expect(after.queueState, before.queueState);
  });

  test(
    'ACK status ordering accepts RESOLVED upgrade and rejects downgrade or older ACK',
    () async {
      final inserted = await queue.acceptAndQueueAck(
        senderCrc: 7005,
        ackTimestampMs: now,
        status: SOSMessageStatus.cancelled,
        nowMs: now,
      );
      final upgraded = await queue.acceptAndQueueAck(
        senderCrc: 7005,
        ackTimestampMs: now,
        status: SOSMessageStatus.resolved,
        nowMs: now,
      );
      final downgrade = await queue.acceptAndQueueAck(
        senderCrc: 7005,
        ackTimestampMs: now,
        status: SOSMessageStatus.cancelled,
        nowMs: now,
      );
      final older = await queue.acceptAndQueueAck(
        senderCrc: 7005,
        ackTimestampMs: now - 1000,
        status: SOSMessageStatus.resolved,
        nowMs: now,
      );
      final tombstone = (await db.query('ack_tombstones')).single;

      expect(inserted, AckApplyResult.inserted);
      expect(upgraded, AckApplyResult.replacedHigherStatus);
      expect(downgrade, AckApplyResult.duplicate);
      expect(older, AckApplyResult.rejectedOlder);
      expect(tombstone['status'], SOSMessageStatus.resolved.index);
    },
  );

  test('ACK too far in the future is rejected', () async {
    final result = await queue.acceptAndQueueAck(
      senderCrc: 7006,
      ackTimestampMs: now + MeshConfig.maxClockSkew.inMilliseconds + 2000,
      status: SOSMessageStatus.resolved,
      nowMs: now,
    );

    expect(result, AckApplyResult.rejectedFuture);
    expect(await db.query('ack_tombstones'), isEmpty);
  });

  test('SOS transaction stores message and queue atomically', () async {
    final sos = message('sos-transaction', senderCrc: 8001);

    final stored = await queue.storeAndQueueSos(
      message: sos,
      nextEligibleAt: now,
    );

    expect(stored, true);
    expect(await db.query('sos_messages'), hasLength(1));
    expect(await queue.getItem(sos.id, 'sos'), isNotNull);
  });

  test('SOS transaction rollback leaves no SOS without queue', () async {
    final sos = message('sos-rollback', senderCrc: 8002);

    expect(
      () => queue.storeAndQueueSos(
        message: sos,
        nextEligibleAt: now,
        failAfterStoreForTest: true,
      ),
      throwsStateError,
    );

    expect(await db.query('sos_messages'), isEmpty);
    expect(await queue.queueSize(), 0);
  });

  test(
    'SOS recovery restores missing queues without duplicating valid queues',
    () async {
      final missing = message('recover-missing', senderCrc: 8003);
      final existing = message('recover-existing', senderCrc: 8004)
        ..relayCount = 3
        ..lastRelayedAt = now - const Duration(seconds: 1).inMilliseconds;
      final acked = message('recover-acked', senderCrc: 8005)
        ..ackReceivedAt = now
        ..localState = 'acked';
      final terminal = message(
        'recover-terminal',
        senderCrc: 8006,
        status: SOSMessageStatus.resolved,
      );
      await insertMessage(missing);
      await insertMessage(existing);
      await insertMessage(acked);
      await insertMessage(terminal);
      await queue.enqueueSos(existing, nextEligibleAt: now + 9999);

      final recovered = await queue.recoverSosQueueFromMessages(nowMs: now);

      expect(recovered, 2);
      expect(await queue.getItem(missing.id, 'sos'), isNotNull);
      final existingQueue = (await queue.getItem(existing.id, 'sos'))!;
      final terminalQueue = (await queue.getItem(terminal.id, 'sos'))!;
      expect(existingQueue.relayCount, 3);
      expect(existingQueue.nextEligibleAt, now + 9999);
      expect(await queue.getItem(acked.id, 'sos'), isNull);
      expect(terminalQueue.priority, 60);
      expect(terminalQueue.nextEligibleAt, now);
    },
  );

  test(
    'storeAndQueueSos accepts newer ACTIVE after ACK and rejects stale state',
    () async {
      await queue.acceptAndQueueAck(
        senderCrc: 8007,
        ackTimestampMs: now,
        status: SOSMessageStatus.resolved,
        nowMs: now,
      );
      final newer = message(
        'newer-after-ack',
        senderCrc: 8007,
        updatedAt: now + 1000,
      );
      final stale = message(
        'stale-after-newer',
        senderCrc: 8007,
        updatedAt: now,
      );

      expect(
        await queue.storeAndQueueSos(message: newer, nextEligibleAt: now),
        true,
      );
      expect(
        await queue.storeAndQueueSos(message: stale, nextEligibleAt: now),
        false,
      );
      final stored = SOSMessage.fromDbMap(
        (await db.query('sos_messages')).single,
      );
      expect(stored.id, newer.id);
    },
  );

  test(
    'canonical timestamp is used by tombstone payload and packet identity',
    () async {
      final rawTimestamp = now + 123;
      await queue.acceptAndQueueAck(
        senderCrc: 9001,
        ackTimestampMs: rawTimestamp,
        status: SOSMessageStatus.resolved,
        nowMs: now,
      );

      final tombstone = (await db.query('ack_tombstones')).single;
      final item = (await queue.getItem('ack-9001', 'ack'))!;
      final packet = BlePacket.unpack(
        base64Decode(item.payloadBase64!),
        referenceTime: DateTime.fromMillisecondsSinceEpoch(rawTimestamp),
      )!;
      final tombstoneTimestamp = tombstone['ack_timestamp_ms'] as int;

      expect(tombstoneTimestamp, canonicalProtocolTimestamp(rawTimestamp));
      expect(packet.timestampMs, tombstoneTimestamp);
      expect(packet.identity, 'ACK:9001:$tombstoneTimestamp:2');
    },
  );

  test(
    'local monotonic timestamps advance by second but incoming packet is unchanged',
    () async {
      final first = message('mono-first', senderCrc: 9002, updatedAt: now);
      await insertMessage(first);
      final second = message(
        'mono-second',
        senderCrc: 9002,
        updatedAt: now + 500,
      );
      await DatabaseHelper.ensureMonotonicStateTimestampInDb(db, second);
      final packet = BlePacket(
        kind: BlePacketKind.sos,
        senderCrc: 9002,
        timestampMs: now + 500,
        latitude: -6.2,
        longitude: 106.8,
        status: SOSMessageStatus.active,
      );

      expect(second.updatedAt, now + 1000);
      expect(packet.timestampMs, now + 500);
    },
  );

  test(
    'basic flooding and controlled epidemic use different slot durations',
    () {
      final basic = RelayQueueService(
        database: db,
        mode: ForwardingMode.basicFlooding,
      );
      final controlled = RelayQueueService(
        database: db,
        mode: ForwardingMode.controlledEpidemic,
      );

      expect(basic.slotDurationForMode(), MeshConfig.basicFloodingSlotDuration);
      expect(controlled.slotDurationForMode(), MeshConfig.relaySlotDuration);
    },
  );

  test('ACK fairness yields SOS after maximum consecutive ACK slots', () async {
    final sos = message('fairness-sos', senderCrc: 9100);
    await insertMessage(sos);
    await queue.enqueueSos(sos, nextEligibleAt: now);
    for (final crc in [9101, 9102, 9103, 9104]) {
      await queue.acceptAndQueueAck(
        senderCrc: crc,
        ackTimestampMs: now,
        status: SOSMessageStatus.resolved,
        nowMs: now,
      );
    }

    final selected = <String>[];
    for (var i = 0; i < 4; i++) {
      final item = (await queue.nextEligible(now))!;
      selected.add(item.packetType);
      await queue.markAdvertisingStarted(item, nowMs: now + i);
      await queue.markAdvertisingSucceeded(item, nowMs: now + i);
    }

    expect(selected.take(3).every((type) => type == 'ack'), true);
    expect(selected[3], 'sos');
  });

  test('queue state persists across service instances', () async {
    final sos = message('persistent');
    await insertMessage(sos);
    await queue.enqueueSos(sos);

    final restoredQueue = RelayQueueService(database: db);
    final restored = await restoredQueue.nextEligible(now);

    expect(restored, isNotNull);
    expect(restored!.messageId, sos.id);
  });

  test('earliestNextEligibleAt ignores disabled queue items', () async {
    final early = message('wake-early');
    final later = message('wake-later');
    final disabled = message('wake-disabled');
    await insertMessage(early);
    await insertMessage(later);
    await insertMessage(disabled);
    await queue.enqueueSos(early, nextEligibleAt: now + 3000);
    await queue.enqueueSos(later, nextEligibleAt: now + 9000);
    await queue.enqueueSos(disabled, nextEligibleAt: now + 1000);
    await db.update(
      'relay_queue',
      {'queue_state': 'disabled'},
      where: 'message_id = ?',
      whereArgs: [disabled.id],
    );

    expect(await queue.earliestNextEligibleAt(), now + 3000);
  });
}
