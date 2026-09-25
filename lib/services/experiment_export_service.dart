import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:pkmproject/models/experiment_event.dart';
import 'package:pkmproject/models/experiment_session.dart';
import 'package:pkmproject/models/experiment_trial.dart';
import 'package:pkmproject/services/experiment_logger.dart';
import 'package:pkmproject/services/research_session_service.dart';

class ExperimentExportService {
  ExperimentExportService({
    ExperimentLogger? logger,
    ResearchSessionService? researchSessionService,
    Directory? outputDir,
  }) : _logger = logger ?? ExperimentLogger(),
       _researchSessionService =
           researchSessionService ?? ResearchSessionService(),
       _outputDir = outputDir;

  final ExperimentLogger _logger;
  final ResearchSessionService _researchSessionService;
  final Directory? _outputDir;

  Future<File> exportJson({String? sessionId, String? trialId}) async {
    final dir = await _resolveOutputDir();
    final session = sessionId == null
        ? await _logger.currentSession()
        : await _researchSessionService.sessionById(sessionId);
    final events = await _logger.events(sessionId: sessionId, trialId: trialId);
    final effectiveSessionId = sessionId ?? session?.sessionId ?? 'all';
    final trials = sessionId == null
        ? <ExperimentTrial>[]
        : await _researchSessionService.trialsForSession(sessionId);
    final suffix = trialId == null
        ? effectiveSessionId
        : '$effectiveSessionId-$trialId';
    final file = File('${dir.path}/resqmesh_$suffix.json');
    final payload = {
      'session': session == null ? null : _sessionJson(session),
      'trials': trials.map(_trialJson).toList(),
      'events': events.map(_eventJson).toList(),
    };
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(payload),
    );
    return file;
  }

  Future<File> exportCsv({String? sessionId, String? trialId}) async {
    final dir = await _resolveOutputDir();
    final session = sessionId == null
        ? await _logger.currentSession()
        : await _researchSessionService.sessionById(sessionId);
    final events = await _logger.events(sessionId: sessionId, trialId: trialId);
    final effectiveSessionId = sessionId ?? session?.sessionId ?? 'all';
    final trials = sessionId == null
        ? <ExperimentTrial>[]
        : await _researchSessionService.trialsForSession(sessionId);
    final trialsById = {for (final trial in trials) trial.trialId: trial};
    final suffix = trialId == null
        ? effectiveSessionId
        : '$effectiveSessionId-$trialId';
    final file = File('${dir.path}/resqmesh_$suffix.csv');
    final buffer = StringBuffer()
      ..writeln(
        'session_id,session_kind,session_name,session_code,trial_id,trial_code,trial_number,trial_status,trial_result,failure_reason,node_id,node_role,forwarding_mode,target_hop,topology_label,hypothesis,message_key,state_identity,observation_id,burst_id,event_timestamp_ms,event_timestamp_iso,elapsed_realtime_ms,protocol_timestamp_ms,event_type,message_id,sender_crc,packet_type,status,hop_in,hop_out,rssi,payload_hash,trickle_imin_ms,trickle_imax_ms,trickle_k,basic_interval_ms,jitter_min_ms,jitter_max_ms,burst_duration_ms,scan_mode,advertise_mode,tx_power,manufacturer_id,protocol_epoch_seconds,protocol_epoch_id,clock_offset_ms,clock_drift_ppm,clock_tolerance_ms,gateway_enabled,ack_enabled,protocol_active,expected_hop_in,configured_hop_out,node_layer,allowed_advertisers,rx_burst_gap_ms,observation_window_ms,trial_command_id,detail',
      );
    for (final event in events) {
      final trial = trialsById[event.trialId];
      buffer.writeln(
        [
          event.sessionId,
          session?.sessionKind,
          session?.name,
          session?.sessionCode,
          event.trialId,
          trial?.trialCode,
          trial?.trialNumber,
          trial?.status,
          trial?.result,
          trial?.failureReason,
          session?.deviceId,
          event.nodeRole ?? session?.nodeRole,
          event.forwardingMode ?? session?.forwardingMode,
          session?.targetHop,
          session?.topologyLabel,
          session?.hypothesis ?? session?.scenarioLabel,
          event.messageKey,
          event.stateIdentity,
          event.observationId,
          event.burstId,
          event.eventTimestampMs ?? event.timestampMs,
          DateTime.fromMillisecondsSinceEpoch(
            event.eventTimestampMs ?? event.timestampMs,
          ).toIso8601String(),
          event.elapsedRealtimeMs,
          event.protocolTimestampMs,
          event.eventType,
          event.messageId,
          event.senderCrc,
          event.packetType,
          event.status,
          event.hopIn,
          event.hopOut,
          event.rssi,
          event.payloadHash,
          session?.trickleIminMs,
          session?.trickleImaxMs,
          session?.trickleK,
          session?.basicIntervalMs,
          session?.jitterMinMs,
          session?.jitterMaxMs,
          session?.sosAdvertiseBurstMs,
          session?.scanMode,
          session?.advertiseMode,
          session?.txPower,
          session?.manufacturerId,
          session?.protocolEpochSeconds,
          session?.protocolEpochId,
          session?.clockOffsetMs,
          session?.clockDriftPpm,
          session?.clockToleranceMs,
          session?.gatewayEnabled,
          session?.ackEnabled,
          session?.protocolActive,
          session?.expectedHopIn,
          session?.hopOut,
          session?.nodeLayer,
          session?.allowedAdvertisersJson,
          session?.rxBurstGapMs,
          session?.observationWindowMs,
          trial?.commandId,
          event.detailJson,
        ].map(_csvCell).join(','),
      );
    }
    await file.writeAsString(buffer.toString());
    return file;
  }

  Future<Directory> _resolveOutputDir() async {
    final dir = _outputDir ?? await getApplicationDocumentsDirectory();
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Map<String, dynamic> _sessionJson(ExperimentSession session) {
    return {
      'session_id': session.sessionId,
      'session_kind': session.sessionKind,
      'device_id': session.deviceId,
      'device_manufacturer': session.deviceManufacturer,
      'device_model': session.deviceModel,
      'android_version': session.androidVersion,
      'android_sdk': session.androidSdk,
      'forwarding_mode': session.forwardingMode,
      'max_hop': session.maxHop,
      'message_lifetime_ms': session.messageLifetimeMs,
      'relay_cooldown_ms': session.relayCooldownMs,
      'started_at': session.startedAt,
      'ended_at': session.endedAt,
      'name': session.name,
      'node_role': session.nodeRole,
      'target_hop': session.targetHop,
      'topology_label': session.topologyLabel,
      'scenario_label': session.scenarioLabel,
      'notes': session.notes,
      'status': session.status,
      'app_version': session.appVersion,
      'app_version_code': session.appVersionCode,
      'build_id': session.buildId,
      'trickle_imin_ms': session.trickleIminMs,
      'trickle_imax_ms': session.trickleImaxMs,
      'trickle_imax_doublings': session.trickleImaxDoublings,
      'trickle_k': session.trickleK,
      'sos_advertise_burst_ms': session.sosAdvertiseBurstMs,
      'trial_timeout_seconds': session.trialTimeoutSeconds,
      'session_code': session.sessionCode,
      'hypothesis': session.hypothesis,
      'observation_window_ms': session.observationWindowMs,
      'basic_interval_ms': session.basicIntervalMs,
      'jitter_min_ms': session.jitterMinMs,
      'jitter_max_ms': session.jitterMaxMs,
      'scan_mode': session.scanMode,
      'advertise_mode': session.advertiseMode,
      'tx_power': session.txPower,
      'manufacturer_id': session.manufacturerId,
      'protocol_epoch_seconds': session.protocolEpochSeconds,
      'protocol_epoch_id': session.protocolEpochId,
      'clock_offset_ms': session.clockOffsetMs,
      'clock_drift_ppm': session.clockDriftPpm,
      'clock_tolerance_ms': session.clockToleranceMs,
      'gateway_enabled': session.gatewayEnabled,
      'ack_enabled': session.ackEnabled,
      'protocol_active': session.protocolActive,
      'expected_hop_in': session.expectedHopIn,
      'hop_out': session.hopOut,
      'node_layer': session.nodeLayer,
      'allowed_advertisers_json': session.allowedAdvertisersJson,
      'rx_burst_gap_ms': session.rxBurstGapMs,
    };
  }

  Map<String, dynamic> _trialJson(ExperimentTrial trial) {
    return {
      'trial_id': trial.trialId,
      'session_id': trial.sessionId,
      'trial_number': trial.trialNumber,
      'trial_code': trial.trialCode,
      'started_at': trial.startedAt,
      'ended_at': trial.endedAt,
      'status': trial.status,
      'result': trial.result,
      'failure_reason': trial.failureReason,
      'notes': trial.notes,
      'observation_ended_at': trial.observationEndedAt,
      'finalized_at': trial.finalizedAt,
      'command_id': trial.commandId,
    };
  }

  Map<String, dynamic> _eventJson(ExperimentEvent event) {
    return {
      'id': event.id,
      'session_id': event.sessionId,
      'trial_id': event.trialId,
      'event_type': event.eventType,
      'message_id': event.messageId,
      'sender_crc': event.senderCrc,
      'timestamp_ms': event.timestampMs,
      'event_timestamp_ms': event.eventTimestampMs,
      'elapsed_realtime_ms': event.elapsedRealtimeMs,
      'protocol_timestamp_ms': event.protocolTimestampMs,
      'node_role': event.nodeRole,
      'forwarding_mode': event.forwardingMode,
      'hop_count': event.hopCount,
      'packet_type': event.packetType,
      'status': event.status,
      'hop_in': event.hopIn,
      'hop_out': event.hopOut,
      'rssi': event.rssi,
      'payload_hash': event.payloadHash,
      'detail_json': event.detailJson,
      'message_key': event.messageKey,
      'state_identity': event.stateIdentity,
      'observation_id': event.observationId,
      'burst_id': event.burstId,
    };
  }

  String _csvCell(Object? value) {
    if (value == null) return '';
    final raw = value.toString();
    final escaped = raw.replaceAll('"', '""');
    return '"$escaped"';
  }
}
