import 'package:pkmproject/config/mesh_config.dart';
import 'package:pkmproject/models/sos_message.dart';
import 'package:pkmproject/utils/protocol_timestamp.dart';
import 'package:pkmproject/utils/sos_status_priority.dart';

class GatewayAck {
  final int senderCrc;
  final int ackTimestampMs;
  final SOSMessageStatus status;
  final String? senderDeviceId;
  final String? localMessageId;

  const GatewayAck({
    required this.senderCrc,
    required this.ackTimestampMs,
    required this.status,
    this.senderDeviceId,
    this.localMessageId,
  });

  factory GatewayAck.fromJson(Map<String, dynamic> json, {int? nowMs}) {
    final senderCrc = _intFrom(json['sender_crc']);
    final ackTimestamp = _timestampFrom(json['ack_timestamp']);
    if (senderCrc == null || ackTimestamp == null) {
      throw const FormatException(
        'ACK must contain sender_crc and ack_timestamp',
      );
    }
    final canonicalAckTimestamp = canonicalProtocolTimestamp(ackTimestamp);
    final effectiveNow = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    if (canonicalAckTimestamp >
        canonicalProtocolTimestamp(
          effectiveNow + MeshConfig.maxClockSkew.inMilliseconds,
        )) {
      throw const FormatException('ACK timestamp is too far in the future');
    }

    final status = _statusFrom(json['status']);
    if (!isValidAckStatus(status)) {
      throw const FormatException('ACK status must be CANCELLED or RESOLVED');
    }

    return GatewayAck(
      senderCrc: senderCrc,
      ackTimestampMs: canonicalAckTimestamp,
      status: status,
      senderDeviceId: json['sender_device_id']?.toString(),
      localMessageId: json['local_message_id']?.toString(),
    );
  }

  static SOSMessageStatus _statusFrom(dynamic value) {
    final raw = value?.toString().trim().toUpperCase();
    if (raw == null || raw.isEmpty) {
      throw const FormatException('ACK status is required');
    }
    for (final status in SOSMessageStatus.values) {
      if (status.name.toUpperCase() == raw) return status;
    }
    throw FormatException('Unknown ACK status: $raw');
  }

  static int? _intFrom(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '');
  }

  static int? _timestampFrom(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is num) return value.toInt();
    return DateTime.tryParse(value.toString())?.millisecondsSinceEpoch;
  }
}
