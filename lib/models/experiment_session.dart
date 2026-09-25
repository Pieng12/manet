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
  final int? trickleIminMs;
  final int? trickleImaxMs;
  final int? trickleImaxDoublings;
  final int? trickleK;
  final int? sosAdvertiseBurstMs;
  final String? sessionCode;
  final String? hypothesis;
  final int? observationWindowMs;
  final int? basicIntervalMs;
  final int? jitterMinMs;
  final int? jitterMaxMs;
  final String? scanMode;
  final String? advertiseMode;
  final String? txPower;
  final int? manufacturerId;
  final int? protocolEpochSeconds;
  final String? protocolEpochId;
  final double? clockOffsetMs;
  final double? clockDriftPpm;
  final int? clockToleranceMs;
  final bool gatewayEnabled;
  final bool ackEnabled;
  final bool protocolActive;
  final int? expectedHopIn;
  final int? hopOut;
  final int? nodeLayer;
  final String? allowedAdvertisersJson;
  final int? rxBurstGapMs;

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
    this.trickleIminMs,
    this.trickleImaxMs,
    this.trickleImaxDoublings,
    this.trickleK,
    this.sosAdvertiseBurstMs,
    this.sessionCode,
    this.hypothesis,
    this.observationWindowMs,
    this.basicIntervalMs,
    this.jitterMinMs,
    this.jitterMaxMs,
    this.scanMode,
    this.advertiseMode,
    this.txPower,
    this.manufacturerId,
    this.protocolEpochSeconds,
    this.protocolEpochId,
    this.clockOffsetMs,
    this.clockDriftPpm,
    this.clockToleranceMs,
    this.gatewayEnabled = false,
    this.ackEnabled = false,
    this.protocolActive = true,
    this.expectedHopIn,
    this.hopOut,
    this.nodeLayer,
    this.allowedAdvertisersJson,
    this.rxBurstGapMs,
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
      'trickle_imin_ms': trickleIminMs,
      'trickle_imax_ms': trickleImaxMs,
      'trickle_imax_doublings': trickleImaxDoublings,
      'trickle_k': trickleK,
      'sos_advertise_burst_ms': sosAdvertiseBurstMs,
      'session_code': sessionCode,
      'hypothesis': hypothesis,
      'observation_window_ms': observationWindowMs,
      'basic_interval_ms': basicIntervalMs,
      'jitter_min_ms': jitterMinMs,
      'jitter_max_ms': jitterMaxMs,
      'scan_mode': scanMode,
      'advertise_mode': advertiseMode,
      'tx_power': txPower,
      'manufacturer_id': manufacturerId,
      'protocol_epoch_seconds': protocolEpochSeconds,
      'protocol_epoch_id': protocolEpochId,
      'clock_offset_ms': clockOffsetMs,
      'clock_drift_ppm': clockDriftPpm,
      'clock_tolerance_ms': clockToleranceMs,
      'gateway_enabled': gatewayEnabled ? 1 : 0,
      'ack_enabled': ackEnabled ? 1 : 0,
      'protocol_active': protocolActive ? 1 : 0,
      'expected_hop_in': expectedHopIn,
      'hop_out': hopOut,
      'node_layer': nodeLayer,
      'allowed_advertisers_json': allowedAdvertisersJson,
      'rx_burst_gap_ms': rxBurstGapMs,
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
      trickleIminMs: map['trickle_imin_ms'] as int?,
      trickleImaxMs: map['trickle_imax_ms'] as int?,
      trickleImaxDoublings: map['trickle_imax_doublings'] as int?,
      trickleK: map['trickle_k'] as int?,
      sosAdvertiseBurstMs: map['sos_advertise_burst_ms'] as int?,
      sessionCode: map['session_code'] as String?,
      hypothesis: map['hypothesis'] as String?,
      observationWindowMs: map['observation_window_ms'] as int?,
      basicIntervalMs: map['basic_interval_ms'] as int?,
      jitterMinMs: map['jitter_min_ms'] as int?,
      jitterMaxMs: map['jitter_max_ms'] as int?,
      scanMode: map['scan_mode'] as String?,
      advertiseMode: map['advertise_mode'] as String?,
      txPower: map['tx_power'] as String?,
      manufacturerId: map['manufacturer_id'] as int?,
      protocolEpochSeconds: map['protocol_epoch_seconds'] as int?,
      protocolEpochId: map['protocol_epoch_id'] as String?,
      clockOffsetMs: (map['clock_offset_ms'] as num?)?.toDouble(),
      clockDriftPpm: (map['clock_drift_ppm'] as num?)?.toDouble(),
      clockToleranceMs: map['clock_tolerance_ms'] as int?,
      gatewayEnabled: (map['gateway_enabled'] as int? ?? 0) == 1,
      ackEnabled: (map['ack_enabled'] as int? ?? 0) == 1,
      protocolActive: (map['protocol_active'] as int? ?? 1) == 1,
      expectedHopIn: map['expected_hop_in'] as int?,
      hopOut: map['hop_out'] as int?,
      nodeLayer: map['node_layer'] as int?,
      allowedAdvertisersJson: map['allowed_advertisers_json'] as String?,
      rxBurstGapMs: map['rx_burst_gap_ms'] as int?,
    );
  }
}
