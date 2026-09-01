class TricklePhase {
  static const waitingTransmit = 'waiting_transmit';
  static const waitingIntervalEnd = 'waiting_interval_end';
}

class TrickleState {
  final String messageId;
  final int intervalMs;
  final int intervalStartedAt;
  final int transmitAt;
  final int intervalEndAt;
  final int consistencyCount;
  final String phase;
  final String? lastResetReason;
  final int updatedAt;

  const TrickleState({
    required this.messageId,
    required this.intervalMs,
    required this.intervalStartedAt,
    required this.transmitAt,
    required this.intervalEndAt,
    required this.consistencyCount,
    required this.phase,
    this.lastResetReason,
    required this.updatedAt,
  });

  Map<String, Object?> toDbMap() {
    return {
      'message_id': messageId,
      'interval_ms': intervalMs,
      'interval_started_at': intervalStartedAt,
      'transmit_at': transmitAt,
      'interval_end_at': intervalEndAt,
      'consistency_count': consistencyCount,
      'phase': phase,
      'last_reset_reason': lastResetReason,
      'updated_at': updatedAt,
    };
  }

  factory TrickleState.fromDbMap(Map<String, Object?> map) {
    return TrickleState(
      messageId: map['message_id'] as String,
      intervalMs: map['interval_ms'] as int,
      intervalStartedAt: map['interval_started_at'] as int,
      transmitAt: map['transmit_at'] as int,
      intervalEndAt: map['interval_end_at'] as int,
      consistencyCount: map['consistency_count'] as int? ?? 0,
      phase: map['phase'] as String? ?? TricklePhase.waitingTransmit,
      lastResetReason: map['last_reset_reason'] as String?,
      updatedAt: map['updated_at'] as int? ?? 0,
    );
  }

  TrickleState copyWith({
    int? intervalMs,
    int? intervalStartedAt,
    int? transmitAt,
    int? intervalEndAt,
    int? consistencyCount,
    String? phase,
    String? lastResetReason,
    int? updatedAt,
  }) {
    return TrickleState(
      messageId: messageId,
      intervalMs: intervalMs ?? this.intervalMs,
      intervalStartedAt: intervalStartedAt ?? this.intervalStartedAt,
      transmitAt: transmitAt ?? this.transmitAt,
      intervalEndAt: intervalEndAt ?? this.intervalEndAt,
      consistencyCount: consistencyCount ?? this.consistencyCount,
      phase: phase ?? this.phase,
      lastResetReason: lastResetReason ?? this.lastResetReason,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}

enum TrickleTransmitDecisionType {
  wait,
  allowTransmit,
  suppressTransmit,
  intervalAdvanced,
}

class TrickleTransmitDecision {
  final TrickleTransmitDecisionType type;
  final TrickleState state;
  final int nextEligibleAt;

  const TrickleTransmitDecision({
    required this.type,
    required this.state,
    required this.nextEligibleAt,
  });

  bool get shouldAdvertise => type == TrickleTransmitDecisionType.allowTransmit;

  bool get shouldSuppress =>
      type == TrickleTransmitDecisionType.suppressTransmit;
}

class TrickleInconsistencyResult {
  final TrickleState state;
  final bool resetPerformed;
  final String reason;

  const TrickleInconsistencyResult({
    required this.state,
    required this.resetPerformed,
    required this.reason,
  });
}
