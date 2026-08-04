import 'package:pkmproject/models/sos_message.dart';

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

  factory GatewayAck.fromJson(Map<String, dynamic> json) {
    final senderCrc = _intFrom(json['sender_crc']);
    final ackTimestamp = _timestampFrom(json['ack_timestamp']);
    if (senderCrc == null || ackTimestamp == null) {
      throw const FormatException(
        'ACK must contain sender_crc and ack_timestamp',
      );
    }

    final status = _statusFrom(json['status']);
    if (status == SOSMessageStatus.active) {
      throw const FormatException('ACK status ACTIVE is invalid');
    }

    return GatewayAck(
      senderCrc: senderCrc,
      ackTimestampMs: ackTimestamp,
      status: status,
      senderDeviceId: json['sender_device_id']?.toString(),
      localMessageId: json['local_message_id']?.toString(),
    );
  }

  static SOSMessageStatus _statusFrom(dynamic value) {
    final raw = value?.toString().toUpperCase() ?? 'RESOLVED';
    return SOSMessageStatus.values.firstWhere(
      (status) => status.name.toUpperCase() == raw,
      orElse: () => SOSMessageStatus.resolved,
    );
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
