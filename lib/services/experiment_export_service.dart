import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:pkmproject/models/experiment_event.dart';
import 'package:pkmproject/models/experiment_session.dart';
import 'package:pkmproject/services/experiment_logger.dart';

class ExperimentExportService {
  ExperimentExportService({ExperimentLogger? logger, Directory? outputDir})
    : _logger = logger ?? ExperimentLogger(),
      _outputDir = outputDir;

  final ExperimentLogger _logger;
  final Directory? _outputDir;

  Future<File> exportJson({String? sessionId}) async {
    final dir = await _resolveOutputDir();
    final session = await _logger.currentSession();
    final events = await _logger.events(sessionId: sessionId);
    final effectiveSessionId = sessionId ?? session?.sessionId ?? 'all';
    final file = File('${dir.path}/resqmesh_$effectiveSessionId.json');
    final payload = {
      'session': session == null ? null : _sessionJson(session),
      'events': events.map(_eventJson).toList(),
    };
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(payload),
    );
    return file;
  }

  Future<File> exportCsv({String? sessionId}) async {
    final dir = await _resolveOutputDir();
    final session = await _logger.currentSession();
    final events = await _logger.events(sessionId: sessionId);
    final effectiveSessionId = sessionId ?? session?.sessionId ?? 'all';
    final file = File('${dir.path}/resqmesh_$effectiveSessionId.csv');
    final buffer = StringBuffer()
      ..writeln(
        'id,session_id,event_type,message_id,sender_crc,timestamp_ms,hop_count,rssi,payload_hash,detail_json',
      );
    for (final event in events) {
      buffer.writeln(
        [
          event.id,
          event.sessionId,
          event.eventType,
          event.messageId,
          event.senderCrc,
          event.timestampMs,
          event.hopCount,
          event.rssi,
          event.payloadHash,
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
    };
  }

  Map<String, dynamic> _eventJson(ExperimentEvent event) {
    return {
      'id': event.id,
      'session_id': event.sessionId,
      'event_type': event.eventType,
      'message_id': event.messageId,
      'sender_crc': event.senderCrc,
      'timestamp_ms': event.timestampMs,
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
}
