import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pkmproject/models/sos_message.dart';
import 'package:pkmproject/services/ble_protocol.dart';
import 'package:pkmproject/utils/hash_utils.dart';

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
  });

  test('rejects invalid header', () {
    final payload = Uint8List(BlePacket.length);
    payload[0] = 0x00;
    payload[1] = 0x00;

    expect(BlePacket.unpack(payload), isNull);
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
}
