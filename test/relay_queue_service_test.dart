import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pkmproject/config/mesh_config.dart';
import 'package:pkmproject/database_schema.dart';
import 'package:pkmproject/models/sos_message.dart';
import 'package:pkmproject/services/ble_protocol.dart';
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
    queue = RelayQueueService(database: db);
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

  test('round robin returns oldest relayed item after slot cooldown', () async {
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
    final next = await queue.nextEligible(afterSlot);

    expect(next, isNotNull);
    expect(next!.messageId, first.messageId);
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

  test('expired ACK item is removed from queue', () async {
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

    expect(next, isNull);
    expect(await queue.queueSize(), 0);
  });

  test('expired SOS item is removed from queue', () async {
    final expired = message('expired', expired: true);
    await insertMessage(expired);
    await queue.enqueueSos(expired);

    final next = await queue.nextEligible(now);
    final size = await queue.queueSize();

    expect(size, 0);
    expect(next, isNull);
  });

  test('duplicate queue item is not inserted twice', () async {
    final sos = message('same');
    await insertMessage(sos);
    await queue.enqueueSos(sos);
    await queue.enqueueSos(sos);

    expect(await queue.queueSize(), 1);
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
