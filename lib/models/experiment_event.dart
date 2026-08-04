class ExperimentEvent {
  final int? id;
  final String sessionId;
  final String eventType;
  final String? messageId;
  final int? senderCrc;
  final int timestampMs;
  final int? hopCount;
  final int? rssi;
  final String? payloadHash;
  final String? detailJson;

  const ExperimentEvent({
    this.id,
    required this.sessionId,
    required this.eventType,
    this.messageId,
    this.senderCrc,
    required this.timestampMs,
    this.hopCount,
    this.rssi,
    this.payloadHash,
    this.detailJson,
  });

  Map<String, dynamic> toDbMap() {
    return {
      if (id != null) 'id': id,
      'session_id': sessionId,
      'event_type': eventType,
      'message_id': messageId,
      'sender_crc': senderCrc,
      'timestamp_ms': timestampMs,
      'hop_count': hopCount,
      'rssi': rssi,
      'payload_hash': payloadHash,
      'detail_json': detailJson,
    };
  }

  factory ExperimentEvent.fromDbMap(Map<String, dynamic> map) {
    return ExperimentEvent(
      id: map['id'] as int?,
      sessionId: map['session_id'] as String,
      eventType: map['event_type'] as String,
      messageId: map['message_id'] as String?,
      senderCrc: map['sender_crc'] as int?,
      timestampMs: map['timestamp_ms'] as int,
      hopCount: map['hop_count'] as int?,
      rssi: map['rssi'] as int?,
      payloadHash: map['payload_hash'] as String?,
      detailJson: map['detail_json'] as String?,
    );
  }
}
