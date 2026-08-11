class ExperimentEvent {
  final int? id;
  final String sessionId;
  final String? trialId;
  final String eventType;
  final String? messageId;
  final int? senderCrc;
  final int timestampMs;
  final int? eventTimestampMs;
  final int? elapsedRealtimeMs;
  final String? nodeRole;
  final String? forwardingMode;
  final int? hopCount;
  final int? rssi;
  final String? payloadHash;
  final String? detailJson;

  const ExperimentEvent({
    this.id,
    required this.sessionId,
    this.trialId,
    required this.eventType,
    this.messageId,
    this.senderCrc,
    required this.timestampMs,
    this.eventTimestampMs,
    this.elapsedRealtimeMs,
    this.nodeRole,
    this.forwardingMode,
    this.hopCount,
    this.rssi,
    this.payloadHash,
    this.detailJson,
  });

  Map<String, dynamic> toDbMap() {
    return {
      if (id != null) 'id': id,
      'session_id': sessionId,
      'trial_id': trialId,
      'event_type': eventType,
      'message_id': messageId,
      'sender_crc': senderCrc,
      'timestamp_ms': timestampMs,
      'event_timestamp_ms': eventTimestampMs,
      'elapsed_realtime_ms': elapsedRealtimeMs,
      'node_role': nodeRole,
      'forwarding_mode': forwardingMode,
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
      trialId: map['trial_id'] as String?,
      eventType: map['event_type'] as String,
      messageId: map['message_id'] as String?,
      senderCrc: map['sender_crc'] as int?,
      timestampMs: map['timestamp_ms'] as int,
      eventTimestampMs: map['event_timestamp_ms'] as int?,
      elapsedRealtimeMs: map['elapsed_realtime_ms'] as int?,
      nodeRole: map['node_role'] as String?,
      forwardingMode: map['forwarding_mode'] as String?,
      hopCount: map['hop_count'] as int?,
      rssi: map['rssi'] as int?,
      payloadHash: map['payload_hash'] as String?,
      detailJson: map['detail_json'] as String?,
    );
  }
}
