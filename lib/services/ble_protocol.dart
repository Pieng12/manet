import 'dart:typed_data';

import 'package:pkmproject/config/mesh_config.dart';
import 'package:pkmproject/models/sos_message.dart';
import 'package:pkmproject/models/message_identity.dart';
import 'package:pkmproject/utils/hash_utils.dart';
import 'package:pkmproject/utils/protocol_timestamp.dart';

enum BlePacketKind { sos, ack }

class BlePacket {
  static const int length = MeshConfig.protocolLength;
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

  String get identity => packetIdentity(this);

  MessageKey get messageKey =>
      MessageKey(senderCrc: senderCrc, protocolTimestampMs: timestampMs);

  StateIdentity get stateIdentity => StateIdentity(
    messageKey: messageKey,
    statusIndex: status.index,
    isAck: isAck,
    fromServer: fromServer,
  );

  static String packetIdentity(BlePacket packet) {
    final type = packet.isAck ? 'ACK' : 'SOS';
    return '$type:${packet.senderCrc}:${canonicalProtocolTimestamp(packet.timestampMs)}:${packet.status.index}';
  }

  static Uint8List packSos(SOSMessage message, {int? hopCount}) {
    final effectiveHopCount = _saturateHop(hopCount ?? message.hopCount);
    _validateCoordinateRange(message.latitude, -90.0, 90.0, 'latitude');
    _validateCoordinateRange(message.longitude, -180.0, 180.0, 'longitude');
    final buffer = ByteData(length);
    _writeHeader(buffer);
    final senderCrc = message.senderCrc ?? crc32(message.senderId);
    buffer.setUint32(2, senderCrc & 0xFFFFFFFF, Endian.big);
    _writeTimestamp(buffer, message.protocolTimestampMs);
    _writeSignedCoordinate(buffer, 9, message.latitude, 10000.0);
    _writeSignedCoordinate(buffer, 12, message.longitude, 10000.0);
    buffer.setUint8(15, message.status.index);
    buffer.setUint8(
      16,
      (message.fromServer ? fromServerFlag : 0x00) |
          (effectiveHopCount & hopMask),
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
    final effectiveHopCount = _saturateHop(hopCount);
    final buffer = ByteData(length);
    _writeHeader(buffer);
    buffer.setUint32(2, senderCrc & 0xFFFFFFFF, Endian.big);
    _writeTimestamp(buffer, canonicalProtocolTimestamp(ackTimestampMs));
    for (var i = 9; i <= 14; i++) {
      buffer.setUint8(i, 0);
    }
    buffer.setUint8(15, status.index);
    buffer.setUint8(
      16,
      ackFlag |
          (fromServer ? fromServerFlag : 0x00) |
          (effectiveHopCount & hopMask),
    );
    return buffer.buffer.asUint8List();
  }

  static BlePacket? unpack(Uint8List payload, {DateTime? referenceTime}) {
    if (payload.length != length) return null;

    final buffer = ByteData.view(payload.buffer, payload.offsetInBytes, length);
    if (buffer.getUint8(0) != 0x52 || buffer.getUint8(1) != 0x4D) {
      return null;
    }

    final senderCrc = buffer.getUint32(2, Endian.big);
    final effectiveReferenceTime = referenceTime ?? DateTime.now();
    final timestampMs = _readTimestamp(
      buffer,
      referenceTime: effectiveReferenceTime,
    );
    if (!_isTimestampPlausible(timestampMs, effectiveReferenceTime)) {
      return null;
    }
    final statusIndex = buffer.getUint8(15);
    if (statusIndex >= SOSMessageStatus.values.length) return null;

    final flags = buffer.getUint8(16);
    final isAck = (flags & ackFlag) != 0;
    final fromServer = (flags & fromServerFlag) != 0;
    final hopCount = flags & hopMask;

    if (isAck) {
      if (SOSMessageStatus.values[statusIndex] == SOSMessageStatus.active) {
        return null;
      }
      return BlePacket(
        kind: BlePacketKind.ack,
        senderCrc: senderCrc,
        timestampMs: timestampMs,
        status: SOSMessageStatus.values[statusIndex],
        fromServer: fromServer,
        hopCount: hopCount,
      );
    }

    final latitude = _readSignedCoordinate(buffer, 9, 10000.0);
    final longitude = _readSignedCoordinate(buffer, 12, 10000.0);
    if (!_isCoordinateInRange(latitude, -90.0, 90.0) ||
        !_isCoordinateInRange(longitude, -180.0, 180.0)) {
      return null;
    }
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

  static int _saturateHop(int hopCount) {
    if (hopCount < 0) return 0;
    if (hopCount > MeshConfig.maxProtocolHop) {
      return MeshConfig.maxProtocolHop;
    }
    return hopCount;
  }

  static void _validateCoordinateRange(
    double value,
    double min,
    double max,
    String name,
  ) {
    if (!_isCoordinateInRange(value, min, max)) {
      throw ArgumentError.value(value, name, 'must be between $min and $max');
    }
  }

  static bool _isCoordinateInRange(double value, double min, double max) {
    return value.isFinite && value >= min && value <= max;
  }

  static bool _isTimestampPlausible(int timestampMs, DateTime referenceTime) {
    final maxFutureMs =
        referenceTime.millisecondsSinceEpoch +
        MeshConfig.maxClockSkew.inMilliseconds;
    return timestampMs <= maxFutureMs;
  }

  static void _writeTimestamp(ByteData buffer, int timestampMs) {
    final secondsSinceBase =
        (canonicalProtocolTimestamp(timestampMs) ~/ 1000) -
        MeshConfig.protocolEpochSeconds;
    if (secondsSinceBase < 0 || secondsSinceBase >= timestampModulo) {
      throw ArgumentError.value(
        timestampMs,
        'timestampMs',
        'outside configured 24-bit protocol epoch',
      );
    }
    final compact = secondsSinceBase;
    buffer.setUint8(6, (compact >> 16) & 0xFF);
    buffer.setUint8(7, (compact >> 8) & 0xFF);
    buffer.setUint8(8, compact & 0xFF);
  }

  static int _readTimestamp(ByteData buffer, {DateTime? referenceTime}) {
    final compact =
        (buffer.getUint8(6) << 16) |
        (buffer.getUint8(7) << 8) |
        buffer.getUint8(8);

    return (MeshConfig.protocolEpochSeconds + compact) * 1000;
  }

  static void _writeSignedCoordinate(
    ByteData buffer,
    int offset,
    double value,
    double scale,
  ) {
    final signed = (value * scale).round();
    if (signed < -0x800000 || signed > 0x7FFFFF) {
      throw ArgumentError.value(value, 'coordinate', 'outside signed 24-bit');
    }
    final encoded = signed & 0xFFFFFF;
    buffer.setUint8(offset, (encoded >> 16) & 0xFF);
    buffer.setUint8(offset + 1, (encoded >> 8) & 0xFF);
    buffer.setUint8(offset + 2, encoded & 0xFF);
  }

  static double _readSignedCoordinate(
    ByteData buffer,
    int offset,
    double scale,
  ) {
    final encoded =
        (buffer.getUint8(offset) << 16) |
        (buffer.getUint8(offset + 1) << 8) |
        buffer.getUint8(offset + 2);
    final signed = (encoded & 0x800000) == 0 ? encoded : encoded - 0x1000000;
    return signed / scale;
  }
}
