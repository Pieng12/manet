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
    final session = await _logger.currentSession();
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
    final session = await _logger.currentSession();
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
        'session_id,session_name,trial_id,trial_number,trial_status,device_id,node_role,forwarding_mode,target_hop,topology_label,scenario_label,event_timestamp_ms,event_timestamp_iso,elapsed_realtime_ms,event_type,message_id,sender_crc,protocol_timestamp,packet_type,status,hop_in,hop_out,rssi,payload_hash,relay_count,duplicate_count,queue_size,sos_queue_size,ack_queue_size,detail',
      );
    for (final event in events) {
      final trial = trialsById[event.trialId];
      buffer.writeln(
        [
          event.sessionId,
          session?.name,
          event.trialId,
          trial?.trialNumber,
          trial?.status,
          session?.deviceId,
          event.nodeRole ?? session?.nodeRole,
          event.forwardingMode ?? session?.forwardingMode,
          session?.targetHop,
          session?.topologyLabel,
          session?.scenarioLabel,
          event.eventTimestampMs ?? event.timestampMs,
          DateTime.fromMillisecondsSinceEpoch(
            event.eventTimestampMs ?? event.timestampMs,
          ).toIso8601String(),
          event.elapsedRealtimeMs,
          event.eventType,
          event.messageId,
          event.senderCrc,
          event.timestampMs,
          _detailValue(event.detailJson, 'kind'),
          _detailValue(event.detailJson, 'status'),
          event.hopCount,
          _detailValue(event.detailJson, 'hop_out'),
          event.rssi,
          event.payloadHash,
          _detailValue(event.detailJson, 'relay_count'),
          _detailValue(event.detailJson, 'duplicate_count'),
          _detailValue(event.detailJson, 'queue_size'),
          _detailValue(event.detailJson, 'sos_queue_size'),
          _detailValue(event.detailJson, 'ack_queue_size'),
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
      'device_id': session.deviceId,
      'device_model': session.deviceModel,
      'android_version': session.androidVersion,
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
      'trial_timeout_seconds': session.trialTimeoutSeconds,
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
      'node_role': event.nodeRole,
      'forwarding_mode': event.forwardingMode,
      'hop_count': event.hopCount,
      'rssi': event.rssi,
      'payload_hash': event.payloadHash,
      'detail_json': event.detailJson,
    };
  }

  String _csvCell(Object? value) {
    if (value == null) return '';
    final raw = value.toString();
    final escaped = raw.replaceAll('"', '""');
    return '"$escaped"';
  }

  Object? _detailValue(String? detailJson, String key) {
    if (detailJson == null || detailJson.isEmpty) return null;
    try {
      final decoded = jsonDecode(detailJson);
      return decoded is Map<String, dynamic> ? decoded[key] : null;
    } catch (_) {
      return null;
    }
  }
}
