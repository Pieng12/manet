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
  final String? name;
  final String? nodeRole;
  final int? targetHop;
  final String? topologyLabel;
  final String? scenarioLabel;
  final String? notes;
  final String status;
  final String? appVersion;
  final int? trialTimeoutSeconds;
  final String sessionKind;
  final String? deviceManufacturer;
  final int? androidSdk;
  final String? appVersionCode;
  final String? buildId;

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
    this.name,
    this.nodeRole,
    this.targetHop,
    this.topologyLabel,
    this.scenarioLabel,
    this.notes,
    this.status = 'RUNNING',
    this.appVersion,
    this.trialTimeoutSeconds,
    this.sessionKind = 'AUTO',
    this.deviceManufacturer,
    this.androidSdk,
    this.appVersionCode,
    this.buildId,
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
      'name': name,
      'node_role': nodeRole,
      'target_hop': targetHop,
      'topology_label': topologyLabel,
      'scenario_label': scenarioLabel,
      'notes': notes,
      'status': status,
      'app_version': appVersion,
      'trial_timeout_seconds': trialTimeoutSeconds,
      'session_kind': sessionKind,
      'device_manufacturer': deviceManufacturer,
      'android_sdk': androidSdk,
      'app_version_code': appVersionCode,
      'build_id': buildId,
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
      name: map['name'] as String?,
      nodeRole: map['node_role'] as String?,
      targetHop: map['target_hop'] as int?,
      topologyLabel: map['topology_label'] as String?,
      scenarioLabel: map['scenario_label'] as String?,
      notes: map['notes'] as String?,
      status: map['status'] as String? ?? 'RUNNING',
      appVersion: map['app_version'] as String?,
      trialTimeoutSeconds: map['trial_timeout_seconds'] as int?,
      sessionKind: map['session_kind'] as String? ?? 'AUTO',
      deviceManufacturer: map['device_manufacturer'] as String?,
      androidSdk: map['android_sdk'] as int?,
      appVersionCode: map['app_version_code']?.toString(),
      buildId: map['build_id'] as String?,
    );
  }
}
