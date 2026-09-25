import 'dart:convert';

import 'package:pkmproject/config/mesh_config.dart';
import 'package:pkmproject/models/sos_message.dart';
import 'package:pkmproject/services/ble_advertiser_service.dart';
import 'package:pkmproject/services/ble_relay_service.dart';
import 'package:pkmproject/services/database_helper.dart';
import 'package:pkmproject/services/experiment_export_service.dart';
import 'package:pkmproject/services/experiment_clock.dart';
import 'package:pkmproject/services/experiment_logger.dart';
import 'package:pkmproject/services/native_bridge_service.dart';
import 'package:pkmproject/services/relay_queue_service.dart';
import 'package:pkmproject/services/research_session_service.dart';
import 'package:pkmproject/services/protocol_epoch_readiness.dart';
import 'package:pkmproject/sync_service.dart';
import 'package:pkmproject/utils/hash_utils.dart';
import 'package:sqflite/sqflite.dart';

typedef SosActivator = Future<void> Function(SOSMessage message);

class AndroidExperimentCommandService {
  AndroidExperimentCommandService({
    Database? database,
    DatabaseHelper? databaseHelper,
    ResearchSessionService? sessions,
    ExperimentLogger? logger,
    ExperimentExportService? exporter,
    SosActivator? activateSos,
    ClockSource? clock,
    Duration resetQuietPeriod = MeshConfig.sosAdvertiseBurstDuration,
  }) : _database = database,
       _databaseHelper = databaseHelper ?? DatabaseHelper(),
       _sessions =
           sessions ??
           ResearchSessionService(
             database: database,
             databaseHelper: databaseHelper,
           ),
       _logger =
           logger ??
           ExperimentLogger(database: database, databaseHelper: databaseHelper),
       _exporter =
           exporter ??
           ExperimentExportService(
             logger: logger,
             researchSessionService: sessions,
           ),
       _activateSos = activateSos ?? BleRelayService().activateForMessage,
       _clock = clock ?? ExperimentClock.instance,
       _resetQuietPeriod = resetQuietPeriod;

  final Database? _database;
  final DatabaseHelper _databaseHelper;
  final ResearchSessionService _sessions;
  final ExperimentLogger _logger;
  final ExperimentExportService _exporter;
  final SosActivator _activateSos;
  final ClockSource _clock;
  final Duration _resetQuietPeriod;

  Future<Database> get _db async => _database ?? _databaseHelper.database;

  Future<Map<String, dynamic>> execute(
    String command,
    Map<String, dynamic> arguments,
  ) async {
    final normalized = command.trim().toLowerCase();
    if (normalized == 'get_status' || normalized == 'readiness') {
      return _status();
    }
    final commandId = _requiredString(arguments, 'command_id');
    final db = await _db;
    final existing = await db.query(
      'experiment_commands',
      where: 'command_id = ?',
      whereArgs: [commandId],
      limit: 1,
    );
    if (existing.isNotEmpty) {
      return Map<String, dynamic>.from(
        jsonDecode(existing.first['result_json'] as String) as Map,
      )..['idempotent_replay'] = true;
    }
    await db.insert('experiment_commands', {
      'command_id': commandId,
      'command_name': normalized,
      'session_id': arguments['session_id']?.toString(),
      'trial_id': arguments['trial_id']?.toString(),
      'result_json': jsonEncode({'ok': false, 'state': 'PROCESSING'}),
      'created_at': DateTime.now().millisecondsSinceEpoch,
    });

    try {
      final result = switch (normalized) {
        'configure_session' => await _configureSession(arguments),
        'start_trial' => await _startTrial(arguments),
        'trigger_sos' => await _triggerSos(arguments),
        'end_observation_window' => await _endObservationWindow(arguments),
        'finalize_trial' => await _finalizeTrial(arguments),
        'export_trial' => await _exportTrial(arguments),
        'reset_trial' => await _resetTrial(arguments),
        _ => throw ArgumentError('UNKNOWN_COMMAND: $normalized'),
      };
      final response = <String, dynamic>{
        'ok': true,
        'command': normalized,
        'command_id': commandId,
        ...result,
      };
      await db.update(
        'experiment_commands',
        {'result_json': jsonEncode(response)},
        where: 'command_id = ?',
        whereArgs: [commandId],
      );
      return response;
    } catch (error) {
      final response = <String, dynamic>{
        'ok': false,
        'command': normalized,
        'command_id': commandId,
        'error': error.toString(),
      };
      await db.update(
        'experiment_commands',
        {'result_json': jsonEncode(response)},
        where: 'command_id = ?',
        whereArgs: [commandId],
      );
      return response;
    }
  }

  Future<Map<String, dynamic>> _configureSession(
    Map<String, dynamic> args,
  ) async {
    final mode = _forwardingMode(_requiredString(args, 'mode'));
    final mainExperiment = args['main_experiment'] != false;
    _requireSupportedInt(
      args,
      'protocol_epoch_seconds',
      MeshConfig.protocolEpochSeconds,
    );
    _requireSupportedInt(args, 'manufacturer_id', MeshConfig.manufacturerId);
    _requireSupportedInt(
      args,
      'burst_duration_ms',
      MeshConfig.sosAdvertiseBurstDuration.inMilliseconds,
    );
    final requestedEpochId = args['protocol_epoch_id']?.toString();
    if (requestedEpochId != null &&
        requestedEpochId != MeshConfig.protocolEpochId) {
      throw ArgumentError(
        'UNSUPPORTED_protocol_epoch_id: $requestedEpochId '
        '(expected ${MeshConfig.protocolEpochId})',
      );
    }
    final rxBurstGapMs =
        _optionalInt(args['rx_burst_gap_ms']) ??
        MeshConfig.defaultRxBurstGap.inMilliseconds;
    if (rxBurstGapMs <= 0) {
      throw ArgumentError('INVALID_rx_burst_gap_ms');
    }
    final role = _requiredString(args, 'role').toUpperCase();
    if (!const {
      'SOURCE',
      'RELAY',
      'DESTINATION',
      'GATEWAY',
      'OBSERVER',
    }.contains(role)) {
      throw ArgumentError('INVALID_ROLE: $role');
    }
    final session = await _sessions.startSession(
      sessionId: _requiredString(args, 'session_id'),
      sessionCode: _requiredString(args, 'session_code'),
      deviceId: _requiredString(args, 'node_id'),
      name: args['name']?.toString() ?? _requiredString(args, 'session_code'),
      nodeRole: role,
      targetHop: _requiredInt(args, 'target_hop'),
      topologyLabel:
          args['topology']?.toString() ??
          'H${_requiredInt(args, 'target_hop')}',
      scenarioLabel: _requiredString(args, 'hypothesis'),
      hypothesis: _requiredString(args, 'hypothesis'),
      observationWindowMs: _requiredInt(args, 'observation_window_ms'),
      forwardingMode: mode,
      buildId: _requiredString(args, 'build_id'),
      clockOffsetMs: _optionalDouble(args['clock_offset_ms']),
      clockDriftPpm: _optionalDouble(args['clock_drift_ppm']),
      clockToleranceMs: _optionalInt(args['clock_tolerance_ms']),
      gatewayEnabled: mainExperiment ? false : args['gateway_enabled'] == true,
      ackEnabled: mainExperiment ? false : args['ack_enabled'] == true,
      protocolActive: args['protocol_active'] != false,
      expectedHopIn: _optionalInt(args['expected_hop_in']),
      hopOut: _optionalInt(args['hop_out']),
      nodeLayer: _optionalInt(args['node_layer']),
      allowedAdvertisersJson: args['allowed_advertisers'] == null
          ? null
          : jsonEncode(args['allowed_advertisers']),
      rxBurstGapMs: rxBurstGapMs,
    );
    RelayQueueService.configureSessionMode(mode);
    await NativeBridgeService.setResearchRxBurstGapMs(
      session.rxBurstGapMs ?? MeshConfig.defaultRxBurstGap.inMilliseconds,
    );
    return {
      'session_id': session.sessionId,
      'mode': session.forwardingMode,
      'role': session.nodeRole,
      'gateway_enabled': session.gatewayEnabled,
      'ack_enabled': session.ackEnabled,
      'main_experiment': mainExperiment,
    };
  }

  Future<Map<String, dynamic>> _startTrial(Map<String, dynamic> args) async {
    _requireValidProtocolEpoch();
    final trial = await _sessions.startTrial(
      sessionId: _requiredString(args, 'session_id'),
      trialId: _requiredString(args, 'trial_id'),
      trialCode: _requiredString(args, 'trial_code'),
      commandId: _requiredString(args, 'command_id'),
    );
    await _logger.logEvent(
      eventType: ExperimentEventTypes.trialWindowStarted,
      deviceId: SyncService().deviceId,
      eventKey: 'TRIAL_WINDOW_STARTED|${trial.trialId}',
      detail: {'trial_code': trial.trialCode},
    );
    return {'trial_id': trial.trialId, 'trial_code': trial.trialCode};
  }

  Future<Map<String, dynamic>> _triggerSos(Map<String, dynamic> args) async {
    _requireValidProtocolEpoch();
    final trialId = _requiredString(args, 'trial_id');
    final db = await _db;
    final trialRows = await db.query(
      'experiment_trials',
      where: 'trial_id = ? AND status = ?',
      whereArgs: [trialId, 'RUNNING'],
      limit: 1,
    );
    if (trialRows.isEmpty) throw StateError('TRIAL_NOT_RUNNING');
    final existing = await db.query(
      'sos_messages',
      where: 'trial_id = ?',
      whereArgs: [trialId],
      limit: 1,
    );
    if (existing.isNotEmpty) {
      throw StateError('TRIAL_ALREADY_HAS_LOGICAL_SOS');
    }
    final now = _clock.wallTimeMs();
    final nodeId = args['node_id']?.toString() ?? SyncService().deviceId;
    final message = SOSMessage(
      id: 'research-$trialId',
      senderId: nodeId,
      senderCrc: crc32(nodeId),
      content: 'RESEARCH_SOS',
      latitude: _optionalDouble(args['latitude']) ?? 3.5952,
      longitude: _optionalDouble(args['longitude']) ?? 98.6722,
      createdAt: now,
      updatedAt: now,
      protocolTimestampMs: now,
      hopCount: 1,
      trialId: trialId,
    );
    await DatabaseHelper.ensureMonotonicStateTimestampInDb(db, message);
    await _logger.logEvent(
      eventType: ExperimentEventTypes.sosCreated,
      deviceId: nodeId,
      messageId: message.id,
      senderCrc: message.senderCrc,
      hopOut: 1,
      protocolTimestampMs: message.protocolTimestampMs,
      packetType: 'sos',
      status: message.status.name,
      messageKey: message.messageKey.value,
      stateIdentity: message.stateIdentity.value,
      eventKey: 'SOS_CREATED|$trialId',
      detail: {'command_id': args['command_id']},
    );
    await _activateSos(message);
    return {
      'trial_id': trialId,
      'message_id': message.id,
      'message_key': message.messageKey.value,
      'hop': 1,
    };
  }

  Future<Map<String, dynamic>> _endObservationWindow(
    Map<String, dynamic> args,
  ) async {
    final trialId = _requiredString(args, 'trial_id');
    final now = DateTime.now().millisecondsSinceEpoch;
    final db = await _db;
    final changed = await db.update(
      'experiment_trials',
      {'status': 'WINDOW_ENDED', 'observation_ended_at': now},
      where: 'trial_id = ? AND status = ?',
      whereArgs: [trialId, 'RUNNING'],
    );
    await _logger.logEvent(
      eventType: ExperimentEventTypes.trialWindowEnded,
      deviceId: SyncService().deviceId,
      eventTimestampMs: now,
      eventKey: 'TRIAL_WINDOW_ENDED|$trialId',
    );
    return {'trial_id': trialId, 'changed': changed == 1};
  }

  Future<Map<String, dynamic>> _finalizeTrial(Map<String, dynamic> args) async {
    final result = _requiredString(args, 'result').toUpperCase();
    if (!const {'SUCCESS', 'FAILED_DELIVERY', 'INVALID'}.contains(result)) {
      throw ArgumentError('INVALID_TRIAL_RESULT: $result');
    }
    final trialId = _requiredString(args, 'trial_id');
    final now = DateTime.now().millisecondsSinceEpoch;
    final db = await _db;
    await db.update(
      'experiment_trials',
      {
        'ended_at': now,
        'finalized_at': now,
        'status': result == 'INVALID' ? 'INVALID' : 'COMPLETED',
        'result': result,
        'failure_reason': args['reason']?.toString(),
      },
      where: 'trial_id = ?',
      whereArgs: [trialId],
    );
    return {'trial_id': trialId, 'result': result};
  }

  Future<Map<String, dynamic>> _exportTrial(Map<String, dynamic> args) async {
    final sessionId = _requiredString(args, 'session_id');
    final trialId = _requiredString(args, 'trial_id');
    final jsonFile = await _exporter.exportJson(
      sessionId: sessionId,
      trialId: trialId,
    );
    final csvFile = await _exporter.exportCsv(
      sessionId: sessionId,
      trialId: trialId,
    );
    return {
      'trial_id': trialId,
      'json_path': jsonFile.path,
      'csv_path': csvFile.path,
    };
  }

  Future<Map<String, dynamic>> _resetTrial(Map<String, dynamic> args) async {
    final trialId = _requiredString(args, 'trial_id');
    await BleAdvertiserService().stopAdvertising();
    final db = await _db;
    final rows = await db.query(
      'sos_messages',
      columns: const ['id'],
      where: 'trial_id = ?',
      whereArgs: [trialId],
    );
    final messageIds = rows.map((row) => row['id'] as String).toList();
    await db.transaction((txn) async {
      for (final messageId in messageIds) {
        await txn.delete(
          'relay_queue',
          where: 'message_id = ?',
          whereArgs: [messageId],
        );
        await txn.delete(
          'trickle_observations',
          where: 'message_id = ?',
          whereArgs: [messageId],
        );
        await txn.delete(
          'trickle_states',
          where: 'message_id = ?',
          whereArgs: [messageId],
        );
      }
      await txn.delete(
        'sos_messages',
        where: 'trial_id = ?',
        whereArgs: [trialId],
      );
      await txn.delete(
        'ack_tombstones',
        where: 'trial_id = ?',
        whereArgs: [trialId],
      );
      await txn.delete(
        'processed_ble_observations',
        where: 'trial_id = ?',
        whereArgs: [trialId],
      );
      await txn.delete(
        'relay_queue',
        where: 'trial_id = ?',
        whereArgs: [trialId],
      );
    });
    await NativeBridgeService.clearNativeBleInbox();
    await NativeBridgeService.setHasPendingRelayWork(false);
    await _logger.logEvent(
      eventType: ExperimentEventTypes.trialReset,
      deviceId: SyncService().deviceId,
      eventKey: 'TRIAL_RESET|$trialId',
      detail: {'quiet_period_ms': _resetQuietPeriod.inMilliseconds},
    );
    await Future<void>.delayed(_resetQuietPeriod);
    return {
      'trial_id': trialId,
      'state_cleared': true,
      'archived_events_preserved': true,
    };
  }

  Future<Map<String, dynamic>> _status() async {
    final session = await _sessions.currentSession();
    final trial = await _sessions.currentTrial(sessionId: session?.sessionId);
    final capabilities = await NativeBridgeService.getBleCapabilities();
    final db = await _db;
    final queueCount =
        Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM relay_queue'),
        ) ??
        0;
    final epoch = ProtocolEpochReadiness.at(_clock.wallTimeMs());
    return {
      'ok': true,
      'bluetooth': capabilities['bluetoothEnabled'],
      'permissions': {
        'scan': capabilities['scanPermission'],
        'advertise': capabilities['advertisePermission'],
      },
      'scanner': capabilities['nativeScanActive'],
      'advertiser': capabilities['nativeAdvertisingActive'],
      'mode': session?.forwardingMode,
      'session_id': session?.sessionId,
      'trial_id': trial?.trialId,
      'queue_size': queueCount,
      'last_error': capabilities['lastErrorCode'],
      'protocol_epoch': epoch.toJson(),
    };
  }

  void _requireValidProtocolEpoch() {
    final epoch = ProtocolEpochReadiness.at(_clock.wallTimeMs());
    if (!epoch.isValid) {
      throw StateError(
        'PROTOCOL_EPOCH_OUT_OF_RANGE: ${epoch.epochId} '
        'ended at ${DateTime.fromMillisecondsSinceEpoch(epoch.representableEndMs, isUtc: true).toIso8601String()}',
      );
    }
  }

  static String _requiredString(Map<String, dynamic> args, String key) {
    final value = args[key]?.toString().trim();
    if (value == null || value.isEmpty) {
      throw ArgumentError('MISSING_$key');
    }
    return value;
  }

  static int _requiredInt(Map<String, dynamic> args, String key) {
    final value = _optionalInt(args[key]);
    if (value == null) throw ArgumentError('MISSING_$key');
    return value;
  }

  static int? _optionalInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '');
  }

  static void _requireSupportedInt(
    Map<String, dynamic> args,
    String key,
    int supported,
  ) {
    final provided = _optionalInt(args[key]);
    if (provided != null && provided != supported) {
      throw ArgumentError('UNSUPPORTED_$key: $provided (expected $supported)');
    }
  }

  static double? _optionalDouble(Object? value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '');
  }

  static ForwardingMode _forwardingMode(String value) {
    return switch (value.toLowerCase()) {
      'trickle' => ForwardingMode.trickle,
      'basic' || 'basic_flooding' => ForwardingMode.basicFlooding,
      _ => throw ArgumentError('INVALID_FORWARDING_MODE: $value'),
    };
  }
}
