import 'dart:typed_data';

import 'package:pkmproject/models/sos_message.dart';
import 'package:pkmproject/utils/hash_utils.dart';

enum BlePacketKind { sos, ack }

class BlePacket {
  static const int length = 17;
  static const int ackFlag = 0x80;
  static const int fromServerFlag = 0x40;
  static const int hopMask = 0x3F;
  static const int timestampModulo = 1 << 24;

  final BlePacketKind kind;
  final int senderCrc;
  final int timestampMs;
  final double? latitude;
  final double? longitude;
  final SOSMessageStatus status;
  final bool fromServer;
  final int hopCount;

  const BlePacket({
    required this.kind,
    required this.senderCrc,
    required this.timestampMs,
    this.latitude,
    this.longitude,
    required this.status,
    this.fromServer = false,
    this.hopCount = 0,
  });

  bool get isAck => kind == BlePacketKind.ack;

  static Uint8List packSos(SOSMessage message, {int hopCount = 0}) {
    final buffer = ByteData(length);
    _writeHeader(buffer);
    final senderCrc = message.senderCrc ?? crc32(message.senderId);
    buffer.setUint32(2, senderCrc & 0xFFFFFFFF, Endian.big);
    _writeTimestamp(buffer, message.updatedAt);
    _writeCoordinate(buffer, 9, message.latitude, -90.0, 10000.0);
    _writeCoordinate(buffer, 12, message.longitude, -180.0, 10000.0);
    buffer.setUint8(15, message.status.index);
    buffer.setUint8(
      16,
      (message.fromServer ? fromServerFlag : 0x00) | (hopCount & hopMask),
    );
    return buffer.buffer.asUint8List();
  }

  static Uint8List packAck({
    required int senderCrc,
    required int ackTimestampMs,
    SOSMessageStatus status = SOSMessageStatus.resolved,
    bool fromServer = true,
    int hopCount = 0,
  }) {
    final buffer = ByteData(length);
    _writeHeader(buffer);
    buffer.setUint32(2, senderCrc & 0xFFFFFFFF, Endian.big);
    _writeTimestamp(buffer, ackTimestampMs);
    for (var i = 9; i <= 14; i++) {
      buffer.setUint8(i, 0);
    }
    buffer.setUint8(15, status.index);
    buffer.setUint8(
      16,
      ackFlag |
          (fromServer ? fromServerFlag : 0x00) |
          ((hopCount + 1) & hopMask),
    );
    return buffer.buffer.asUint8List();
  }

  static BlePacket? unpack(Uint8List payload, {DateTime? referenceTime}) {
    if (payload.length < length) return null;

    final buffer = ByteData.view(payload.buffer, payload.offsetInBytes, length);
    if (buffer.getUint8(0) != 0x52 || buffer.getUint8(1) != 0x4D) {
      return null;
    }

    final senderCrc = buffer.getUint32(2, Endian.big);
    final timestampMs = _readTimestamp(buffer, referenceTime: referenceTime);
    final statusIndex = buffer.getUint8(15);
    if (statusIndex >= SOSMessageStatus.values.length) return null;

    final flags = buffer.getUint8(16);
    final isAck = (flags & ackFlag) != 0;
    final fromServer = (flags & fromServerFlag) != 0;
    final hopCount = flags & hopMask;

    if (isAck) {
      return BlePacket(
        kind: BlePacketKind.ack,
        senderCrc: senderCrc,
        timestampMs: timestampMs,
        status: SOSMessageStatus.values[statusIndex],
        fromServer: fromServer,
        hopCount: hopCount,
      );
    }

    final latitude = _readCoordinate(buffer, 9, -90.0, 10000.0);
    final longitude = _readCoordinate(buffer, 12, -180.0, 10000.0);
    return BlePacket(
      kind: BlePacketKind.sos,
      senderCrc: senderCrc,
      timestampMs: timestampMs,
      latitude: latitude,
      longitude: longitude,
      status: SOSMessageStatus.values[statusIndex],
      fromServer: fromServer,
      hopCount: hopCount,
    );
  }

  static void _writeHeader(ByteData buffer) {
    buffer.setUint8(0, 0x52);
    buffer.setUint8(1, 0x4D);
  }

  static void _writeTimestamp(ByteData buffer, int timestampMs) {
    final secondsSinceBase = (timestampMs ~/ 1000) - SOSMessage.kBaseTimestamp;
    final compact = secondsSinceBase % timestampModulo;
    buffer.setUint8(6, (compact >> 16) & 0xFF);
    buffer.setUint8(7, (compact >> 8) & 0xFF);
    buffer.setUint8(8, compact & 0xFF);
  }

  static int _readTimestamp(ByteData buffer, {DateTime? referenceTime}) {
    final compact =
        (buffer.getUint8(6) << 16) |
        (buffer.getUint8(7) << 8) |
        buffer.getUint8(8);

    final referenceSeconds =
        ((referenceTime ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000) -
        SOSMessage.kBaseTimestamp;
    final baseWindow =
        (referenceSeconds / timestampModulo).round() * timestampModulo;

    var best = baseWindow + compact;
    for (final candidate in <int>[
      baseWindow - timestampModulo + compact,
      baseWindow + compact,
      baseWindow + timestampModulo + compact,
    ]) {
      if ((candidate - referenceSeconds).abs() <
          (best - referenceSeconds).abs()) {
        best = candidate;
      }
    }

    return (SOSMessage.kBaseTimestamp + best) * 1000;
  }

  static void _writeCoordinate(
    ByteData buffer,
    int offset,
    double value,
    double base,
    double scale,
  ) {
    final encoded = ((value - base) * scale).round().clamp(0, 0xFFFFFF);
    buffer.setUint8(offset, (encoded >> 16) & 0xFF);
    buffer.setUint8(offset + 1, (encoded >> 8) & 0xFF);
    buffer.setUint8(offset + 2, encoded & 0xFF);
  }

  static double _readCoordinate(
    ByteData buffer,
    int offset,
    double base,
    double scale,
  ) {
    final encoded =
        (buffer.getUint8(offset) << 16) |
        (buffer.getUint8(offset + 1) << 8) |
        buffer.getUint8(offset + 2);
    return (encoded / scale) + base;
  }
}
