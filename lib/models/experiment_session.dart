class ExperimentSession {
  final String sessionId;
  final String deviceId;
  final String deviceModel;
  final String androidVersion;
  final String forwardingMode;
  final int maxHop;
  final int messageLifetimeMs;
  final int relayCooldownMs;
  final int startedAt;
  final int? endedAt;

  const ExperimentSession({
    required this.sessionId,
    required this.deviceId,
    required this.deviceModel,
    required this.androidVersion,
    required this.forwardingMode,
    required this.maxHop,
    required this.messageLifetimeMs,
    required this.relayCooldownMs,
    required this.startedAt,
    this.endedAt,
  });

  Map<String, dynamic> toDbMap() {
    return {
      'session_id': sessionId,
      'device_id': deviceId,
      'device_model': deviceModel,
      'android_version': androidVersion,
      'forwarding_mode': forwardingMode,
      'max_hop': maxHop,
      'message_lifetime_ms': messageLifetimeMs,
      'relay_cooldown_ms': relayCooldownMs,
      'started_at': startedAt,
      'ended_at': endedAt,
    };
  }

  factory ExperimentSession.fromDbMap(Map<String, dynamic> map) {
    return ExperimentSession(
      sessionId: map['session_id'] as String,
      deviceId: map['device_id'] as String,
      deviceModel: map['device_model'] as String,
      androidVersion: map['android_version'] as String,
      forwardingMode: map['forwarding_mode'] as String,
      maxHop: map['max_hop'] as int,
      messageLifetimeMs: map['message_lifetime_ms'] as int,
      relayCooldownMs: map['relay_cooldown_ms'] as int,
      startedAt: map['started_at'] as int,
      endedAt: map['ended_at'] as int?,
    );
  }
}
