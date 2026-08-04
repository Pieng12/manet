import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:pkmproject/config/mesh_config.dart';
import 'package:pkmproject/database_schema.dart';
import 'package:pkmproject/models/forwarding_decision.dart';
import 'package:pkmproject/models/sos_message.dart';
import 'package:pkmproject/services/ble_protocol.dart';
import 'package:pkmproject/services/forwarding_policy.dart';
import 'package:pkmproject/services/relay_queue_service.dart';
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
    queue = RelayQueueService(database: db, random: Random(1));
    now = DateTime.utc(2026, 8, 4, 12).millisecondsSinceEpoch;
  });

  tearDown(() async {
    await db.close();
  });

  SOSMessage message(String id, {int offsetSeconds = 0, bool expired = false}) {
    final createdAt = now + Duration(seconds: offsetSeconds).inMilliseconds;
    return SOSMessage(
      id: id,
      senderId: 'device-$id',
      senderCrc: id.hashCode,
      content: 'SOS',
      latitude: -6.2,
      longitude: 106.8,
      status: SOSMessageStatus.active,
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
    final sos = message('max-relay')..relayCount = MeshConfig.maxRelayCount - 1;
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
    expect(stored.relayCount, MeshConfig.maxRelayCount);
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

  test('old ACK item remains in persistent queue', () async {
    final oldAckTimestamp = now - MeshConfig.ackLifetime.inMilliseconds;
    final ackPayload = BlePacket.packAck(
      senderCrc: 12345,
      ackTimestampMs: oldAckTimestamp,
    );
    await queue.enqueueAck(
      messageId: 'ack-12345-$oldAckTimestamp-2',
      payloadBase64: base64Encode(ackPayload),
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

  test('duplicate queue item is not inserted twice', () async {
    final sos = message('same');
    await insertMessage(sos);
    await queue.enqueueSos(sos);
    await queue.enqueueSos(sos);

    expect(await queue.queueSize(), 1);
  });

  test('DROP_COOLDOWN decision is stored as deferred queue item', () async {
    final sos = message('cooldown');
    sos.lastRelayedAt = now - const Duration(seconds: 2).inMilliseconds;
    await insertMessage(sos);

    final packet = BlePacket(
      kind: BlePacketKind.sos,
      senderCrc: sos.senderCrc!,
      timestampMs: sos.updatedAt + 1000,
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

  test('queue state persists across service instances', () async {
    final sos = message('persistent');
    await insertMessage(sos);
    await queue.enqueueSos(sos);

    final restoredQueue = RelayQueueService(database: db);
    final restored = await restoredQueue.nextEligible(now);

    expect(restored, isNotNull);
    expect(restored!.messageId, sos.id);
  });
}
