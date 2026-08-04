class RelayQueueItem {
  final int? id;
  final String messageId;
  final String packetType;
  final int priority;
  final int nextEligibleAt;
  final int relayCount;
  final int lastRelayedAt;
  final String queueState;
  final String? payloadBase64;

  const RelayQueueItem({
    this.id,
    required this.messageId,
    required this.packetType,
    this.priority = 0,
    this.nextEligibleAt = 0,
    this.relayCount = 0,
    this.lastRelayedAt = 0,
    this.queueState = 'queued',
    this.payloadBase64,
  });

  bool get isAck => packetType == 'ack';
  bool get isSos => packetType == 'sos';

  Map<String, dynamic> toDbMap() {
    return {
      if (id != null) 'id': id,
      'message_id': messageId,
      'packet_type': packetType,
      'priority': priority,
      'next_eligible_at': nextEligibleAt,
      'relay_count': relayCount,
      'last_relayed_at': lastRelayedAt,
      'queue_state': queueState,
      'payload_base64': payloadBase64,
    };
  }

  factory RelayQueueItem.fromDbMap(Map<String, dynamic> map) {
    return RelayQueueItem(
      id: map['id'] as int?,
      messageId: map['message_id'] as String,
      packetType: map['packet_type'] as String,
      priority: map['priority'] as int? ?? 0,
      nextEligibleAt: map['next_eligible_at'] as int? ?? 0,
      relayCount: map['relay_count'] as int? ?? 0,
      lastRelayedAt: map['last_relayed_at'] as int? ?? 0,
      queueState: map['queue_state'] as String? ?? 'queued',
      payloadBase64: map['payload_base64'] as String?,
    );
  }
}
