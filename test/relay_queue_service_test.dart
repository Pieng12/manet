import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:pkmproject/config/mesh_config.dart';
import 'package:pkmproject/database_schema.dart';
import 'package:pkmproject/models/ack_apply_result.dart';
import 'package:pkmproject/models/experiment_session.dart';
import 'package:pkmproject/models/forwarding_decision.dart';
import 'package:pkmproject/models/sos_message.dart';
import 'package:pkmproject/models/trickle_state.dart';
import 'package:pkmproject/services/ble_relay_service.dart';
import 'package:pkmproject/services/ble_protocol.dart';
import 'package:pkmproject/services/database_helper.dart';
import 'package:pkmproject/services/forwarding_policy.dart';
import 'package:pkmproject/services/relay_queue_service.dart';
import 'package:pkmproject/services/topology_policy.dart';
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
    await db.execute(createTrickleStatesTableSql);
    await db.execute(createTrickleObservationsTableSql);
    await db.execute(createProcessedBleObservationsTableSql);
    queue = RelayQueueService(
      database: db,
      random: Random(1),
      mode: ForwardingMode.basicFlooding,
    );
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
    int hopCount = 0,
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
      hopCount: hopCount,
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
    'basic flooding returns relayed SOS after fixed interval and jitter',
    () async {
      final basicQueue = RelayQueueService(
        database: db,
        random: Random(1),
        mode: ForwardingMode.basicFlooding,
      );
      final messages = [message('a'), message('b'), message('c')];
      for (final item in messages) {
        await insertMessage(item);
        await basicQueue.enqueueSos(item, nextEligibleAt: now);
      }

      final first = await basicQueue.nextEligible(now);
      await basicQueue.markRelayed(first!, nowMs: now);
      final second = await basicQueue.nextEligible(now);
      await basicQueue.markRelayed(second!, nowMs: now + 1);
      final third = await basicQueue.nextEligible(now);
      await basicQueue.markRelayed(third!, nowMs: now + 2);

      final beforeInterval =
          now +
          MeshConfig.sosAdvertiseBurstDuration.inMilliseconds +
          MeshConfig.basicFloodingInterval.inMilliseconds -
          1;
      expect(await basicQueue.nextEligible(beforeInterval), isNull);

      final afterInterval =
          now +
          MeshConfig.sosAdvertiseBurstDuration.inMilliseconds +
          MeshConfig.basicFloodingInterval.inMilliseconds +
          MeshConfig.relayJitterMax.inMilliseconds +
          1;
      final next = await basicQueue.nextEligible(afterInterval);

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
    'advertising success increments counters and reschedules with jitter',
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
              MeshConfig.sosAdvertiseBurstDuration.inMilliseconds +
              MeshConfig.basicFloodingInterval.inMilliseconds +
              MeshConfig.relayJitterMin.inMilliseconds,
        ),
      );
      expect(
        queued.nextEligibleAt,
        lessThanOrEqualTo(
          now +
              MeshConfig.sosAdvertiseBurstDuration.inMilliseconds +
              MeshConfig.basicFloodingInterval.inMilliseconds +
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

  test('relay count never disables persistent SOS scheduling', () async {
    final sos = message('relay-count-metric')..relayCount = 99;
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

  test('ACK deletes matching Trickle state', () async {
    final trickle = RelayQueueService(
      database: db,
      random: Random(1),
      mode: ForwardingMode.trickle,
    );
    final sos = message('trickle-acked', senderCrc: 12345, updatedAt: now);
    await trickle.storeAndQueueSos(message: sos, nextEligibleAt: now);
    expect(await trickle.trickleStateFor(sos.id), isNotNull);

    await trickle.acceptAndQueueAck(
      senderCrc: sos.senderCrc!,
      ackTimestampMs: now,
      status: SOSMessageStatus.resolved,
      nowMs: now,
    );

    expect(await trickle.getItem(sos.id, 'sos'), isNull);
    expect(await trickle.trickleStateFor(sos.id), isNull);
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

  test('ACK queue is keyed by sender and protocol timestamp', () async {
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

    expect(rows, hasLength(2));
    final newest = rows.last;
    expect(
      newest['message_id'],
      RelayQueueService.ackMessageId(
        senderCrc: 12345,
        ackTimestampMs: now + 1000,
        statusIndex: SOSMessageStatus.resolved.index,
      ),
    );
    final packet = BlePacket.unpack(
      base64Decode(newest['payload_base64'] as String),
      referenceTime: DateTime.fromMillisecondsSinceEpoch(now + 1000),
    );
    expect(packet!.timestampMs, now + 1000);
    expect(tombstone, hasLength(2));
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

  test('queue ACK remains bounded per logical message key', () async {
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
    expect(rows, hasLength(20));
    expect(rows.map((row) => row['message_id']).toSet(), hasLength(20));
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

  test('basic flooding and trickle produce different SOS schedules', () async {
    final basic = RelayQueueService(
      database: db,
      random: Random(1),
      mode: ForwardingMode.basicFlooding,
    );
    final trickle = RelayQueueService(
      database: db,
      random: Random(1),
      mode: ForwardingMode.trickle,
    );
    final basicMessage = message('basic-schedule', senderCrc: 4100);
    final trickleMessage = message('trickle-schedule', senderCrc: 4200);

    await basic.storeAndQueueSos(message: basicMessage, nextEligibleAt: now);
    await trickle.storeAndQueueSos(
      message: trickleMessage,
      nextEligibleAt: now,
    );
    final basicItem = await basic.getItem(basicMessage.id, 'sos');
    final trickleItem = await trickle.getItem(trickleMessage.id, 'sos');

    expect(basicItem!.nextEligibleAt, now);
    expect(trickleItem!.nextEligibleAt, isNot(now));
    expect(
      trickleItem.nextEligibleAt,
      inInclusiveRange(
        now + MeshConfig.trickleImin.inMilliseconds ~/ 2,
        now + MeshConfig.trickleImin.inMilliseconds - 1,
      ),
    );
  });

  test(
    'trickle suppresses queue transmission when consistency reaches k',
    () async {
      final trickle = RelayQueueService(
        database: db,
        random: Random(1),
        mode: ForwardingMode.trickle,
      );
      final sos = message('trickle-suppress', senderCrc: 4300);
      await trickle.storeAndQueueSos(message: sos, nextEligibleAt: now);
      var item = (await trickle.getItem(sos.id, 'sos'))!;

      expect(
        await trickle.recordConsistentSosObservation(
          messageId: sos.id,
          observationId: 'obs-1',
          observerKey: 'AA:BB:CC:DD:EE:FF',
          nowMs: now + 1,
        ),
        isTrue,
      );
      final decision = await trickle.handleTrickleQueueEvent(
        item: item,
        nowMs: item.nextEligibleAt,
      );
      item = (await trickle.getItem(sos.id, 'sos'))!;

      expect(decision.type, TrickleTransmitDecisionType.suppressTransmit);
      expect(decision.shouldAdvertise, isFalse);
      expect(item.queueState, RelayQueueService.stateQueued);
      expect(item.relayCount, 0);
      expect(item.nextEligibleAt, decision.state.intervalEndAt);
    },
  );

  test(
    'parallel relay suppresses R2 for one interval without replacing state',
    () async {
      final trickle = RelayQueueService(
        database: db,
        random: Random(7),
        mode: ForwardingMode.trickle,
      );
      final sourcePacket = BlePacket(
        kind: BlePacketKind.sos,
        senderCrc: 4400,
        timestampMs: now,
        latitude: 3.5952,
        longitude: 98.6722,
        status: SOSMessageStatus.active,
        hopCount: 1,
      );
      final localState = BleRelayService.messageFromSosPacket(
        sourcePacket,
        now,
      );
      await trickle.storeAndQueueSos(message: localState, nextEligibleAt: now);
      final beforeItem = (await trickle.getItem(localState.id, 'sos'))!;
      final beforeState = (await trickle.trickleStateFor(localState.id))!;

      final peerPacket = BlePacket(
        kind: BlePacketKind.sos,
        senderCrc: sourcePacket.senderCrc,
        timestampMs: sourcePacket.timestampMs,
        latitude: sourcePacket.latitude,
        longitude: sourcePacket.longitude,
        status: sourcePacket.status,
        hopCount: 2,
      );
      final topology = const TopologyPolicy().evaluate(
        packet: peerPacket,
        session: ExperimentSession(
          sessionId: 'parallel-relay',
          deviceId: 'R2',
          deviceModel: 'test',
          androidVersion: 'test',
          forwardingMode: 'trickle',
          maxHop: 63,
          messageLifetimeMs: 0,
          relayCooldownMs: 0,
          startedAt: now - 1000,
          sessionKind: 'RESEARCH',
          nodeRole: 'RELAY',
          protocolActive: true,
          expectedHopIn: 1,
        ),
        existingMessage: localState,
        observerKey: 'ble:R1',
      );

      expect(topology.countAsLogicalDuplicate, isTrue);
      expect(topology.countAsTrickleConsistency, isTrue);
      expect(topology.acceptForState, isFalse);
      expect(topology.relay, isFalse);
      final recorded = await trickle.recordLogicalDuplicateObservation(
        messageId: localState.id,
        observationId: 'r1-burst-1',
        observerKey: 'ble:R1',
        nowMs: beforeState.transmitAt - 1,
      );
      expect(recorded.trickleRecorded, isTrue);

      final atTransmit = (await trickle.getItem(localState.id, 'sos'))!;
      final decision = await trickle.handleTrickleQueueEvent(
        item: atTransmit,
        nowMs: beforeState.transmitAt,
      );
      final storedMessage = SOSMessage.fromDbMap(
        (await db.query(
          'sos_messages',
          where: 'id = ?',
          whereArgs: [localState.id],
        )).single,
      );
      final afterSuppression = (await trickle.getItem(localState.id, 'sos'))!;

      expect(decision.type, TrickleTransmitDecisionType.suppressTransmit);
      expect(decision.state.consistencyCount, 1);
      expect(storedMessage.hopCount, 2);
      expect(storedMessage.relayCount, 0);
      expect(afterSuppression.relayCount, beforeItem.relayCount);
      expect(afterSuppression.queueState, RelayQueueService.stateQueued);

      final nextInterval = await trickle.handleTrickleQueueEvent(
        item: afterSuppression,
        nowMs: decision.state.intervalEndAt,
      );
      final persisted = await trickle.trickleStateFor(localState.id);

      expect(nextInterval.type, TrickleTransmitDecisionType.intervalAdvanced);
      expect(persisted, isNotNull);
      expect(persisted!.intervalMs, MeshConfig.trickleImin.inMilliseconds * 2);
      expect(persisted.consistencyCount, 0);
      expect(await trickle.getItem(localState.id, 'sos'), isNotNull);
    },
  );

  test('upstream repeat is a duplicate but not Trickle consistency', () async {
    final trickle = RelayQueueService(
      database: db,
      random: Random(9),
      mode: ForwardingMode.trickle,
    );
    final sos = message('upstream-repeat', senderCrc: 4410);
    await trickle.storeAndQueueSos(message: sos, nextEligibleAt: now);

    final recorded = await trickle.recordLogicalDuplicateObservation(
      messageId: sos.id,
      observationId: 'source-burst-repeat',
      observerKey: 'source',
      nowMs: now + 1,
      countAsTrickleConsistency: false,
    );
    final state = await trickle.trickleStateFor(sos.id);
    final stored = (await db.query(
      'sos_messages',
      where: 'id = ?',
      whereArgs: [sos.id],
    )).single;

    expect(recorded.trickleRecorded, isFalse);
    expect(state!.consistencyCount, 0);
    expect(stored['duplicate_count'], 1);
  });

  test(
    'basic flooding records duplicate without Trickle suppression',
    () async {
      final sos = message('basic-logical-duplicate', senderCrc: 4411);
      await queue.storeAndQueueSos(message: sos, nextEligibleAt: now);

      final recorded = await queue.recordLogicalDuplicateObservation(
        messageId: sos.id,
        observationId: 'basic-burst-duplicate',
        observerKey: 'ble:R1',
        nowMs: now + 1,
      );
      final stored = (await db.query(
        'sos_messages',
        where: 'id = ?',
        whereArgs: [sos.id],
      )).single;

      expect(stored['duplicate_count'], 1);
      expect(recorded.trickleRecorded, isFalse);
      expect(await queue.trickleStateFor(sos.id), isNull);
    },
  );

  test('trickle observation id controls idempotent c increments', () async {
    final trickle = RelayQueueService(
      database: db,
      random: Random(1),
      mode: ForwardingMode.trickle,
    );
    final sos = message('trickle-observations', senderCrc: 4350);
    await trickle.storeAndQueueSos(message: sos, nextEligibleAt: now);

    expect(
      await trickle.recordConsistentSosObservation(
        messageId: sos.id,
        observationId: 'obs-1',
        observerKey: 'ble:AA',
        nowMs: now + 1,
      ),
      isTrue,
    );
    expect(
      await trickle.recordConsistentSosObservation(
        messageId: sos.id,
        observationId: 'obs-1',
        observerKey: 'ble:AA',
        nowMs: now + 2,
      ),
      isFalse,
    );
    expect(
      await trickle.recordConsistentSosObservation(
        messageId: sos.id,
        observationId: 'obs-2',
        observerKey: 'ble:AA',
        nowMs: now + 3,
      ),
      isTrue,
    );
    expect(
      await trickle.recordConsistentSosObservation(
        messageId: sos.id,
        observationId: 'obs-3',
        observerKey: 'ble:BB',
        nowMs: now + 4,
      ),
      isTrue,
    );

    final state = await trickle.trickleStateFor(sos.id);
    expect(state!.consistencyCount, 3);
  });

  test(
    'relay queue records observations by native receive time, not processing time',
    () async {
      final trickle = RelayQueueService(
        database: db,
        random: Random(1),
        mode: ForwardingMode.trickle,
      );
      final sos = message('trickle-receive-time', senderCrc: 4360);
      await trickle.storeAndQueueSos(message: sos, nextEligibleAt: now);
      final initial = (await trickle.trickleStateFor(sos.id))!;
      final item = (await trickle.getItem(sos.id, 'sos'))!;

      await trickle.handleTrickleQueueEvent(
        item: item,
        nowMs: initial.intervalEndAt,
      );
      final advanced = (await trickle.trickleStateFor(sos.id))!;
      expect(advanced.intervalStartedAt, initial.intervalEndAt);

      final oldReceive = initial.intervalStartedAt + 4000;
      expect(
        await trickle.recordConsistentSosObservation(
          messageId: sos.id,
          observationId: 'old-native-obs',
          observerKey: 'ble:AA',
          nowMs: oldReceive,
        ),
        isFalse,
      );

      final currentReceive = advanced.intervalStartedAt + 2000;
      expect(
        await trickle.recordConsistentSosObservation(
          messageId: sos.id,
          observationId: 'current-native-obs',
          observerKey: 'ble:AA',
          nowMs: currentReceive,
        ),
        isTrue,
      );
      expect(
        await trickle.recordConsistentSosObservation(
          messageId: sos.id,
          observationId: 'current-native-obs',
          observerKey: 'ble:AA',
          nowMs: currentReceive + 1,
        ),
        isFalse,
      );

      final state = await trickle.trickleStateFor(sos.id);
      final observations = await db.query('trickle_observations');
      expect(state!.consistencyCount, 1);
      expect(observations, hasLength(1));
      expect(observations.single['observation_id'], 'current-native-obs');
    },
  );

  test(
    'same native observation through direct and inbox paths increments c once',
    () async {
      final trickle = RelayQueueService(
        database: db,
        random: Random(1),
        mode: ForwardingMode.trickle,
      );
      final sos = message('trickle-direct-inbox', senderCrc: 4361);
      await trickle.storeAndQueueSos(message: sos, nextEligibleAt: now);

      for (final source in ['direct', 'inbox']) {
        final recorded = await trickle.recordConsistentSosObservation(
          messageId: sos.id,
          observationId: 'obs-123',
          observerKey: 'ble:AA:BB',
          nowMs: now + (source == 'direct' ? 100 : 200),
        );
        expect(recorded, source == 'direct');
      }

      var state = await trickle.trickleStateFor(sos.id);
      expect(state!.consistencyCount, 1);

      final reverse = message('trickle-inbox-direct', senderCrc: 4362);
      await trickle.storeAndQueueSos(message: reverse, nextEligibleAt: now);
      for (final source in ['inbox', 'direct']) {
        final recorded = await trickle.recordConsistentSosObservation(
          messageId: reverse.id,
          observationId: 'obs-456',
          observerKey: 'ble:CC:DD',
          nowMs: now + (source == 'inbox' ? 300 : 400),
        );
        expect(recorded, source == 'inbox');
      }

      state = await trickle.trickleStateFor(reverse.id);
      expect(state!.consistencyCount, 1);
    },
  );

  test(
    'trickle interval end doubles I and schedules the next transmit',
    () async {
      final trickle = RelayQueueService(
        database: db,
        random: Random(1),
        mode: ForwardingMode.trickle,
      );
      final sos = message('trickle-double', senderCrc: 4400);
      await trickle.storeAndQueueSos(message: sos, nextEligibleAt: now);
      final initial = (await trickle.trickleStateFor(sos.id))!;
      final item = (await trickle.getItem(sos.id, 'sos'))!;

      final decision = await trickle.handleTrickleQueueEvent(
        item: item,
        nowMs: initial.intervalEndAt,
      );
      final queued = (await trickle.getItem(sos.id, 'sos'))!;

      expect(decision.type, TrickleTransmitDecisionType.intervalAdvanced);
      expect(
        decision.state.intervalMs,
        MeshConfig.trickleImin.inMilliseconds * 2,
      );
      expect(queued.nextEligibleAt, decision.nextEligibleAt);
      expect(
        queued.nextEligibleAt,
        inInclusiveRange(
          initial.intervalEndAt + MeshConfig.trickleImin.inMilliseconds,
          initial.intervalEndAt + MeshConfig.trickleImin.inMilliseconds * 2 - 1,
        ),
      );
    },
  );

  test('ACK tombstone suppresses only its exact logical SOS key', () async {
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
        sosTimestampMs: now,
      ),
      true,
    );
    expect(
      await DatabaseHelper.isSuppressedByAckTombstoneInDb(
        db,
        senderCrc: 12345,
        sosTimestampMs: now + 1000,
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
      final item = await queue.getItem(
        RelayQueueService.ackMessageId(
          senderCrc: 24680,
          ackTimestampMs: now,
          statusIndex: SOSMessageStatus.resolved.index,
        ),
        'ack',
      );
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
    expect(
      await queue.getItem(
        RelayQueueService.ackMessageId(
          senderCrc: 13579,
          ackTimestampMs: now,
          statusIndex: SOSMessageStatus.resolved.index,
        ),
        'ack',
      ),
      isNotNull,
    );
    expect(await queue.queueSize(), 1);
  });

  test(
    'same-key ACK suppresses SOS and a second new SOS is rejected',
    () async {
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
        true,
      );

      final sos = message(
        'same-second-new',
        senderCrc: 11223,
        updatedAt: sameSecondSos,
      );
      expect(
        () => DatabaseHelper.ensureMonotonicStateTimestampInDb(db, sos),
        throwsStateError,
      );
    },
  );

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
      final oldId = RelayQueueService.ackMessageId(
        senderCrc: 99887,
        ackTimestampMs: now,
        statusIndex: SOSMessageStatus.resolved.index,
      );
      final oldItem = (await queue.getItem(oldId, 'ack'))!;
      await queue.markAdvertisingStarted(oldItem, nowMs: now);
      await queue.markAdvertisingSucceeded(oldItem, nowMs: now);

      final newPayload = BlePacket.packAck(
        senderCrc: 99887,
        ackTimestampMs: now + 1000,
      );
      await queue.enqueueAck(
        messageId: 'ack-99887-new',
        payloadBase64: base64Encode(newPayload),
        nextEligibleAt: now + 1000,
      );

      final newId = RelayQueueService.ackMessageId(
        senderCrc: 99887,
        ackTimestampMs: now + 1000,
        statusIndex: SOSMessageStatus.resolved.index,
      );
      final item = (await queue.getItem(newId, 'ack'))!;
      expect(item.relayCount, 0);
      expect(item.lastRelayedAt, 0);
      expect(item.nextEligibleAt, now + 1000);
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

  test('accepted SOS is stored as immediate queue work', () async {
    final sos = message('accepted-immediate');
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

    expect(decision.reason, ForwardingDecisionReason.relayAccepted);
    await queue.enqueueSos(sos, nextEligibleAt: now);

    final item = await queue.getItem(sos.id, 'sos');
    expect(item, isNotNull);
    expect(item!.nextEligibleAt, now);
    expect(await queue.nextEligible(now), isNotNull);
  });

  test(
    'better-hop policy and storage update SQLite queue and advertised hop',
    () async {
      const senderCrc = 424242;
      final timestamp = canonicalProtocolTimestamp(now);
      final existing = message(
        'ble-$senderCrc-$timestamp',
        senderCrc: senderCrc,
        updatedAt: timestamp,
        hopCount: 3,
      )..senderId = 'ble-device-$senderCrc';
      await queue.storeAndQueueSos(
        message: existing,
        nextEligibleAt: now + 60000,
      );

      final packet = BlePacket(
        kind: BlePacketKind.sos,
        senderCrc: senderCrc,
        timestampMs: timestamp,
        latitude: existing.latitude,
        longitude: existing.longitude,
        status: SOSMessageStatus.active,
        hopCount: 0,
      );
      final decision = const ForwardingPolicy().decideSos(
        packet: packet,
        nowMs: now,
        existingMessage: existing,
      );
      final incoming = BleRelayService.messageFromSosPacket(packet, now)
        ..localState = 'queued';
      incoming.hopCount = decision.nextHopCount!;

      expect(decision.shouldStore, true);
      expect(decision.nextHopCount, 1);
      expect(
        await queue.storeAndQueueSos(message: incoming, nextEligibleAt: now),
        true,
      );

      final stored = SOSMessage.fromDbMap(
        (await db.query('sos_messages')).single,
      );
      final queued = await queue.getItem(incoming.id, 'sos');
      final advertised = BlePacket.unpack(BlePacket.packSos(stored))!;

      expect(stored.id, incoming.id);
      expect(stored.hopCount, 1);
      expect(stored.relayCount, 0);
      expect(stored.lastRelayedAt, 0);
      expect(queued, isNotNull);
      expect(queued!.messageId, incoming.id);
      expect(queued.nextEligibleAt, now);
      expect(advertised.hopCount, 1);
    },
  );

  test('worse hop does not replace better same-version state', () async {
    final existing =
        message('same-version', senderCrc: 5151, updatedAt: now, hopCount: 1)
          ..relayCount = 7
          ..lastRelayedAt = now - 1000;
    await queue.storeAndQueueSos(message: existing, nextEligibleAt: now);

    final worse = message(
      'same-version',
      senderCrc: 5151,
      updatedAt: now,
      hopCount: 3,
    );

    expect(
      await queue.storeAndQueueSos(message: worse, nextEligibleAt: now),
      false,
    );
    final stored = SOSMessage.fromDbMap(
      (await db.query('sos_messages')).single,
    );
    expect(stored.hopCount, 1);
    expect(stored.relayCount, 7);
    expect(stored.lastRelayedAt, now - 1000);
  });

  test(
    'equal hop remains duplicate and does not reset relay metrics',
    () async {
      final existing =
          message('equal-hop', senderCrc: 5252, updatedAt: now, hopCount: 2)
            ..relayCount = 3
            ..lastRelayedAt = now - 2000;
      await queue.storeAndQueueSos(message: existing, nextEligibleAt: now);

      final equal = message(
        'equal-hop',
        senderCrc: 5252,
        updatedAt: now,
        hopCount: 2,
      );

      expect(
        await queue.storeAndQueueSos(message: equal, nextEligibleAt: now),
        false,
      );
      final stored = SOSMessage.fromDbMap(
        (await db.query('sos_messages')).single,
      );
      expect(stored.hopCount, 2);
      expect(stored.relayCount, 3);
      expect(stored.lastRelayedAt, now - 2000);
    },
  );

  test('newer timestamp wins despite worse hop', () async {
    final existing = message(
      'newer-wins',
      senderCrc: 5353,
      updatedAt: now,
      hopCount: 1,
    );
    await queue.storeAndQueueSos(message: existing, nextEligibleAt: now);

    final newer = message(
      'newer-wins',
      senderCrc: 5353,
      updatedAt: now + 1000,
      hopCount: 5,
    );

    expect(
      await queue.storeAndQueueSos(message: newer, nextEligibleAt: now),
      true,
    );
    final stored = SOSMessage.fromDbMap(
      (await db.query('sos_messages')).single,
    );
    expect(stored.updatedAt, now + 1000);
    expect(stored.hopCount, 5);
  });

  test('terminal higher-priority status wins despite worse hop', () async {
    final active = message(
      'terminal-wins',
      senderCrc: 5454,
      updatedAt: now,
      hopCount: 1,
    );
    await queue.storeAndQueueSos(message: active, nextEligibleAt: now);

    final resolved = message(
      'terminal-wins',
      senderCrc: 5454,
      updatedAt: now,
      status: SOSMessageStatus.resolved,
      hopCount: 5,
    );

    expect(
      await queue.storeAndQueueSos(message: resolved, nextEligibleAt: now),
      true,
    );
    final stored = SOSMessage.fromDbMap(
      (await db.query('sos_messages')).single,
    );
    expect(stored.status, SOSMessageStatus.resolved);
    expect(stored.hopCount, 5);
  });

  test('stale ACTIVE better hop cannot replace terminal state', () async {
    final resolved = message(
      'no-resurrect',
      senderCrc: 5555,
      updatedAt: now,
      status: SOSMessageStatus.resolved,
      hopCount: 5,
    );
    await queue.storeAndQueueSos(message: resolved, nextEligibleAt: now);

    final active = message(
      'no-resurrect',
      senderCrc: 5555,
      updatedAt: now,
      hopCount: 1,
    );

    expect(
      await queue.storeAndQueueSos(message: active, nextEligibleAt: now),
      false,
    );
    final stored = SOSMessage.fromDbMap(
      (await db.query('sos_messages')).single,
    );
    expect(stored.status, SOSMessageStatus.resolved);
    expect(stored.hopCount, 5);
  });

  test('ACK tombstone still suppresses better-hop ACTIVE', () async {
    await DatabaseHelper.upsertAckTombstoneInDb(
      db,
      senderCrc: 5656,
      ackTimestampMs: now,
      status: SOSMessageStatus.resolved,
    );

    expect(
      await DatabaseHelper.isSuppressedByAckTombstoneInDb(
        db,
        senderCrc: 5656,
        sosTimestampMs: now,
      ),
      true,
    );
  });

  test('hop 63 saturation and better-hop ordering remain coherent', () async {
    final saturated = message(
      'saturated',
      senderCrc: 5757,
      updatedAt: now,
      hopCount: MeshConfig.maxProtocolHop,
    );
    await queue.storeAndQueueSos(message: saturated, nextEligibleAt: now);

    final better = message(
      'saturated',
      senderCrc: 5757,
      updatedAt: now,
      hopCount: MeshConfig.maxProtocolHop - 1,
    );
    expect(
      await queue.storeAndQueueSos(message: better, nextEligibleAt: now),
      true,
    );
    var stored = SOSMessage.fromDbMap((await db.query('sos_messages')).single);
    expect(stored.hopCount, MeshConfig.maxProtocolHop - 1);

    final worse = message(
      'saturated',
      senderCrc: 5757,
      updatedAt: now,
      hopCount: MeshConfig.maxProtocolHop,
    );
    expect(
      await queue.storeAndQueueSos(message: worse, nextEligibleAt: now),
      false,
    );
    stored = SOSMessage.fromDbMap((await db.query('sos_messages')).single);
    expect(stored.hopCount, MeshConfig.maxProtocolHop - 1);
  });

  test(
    'better-hop state ordering is consistent in basic flooding mode',
    () async {
      final basicQueue = RelayQueueService(
        database: db,
        random: Random(1),
        mode: ForwardingMode.basicFlooding,
      );
      final existing = message(
        'basic-better-hop',
        senderCrc: 5858,
        updatedAt: now,
        hopCount: 4,
      );
      await basicQueue.storeAndQueueSos(message: existing, nextEligibleAt: now);

      final better = message(
        'basic-better-hop',
        senderCrc: 5858,
        updatedAt: now,
        hopCount: 2,
      );

      expect(
        await basicQueue.storeAndQueueSos(message: better, nextEligibleAt: now),
        true,
      );
      final stored = SOSMessage.fromDbMap(
        (await db.query('sos_messages')).single,
      );
      expect(stored.hopCount, 2);
    },
  );

  test('better-hop state ordering is consistent in trickle mode', () async {
    final trickleQueue = RelayQueueService(
      database: db,
      random: Random(1),
      mode: ForwardingMode.trickle,
    );
    final existing = message(
      'trickle-better-hop',
      senderCrc: 5959,
      updatedAt: now,
      hopCount: 4,
    );
    await trickleQueue.storeAndQueueSos(message: existing, nextEligibleAt: now);

    final better = message(
      'trickle-better-hop',
      senderCrc: 5959,
      updatedAt: now,
      hopCount: 2,
    );

    final result = await trickleQueue.storeAndQueueSosWithResult(
      message: better,
      nextEligibleAt: now,
    );
    expect(result.stored, true);
    expect(result.trickleResetPerformed, true);
    expect(result.trickleInconsistentHeard, false);
    expect(result.trickleReason, 'better_hop_event');
    final stored = SOSMessage.fromDbMap(
      (await db.query('sos_messages')).single,
    );
    expect(stored.hopCount, 2);
    final state = await trickleQueue.trickleStateFor(better.id);
    expect(state?.lastResetReason, 'better_hop_event');
  });

  test('upsertMessageInDb preserves better-hop preferred state', () async {
    final existing = message(
      'upsert-hop-3',
      senderCrc: 6060,
      updatedAt: now,
      hopCount: 3,
    );
    await DatabaseHelper.upsertMessageInDb(db, existing);

    final better = message(
      'upsert-hop-1',
      senderCrc: 6060,
      updatedAt: now,
      hopCount: 1,
    );
    final result = await DatabaseHelper.upsertMessageInDb(db, better);

    final rows = await db.query('sos_messages');
    final stored = SOSMessage.fromDbMap(rows.single);

    expect(result, 1);
    expect(stored.id, 'upsert-hop-1');
    expect(stored.hopCount, 1);
  });

  test('cleanupOldDuplicatesInDb keeps better-hop preferred state', () async {
    final worse = message(
      'cleanup-hop-3',
      senderCrc: 6161,
      updatedAt: now,
      hopCount: 3,
    );
    final better = message(
      'cleanup-hop-1',
      senderCrc: 6161,
      updatedAt: now,
      hopCount: 1,
    );
    await insertMessage(worse);
    await insertMessage(better);

    final deleted = await DatabaseHelper.cleanupOldDuplicatesInDb(db);
    final rows = await db.query('sos_messages');
    final stored = SOSMessage.fromDbMap(rows.single);

    expect(deleted, 1);
    expect(stored.id, 'cleanup-hop-1');
    expect(stored.hopCount, 1);
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
      expect(
        await queue.getItem(
          RelayQueueService.ackMessageId(
            senderCrc: 7001,
            ackTimestampMs: now + 123,
            statusIndex: SOSMessageStatus.resolved.index,
          ),
          'ack',
        ),
        isNotNull,
      );
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
      expect(
        await queue.getItem(
          RelayQueueService.ackMessageId(
            senderCrc: 7003,
            ackTimestampMs: now,
            statusIndex: SOSMessageStatus.resolved.index,
          ),
          'ack',
        ),
        isNotNull,
      );
    },
  );

  test('duplicate ACK does not reset relay metadata', () async {
    await queue.acceptAndQueueAck(
      senderCrc: 7004,
      ackTimestampMs: now,
      status: SOSMessageStatus.resolved,
      nowMs: now,
    );
    final ack7004 = RelayQueueService.ackMessageId(
      senderCrc: 7004,
      ackTimestampMs: now,
      statusIndex: SOSMessageStatus.resolved.index,
    );
    final item = (await queue.getItem(ack7004, 'ack'))!;
    await queue.markAdvertisingStarted(item, nowMs: now);
    await queue.markAdvertisingSucceeded(item, nowMs: now);
    final before = (await queue.getItem(ack7004, 'ack'))!;

    final duplicate = await queue.acceptAndQueueAck(
      senderCrc: 7004,
      ackTimestampMs: now,
      status: SOSMessageStatus.resolved,
      nowMs: now,
    );
    final after = (await queue.getItem(ack7004, 'ack'))!;

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
      final tombstones = await db.query(
        'ack_tombstones',
        where: 'ack_timestamp_ms = ?',
        whereArgs: [now],
      );
      final tombstone = tombstones.single;

      expect(inserted, AckApplyResult.inserted);
      expect(upgraded, AckApplyResult.replacedHigherStatus);
      expect(downgrade, AckApplyResult.rejectedOlder);
      expect(older, AckApplyResult.inserted);
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
      final item = (await queue.getItem(
        RelayQueueService.ackMessageId(
          senderCrc: 9001,
          ackTimestampMs: rawTimestamp,
          statusIndex: SOSMessageStatus.resolved.index,
        ),
        'ack',
      ))!;
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

  test('new SOS in the same protocol second is explicitly rejected', () async {
    final first = message('mono-first', senderCrc: 9002, updatedAt: now);
    await insertMessage(first);
    final second = message(
      'mono-second',
      senderCrc: 9002,
      updatedAt: now + 500,
    );
    final rejection = DatabaseHelper.ensureMonotonicStateTimestampInDb(
      db,
      second,
    );
    final packet = BlePacket(
      kind: BlePacketKind.sos,
      senderCrc: 9002,
      timestampMs: now + 500,
      latitude: -6.2,
      longitude: 106.8,
      status: SOSMessageStatus.active,
    );

    await expectLater(rejection, throwsStateError);
    expect(second.protocolTimestampMs, canonicalProtocolTimestamp(now + 500));
    expect(packet.timestampMs, now + 500);
  });

  test(
    'basic flooding and trickle share the SOS advertising burst duration',
    () {
      final basic = RelayQueueService(
        database: db,
        mode: ForwardingMode.basicFlooding,
      );
      final trickle = RelayQueueService(
        database: db,
        mode: ForwardingMode.trickle,
      );

      expect(basic.slotDurationForMode(), MeshConfig.sosAdvertiseBurstDuration);
      expect(
        trickle.slotDurationForMode(),
        MeshConfig.sosAdvertiseBurstDuration,
      );
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
