import 'dart:typed_data';

import 'package:pkmproject/models/message_identity.dart';
import 'package:pkmproject/services/ble_protocol.dart';
import 'package:pkmproject/config/mesh_config.dart';

enum NeighborFrameType { data, status }

/// RN v1; all multi-byte integers are big endian. RM remains the inner codec.
class NeighborFrame {
  const NeighborFrame({
    required this.type,
    required this.transmitter,
    required this.boot,
    required this.sequence,
    required this.scope,
    this.inner,
    this.inventory = const [],
    this.complete = true,
  });

  static const headerLength = 22;
  static const capacity = 8;
  static const maxLength = headerLength + capacity * 8;
  final NeighborFrameType type;
  final int transmitter;
  final int boot;
  final int sequence;
  final int scope;
  final Uint8List? inner;
  final List<StateIdentity> inventory;
  final bool complete;

  String get burstIdentity => '$scope:$transmitter:$boot:$sequence';
  String observationIdentity(String receiver) => '$receiver|$burstIdentity';

  Uint8List encode() {
    if ([
      transmitter,
      boot,
      sequence,
      scope,
    ].any((v) => v <= 0 || v > 0xffffffff)) {
      throw ArgumentError('Transport IDs must be nonzero uint32');
    }
    if (type == NeighborFrameType.data &&
        (inner?.length != 17 ||
            inventory.isNotEmpty ||
            !complete ||
            BlePacket.unpack(inner!) == null)) {
      throw ArgumentError('DATA requires the unchanged 17-byte inner payload');
    }
    if (inventory.length > capacity) throw ArgumentError('Inventory overflow');
    final bytes = Uint8List(
      headerLength +
          (type == NeighborFrameType.data ? 17 : inventory.length * 8),
    );
    final b = ByteData.sublistView(bytes);
    bytes.setRange(0, 4, [0x52, 0x4e, 1, type.index]);
    for (final pair in [
      (4, transmitter),
      (8, boot),
      (12, sequence),
      (16, scope),
    ]) {
      b.setUint32(pair.$1, pair.$2, Endian.big);
    }
    bytes[20] = inventory.length;
    bytes[21] = complete ? 1 : 0;
    if (type == NeighborFrameType.data) {
      bytes.setRange(headerLength, bytes.length, inner!);
    } else {
      for (var i = 0; i < inventory.length; i++) {
        final state = inventory[i];
        final seconds =
            state.messageKey.protocolTimestampMs ~/ 1000 -
            MeshConfig.protocolEpochSeconds;
        if (seconds < 0 ||
            seconds >= 1 << 24 ||
            state.statusIndex < 0 ||
            state.statusIndex > 2 ||
            (state.isAck && state.statusIndex == 1)) {
          throw ArgumentError('Invalid inventory state');
        }
        final offset = headerLength + i * 8;
        b.setUint32(offset, state.messageKey.senderCrc, Endian.big);
        bytes[offset + 4] = seconds >> 16;
        bytes[offset + 5] = (seconds >> 8) & 255;
        bytes[offset + 6] = seconds & 255;
        bytes[offset + 7] =
            state.statusIndex |
            (state.isAck ? 0x80 : 0) |
            (state.fromServer ? 0x40 : 0);
      }
    }
    return bytes;
  }

  static NeighborFrame? decode(Uint8List bytes, {DateTime? referenceTime}) {
    if (bytes.length < headerLength ||
        bytes[0] != 0x52 ||
        bytes[1] != 0x4e ||
        bytes[2] != 1 ||
        bytes[3] > 1 ||
        bytes[20] > capacity ||
        bytes[21] > 1) {
      return null;
    }
    final b = ByteData.sublistView(bytes);
    final ids = [
      for (final offset in [4, 8, 12, 16]) b.getUint32(offset, Endian.big),
    ];
    if (ids.any((v) => v == 0)) return null;
    final type = NeighborFrameType.values[bytes[3]];
    if (bytes.length !=
        headerLength + (type == NeighborFrameType.data ? 17 : bytes[20] * 8)) {
      return null;
    }
    Uint8List? inner;
    final states = <StateIdentity>[];
    if (type == NeighborFrameType.data) {
      if (bytes[20] != 0 || bytes[21] != 1) return null;
      inner = Uint8List.sublistView(bytes, headerLength);
      if (BlePacket.unpack(inner, referenceTime: referenceTime) == null) {
        return null;
      }
    } else {
      for (var i = 0; i < bytes[20]; i++) {
        final o = headerLength + i * 8;
        final flags = bytes[o + 7];
        if ((flags & 0x3f) > 2 ||
            ((flags & 0x80) != 0 && (flags & 0x3f) == 1)) {
          return null;
        }
        final compact = bytes[o + 4] << 16 | bytes[o + 5] << 8 | bytes[o + 6];
        if ((MeshConfig.protocolEpochSeconds + compact) * 1000 >
            (referenceTime ?? DateTime.now()).millisecondsSinceEpoch +
                MeshConfig.maxClockSkew.inMilliseconds) {
          return null;
        }
        states.add(
          StateIdentity(
            messageKey: MessageKey(
              senderCrc: b.getUint32(o, Endian.big),
              protocolTimestampMs:
                  (MeshConfig.protocolEpochSeconds + compact) * 1000,
            ),
            statusIndex: flags & 0x3f,
            isAck: flags & 0x80 != 0,
            fromServer: flags & 0x40 != 0,
          ),
        );
      }
    }
    return NeighborFrame(
      type: type,
      transmitter: ids[0],
      boot: ids[1],
      sequence: ids[2],
      scope: ids[3],
      inner: inner,
      inventory: states,
      complete: bytes[21] == 1,
    );
  }
}
