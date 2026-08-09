import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pkmproject/config/mesh_config.dart';
import 'package:pkmproject/database_schema.dart';
import 'package:pkmproject/models/sos_message.dart';
import 'package:pkmproject/services/ble_relay_service.dart';
import 'package:pkmproject/services/ble_protocol.dart';
import 'package:pkmproject/services/database_helper.dart';
import 'package:pkmproject/utils/hash_utils.dart';
import 'package:pkmproject/utils/protocol_timestamp.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  final reference = DateTime.utc(2026, 6, 8, 12);

  test('packs and unpacks SOS payload in 17 bytes', () {
    final updatedAt = reference.millisecondsSinceEpoch;
    final message = SOSMessage(
      id: 'local-1',
      senderId: 'device-a',
      senderCrc: crc32('device-a'),
      content: 'SOS',
      latitude: -6.2,
      longitude: 106.8,
      status: SOSMessageStatus.active,
      createdAt: updatedAt,
      updatedAt: updatedAt,
    );

    final payload = BlePacket.packSos(message);
    expect(payload.length, BlePacket.length);

    final packet = BlePacket.unpack(payload, referenceTime: reference);
    expect(packet, isNotNull);
    expect(packet!.kind, BlePacketKind.sos);
    expect(packet.senderCrc, crc32('device-a'));
    expect(packet.status, SOSMessageStatus.active);
    expect(packet.latitude!, closeTo(-6.2, 0.0002));
    expect(packet.longitude!, closeTo(106.8, 0.0002));
    expect(packet.timestampMs, updatedAt);
  });

  test('packs relayed SOS with existing sender CRC', () {
    final updatedAt = reference.millisecondsSinceEpoch;
    final message = SOSMessage(
      id: 'relay-1',
      senderId: 'ble-device-12345',
      senderCrc: 12345,
      content: 'SOS',
      latitude: -6.2,
      longitude: 106.8,
      status: SOSMessageStatus.active,
      createdAt: updatedAt,
      updatedAt: updatedAt,
    );

    final payload = BlePacket.packSos(message);
    final packet = BlePacket.unpack(payload, referenceTime: reference);

    expect(packet, isNotNull);
    expect(packet!.senderCrc, 12345);
  });

  test('origin SOS advertises hop 0 and first relay advertises hop 1', () {
    final updatedAt = reference.millisecondsSinceEpoch;
    final origin = SOSMessage(
      id: 'origin-1',
      senderId: 'device-a',
      senderCrc: crc32('device-a'),
      content: 'SOS',
      latitude: -6.2,
      longitude: 106.8,
      status: SOSMessageStatus.active,
      createdAt: updatedAt,
      updatedAt: updatedAt,
    );

    final originPayload = BlePacket.packSos(origin);
    final incoming = BlePacket.unpack(originPayload, referenceTime: reference);

    expect(incoming, isNotNull);
    expect(incoming!.hopCount, 0);

    final relayed = BleRelayService.messageFromSosPacket(
      incoming,
      updatedAt + const Duration(seconds: 1).inMilliseconds,
    );
    final relayPayload = BlePacket.packSos(relayed);
    final relayPacket = BlePacket.unpack(
      relayPayload,
      referenceTime: reference,
    );

    expect(relayed.hopCount, 1);
    expect(relayPacket, isNotNull);
    expect(relayPacket!.hopCount, 1);
  });

  test('SOS at hop 4 is relayed as hop 5', () {
    final updatedAt = reference.millisecondsSinceEpoch;
    final message = SOSMessage(
      id: 'relay-4',
      senderId: 'device-a',
      senderCrc: crc32('device-a'),
      content: 'SOS',
      latitude: -6.2,
      longitude: 106.8,
      status: SOSMessageStatus.active,
      createdAt: updatedAt,
      updatedAt: updatedAt,
      hopCount: MeshConfig.legacyHopMetadata - 1,
    );
    final packet = BlePacket.unpack(
      BlePacket.packSos(message),
      referenceTime: reference,
    );

    final relayed = BleRelayService.messageFromSosPacket(
      packet!,
      updatedAt + const Duration(seconds: 1).inMilliseconds,
    );

    expect(
      BleRelayService.canRelaySosPacket(packet, relayed.firstSeenAt),
      true,
    );
    expect(relayed.hopCount, MeshConfig.legacyHopMetadata);
  });

  test('SOS at hop 63 is relayed with saturated hop 63', () {
    final updatedAt = reference.millisecondsSinceEpoch;
    final message = SOSMessage(
      id: 'relay-63',
      senderId: 'device-a',
      senderCrc: crc32('device-a'),
      content: 'SOS',
      latitude: -6.2,
      longitude: 106.8,
      status: SOSMessageStatus.active,
      createdAt: updatedAt,
      updatedAt: updatedAt,
      hopCount: MeshConfig.maxProtocolHop,
    );
    final packet = BlePacket.unpack(
      BlePacket.packSos(message),
      referenceTime: reference,
    );
    final receivedAt = updatedAt + const Duration(seconds: 1).inMilliseconds;

    final stored = BleRelayService.messageFromSosPacket(packet!, receivedAt);

    expect(stored.hopCount, MeshConfig.maxProtocolHop);
    expect(BleRelayService.canRelaySosPacket(packet, receivedAt), true);
  });

  test('old SOS remains relayable while not ACKed', () {
    final updatedAt = reference.millisecondsSinceEpoch;
    final message = SOSMessage(
      id: 'expired-1',
      senderId: 'device-a',
      senderCrc: crc32('device-a'),
      content: 'SOS',
      latitude: -6.2,
      longitude: 106.8,
      status: SOSMessageStatus.active,
      createdAt: updatedAt,
      updatedAt: updatedAt,
    );
    final packet = BlePacket.unpack(
      BlePacket.packSos(message),
      referenceTime: reference,
    );
    final receivedAt =
        updatedAt + MeshConfig.defaultMessageLifetime.inMilliseconds;

    final stored = BleRelayService.messageFromSosPacket(packet!, receivedAt);

    expect(stored.localState, 'pending');
    expect(stored.isExpiredAt(receivedAt), false);
    expect(BleRelayService.canRelaySosPacket(packet, receivedAt), true);
  });

  test('database map preserves hop and expiry metadata after reload', () {
    final updatedAt = DateTime.now().millisecondsSinceEpoch;
    final expiresAt =
        updatedAt + MeshConfig.defaultMessageLifetime.inMilliseconds;
    final message = SOSMessage(
      id: 'persisted-hop',
      senderId: 'device-a',
      senderCrc: crc32('device-a'),
      content: 'SOS',
      latitude: -6.2,
      longitude: 106.8,
      status: SOSMessageStatus.active,
      createdAt: updatedAt,
      updatedAt: updatedAt,
      hopCount: 3,
      maxHop: MeshConfig.legacyHopMetadata,
      expiresAt: expiresAt,
      firstSeenAt: updatedAt + 500,
      relayCount: 2,
      localState: 'relayed',
    );

    final reloaded = SOSMessage.fromDbMap(message.toDbMap());

    expect(reloaded.hopCount, 3);
    expect(reloaded.maxHop, MeshConfig.legacyHopMetadata);
    expect(reloaded.expiresAt, expiresAt);
    expect(reloaded.firstSeenAt, updatedAt + 500);
    expect(reloaded.relayCount, 2);
    expect(reloaded.localState, 'relayed');
  });

  test('packs and unpacks ACK payload in 17 bytes', () {
    final ackTimestamp = reference.millisecondsSinceEpoch;
    final payload = BlePacket.packAck(
      senderCrc: 12345,
      ackTimestampMs: ackTimestamp,
      status: SOSMessageStatus.resolved,
    );

    expect(payload.length, BlePacket.length);

    final packet = BlePacket.unpack(payload, referenceTime: reference);
    expect(packet, isNotNull);
    expect(packet!.kind, BlePacketKind.ack);
    expect(packet.senderCrc, 12345);
    expect(packet.timestampMs, ackTimestamp);
    expect(packet.status, SOSMessageStatus.resolved);
    expect(packet.hopCount, 0);
  });

  test('BLE payload timestamps are canonical to protocol seconds', () {
    final rawTimestamp = reference.millisecondsSinceEpoch + 789;
    final payload = BlePacket.packAck(
      senderCrc: 12345,
      ackTimestampMs: rawTimestamp,
      status: SOSMessageStatus.resolved,
    );

    final packet = BlePacket.unpack(
      payload,
      referenceTime: DateTime.fromMillisecondsSinceEpoch(rawTimestamp),
    );

    expect(packet, isNotNull);
    expect(packet!.timestampMs, canonicalProtocolTimestamp(rawTimestamp));
    expect(
      packet.identity,
      'ACK:12345:${canonicalProtocolTimestamp(rawTimestamp)}:2',
    );
  });

  test('rejects ACK with ACTIVE status', () {
    final payload = BlePacket.packAck(
      senderCrc: 12345,
      ackTimestampMs: reference.millisecondsSinceEpoch,
      status: SOSMessageStatus.active,
    );

    expect(BlePacket.unpack(payload, referenceTime: reference), isNull);
  });

  test('ACK relay increments hop and continues beyond legacy max ACK hop', () {
    final ackTimestamp = reference.millisecondsSinceEpoch;
    final originPayload = BlePacket.packAck(
      senderCrc: 12345,
      ackTimestampMs: ackTimestamp,
      status: SOSMessageStatus.resolved,
    );
    final originPacket = BlePacket.unpack(
      originPayload,
      referenceTime: reference,
    );

    expect(originPacket, isNotNull);
    expect(originPacket!.hopCount, 0);
    expect(BleRelayService.canRelayAckPacket(originPacket, ackTimestamp), true);

    final relayPayload = BlePacket.packAck(
      senderCrc: originPacket.senderCrc,
      ackTimestampMs: originPacket.timestampMs,
      status: originPacket.status,
      hopCount: originPacket.hopCount + 1,
    );
    final relayPacket = BlePacket.unpack(
      relayPayload,
      referenceTime: reference,
    );

    expect(relayPacket, isNotNull);
    expect(relayPacket!.hopCount, 1);

    final maxHopPayload = BlePacket.packAck(
      senderCrc: 12345,
      ackTimestampMs: ackTimestamp,
      hopCount: MeshConfig.legacyAckHopMetadata + 1,
    );
    final maxHopPacket = BlePacket.unpack(
      maxHopPayload,
      referenceTime: reference,
    );
    expect(maxHopPacket, isNotNull);
    expect(
      BleRelayService.canRelayAckPacket(maxHopPacket!, ackTimestamp),
      true,
    );
  });

  test('old ACK remains relayable as persistent anti-message', () {
    final ackTimestamp = reference.millisecondsSinceEpoch;
    final payload = BlePacket.packAck(
      senderCrc: 12345,
      ackTimestampMs: ackTimestamp,
    );
    final packet = BlePacket.unpack(payload, referenceTime: reference);
    final expiredAt = ackTimestamp + MeshConfig.ackLifetime.inMilliseconds;

    expect(packet, isNotNull);
    expect(BleRelayService.isAckPacketExpired(packet!, expiredAt), false);
    expect(BleRelayService.canRelayAckPacket(packet, expiredAt), true);
  });

  test('rejects invalid header', () {
    final payload = Uint8List(BlePacket.length);
    payload[0] = 0x00;
    payload[1] = 0x00;

    expect(BlePacket.unpack(payload), isNull);
  });

  test('rejects payload with invalid length', () {
    expect(BlePacket.unpack(Uint8List(BlePacket.length + 1)), isNull);
    expect(BlePacket.unpack(Uint8List(BlePacket.length - 1)), isNull);
  });

  test('rejects invalid coordinates and future timestamps', () {
    final updatedAt = reference.millisecondsSinceEpoch;
    final invalidLatitude = SOSMessage(
      id: 'invalid-lat',
      senderId: 'device-a',
      senderCrc: crc32('device-a'),
      content: 'SOS',
      latitude: 91,
      longitude: 106.8,
      status: SOSMessageStatus.active,
      createdAt: updatedAt,
      updatedAt: updatedAt,
    );
    final invalidHop = SOSMessage(
      id: 'invalid-hop',
      senderId: 'device-a',
      senderCrc: crc32('device-a'),
      content: 'SOS',
      latitude: -6.2,
      longitude: 106.8,
      status: SOSMessageStatus.active,
      createdAt: updatedAt,
      updatedAt: updatedAt,
      hopCount: MeshConfig.maxProtocolHop + 1,
    );
    final futureMessage = SOSMessage(
      id: 'future',
      senderId: 'device-a',
      senderCrc: crc32('device-a'),
      content: 'SOS',
      latitude: -6.2,
      longitude: 106.8,
      status: SOSMessageStatus.active,
      createdAt: updatedAt + MeshConfig.maxClockSkew.inMilliseconds + 1000,
      updatedAt: updatedAt + MeshConfig.maxClockSkew.inMilliseconds + 1000,
    );

    expect(() => BlePacket.packSos(invalidLatitude), throwsArgumentError);
    final saturatedHop = BlePacket.unpack(
      BlePacket.packSos(invalidHop),
      referenceTime: reference,
    );
    expect(saturatedHop, isNotNull);
    expect(saturatedHop!.hopCount, MeshConfig.maxProtocolHop);
    expect(
      BlePacket.unpack(
        BlePacket.packSos(futureMessage),
        referenceTime: reference,
      ),
      isNull,
    );
  });

  test('ACK timestamp rule keeps newer local messages alive', () {
    final localUpdatedAt = reference.add(const Duration(seconds: 10));
    final oldAck = reference;
    final newAck = reference.add(const Duration(seconds: 15));

    expect(
      localUpdatedAt.millisecondsSinceEpoch <= oldAck.millisecondsSinceEpoch,
      isFalse,
    );
    expect(
      localUpdatedAt.millisecondsSinceEpoch <= newAck.millisecondsSinceEpoch,
      isTrue,
    );
  });

  test('database migration keeps old SOS rows and creates relay queue', () async {
    sqfliteFfiInit();
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    addTearDown(db.close);

    await db.execute('''
CREATE TABLE sos_messages (
  id TEXT PRIMARY KEY,
  sender_id TEXT,
  sender_name TEXT NULL,
  content TEXT,
  latitude REAL,
  longitude REAL,
  status INTEGER,
  created_at INTEGER,
  updated_at INTEGER,
  is_synced INTEGER DEFAULT 0,
  sender_crc INTEGER NULL,
  from_server INTEGER DEFAULT 0
);
''');
    final createdAt = reference.millisecondsSinceEpoch;
    await db.insert('sos_messages', {
      'id': 'legacy-1',
      'sender_id': 'legacy-device',
      'sender_name': 'Legacy Node',
      'content': 'SOS',
      'latitude': -6.2,
      'longitude': 106.8,
      'status': SOSMessageStatus.active.index,
      'created_at': createdAt,
      'updated_at': createdAt,
      'is_synced': 0,
      'sender_crc': 12345,
      'from_server': 0,
    });

    await DatabaseHelper.migrateDatabase(db, 2, DatabaseHelper.databaseVersion);

    final rows = await db.query('sos_messages');
    expect(rows, hasLength(1));
    expect(rows.single['id'], 'legacy-1');
    expect(rows.single['hop_count'], 0);
    expect(rows.single['max_hop'], MeshConfig.legacyHopMetadata);
    expect(
      rows.single['expires_at'],
      createdAt + MeshConfig.defaultMessageLifetime.inMilliseconds,
    );
    expect(rows.single['first_seen_at'], createdAt);
    expect(rows.single['local_state'], 'pending');

    final columns = await db.rawQuery('PRAGMA table_info(sos_messages)');
    final columnNames = columns.map((column) => column['name']).toSet();
    for (final columnName in sosMessagesColumnDefinitions.keys) {
      expect(columnNames, contains(columnName));
    }

    final relayQueue = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name='relay_queue'",
    );
    expect(relayQueue, hasLength(1));

    final ackTombstones = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name='ack_tombstones'",
    );
    expect(ackTombstones, hasLength(1));

    final experimentTables = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' "
      "AND name IN ('experiment_sessions', 'experiment_events')",
    );
    expect(experimentTables, hasLength(2));
  });
}
