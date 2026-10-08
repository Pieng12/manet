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
import 'package:pkmproject/services/range_test_service.dart';
import 'package:pkmproject/services/neighbor_runtime.dart';
import 'package:pkmproject/services/neighbor_status_controller.dart';
import 'package:pkmproject/sync_service.dart';
import 'package:pkmproject/utils/hash_utils.dart';
import 'package:sqflite/sqflite.dart';
import 'package:shared_preferences/shared_preferences.dart';

typedef SosActivator = Future<void> Function(SOSMessage message);
typedef ObservationWindowStarter = void Function();
typedef ObservationWindowStopper = Future<void> Function();

class AndroidExperimentCommandService {
  AndroidExperimentCommandService({
    Database? database,
    DatabaseHelper? databaseHelper,
    ResearchSessionService? sessions,
    ExperimentLogger? logger,
    ExperimentExportService? exporter,
    SosActivator? activateSos,
    ObservationWindowStarter? startObservationWindow,
    ObservationWindowStopper? stopObservationWindow,
    ClockSource? clock,
    RangeTestService? rangeService,
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
       _startObservationWindow =
           startObservationWindow ??
           BleAdvertiserService().resumeResearchObservationWindow,
       _stopObservationWindow =
           stopObservationWindow ??
           BleAdvertiserService().pauseResearchObservationWindow,
       _clock = clock ?? ExperimentClock.instance,
       _rangeService = rangeService,
       _resetQuietPeriod = resetQuietPeriod;

  final Database? _database;
  final DatabaseHelper _databaseHelper;
  final ResearchSessionService _sessions;
  final ExperimentLogger _logger;
  final ExperimentExportService _exporter;
  final SosActivator _activateSos;
  final ObservationWindowStarter _startObservationWindow;
  final ObservationWindowStopper _stopObservationWindow;
  final ClockSource _clock;
  final RangeTestService? _rangeService;
  RangeTestService get _range =>
      _rangeService ??
      RangeTestService(
        protocol: _database,
        clock: _clock,
        observePoints: false,
      );
  final Duration _resetQuietPeriod;

  Future<Database> get _db async => _database ?? _databaseHelper.database;

  Future<Map<String, dynamic>> execute(
    String command,
    Map<String, dynamic> arguments,
  ) async {
    final normalized = command.trim().toLowerCase();
    if (normalized == 'get_status' || normalized == 'readiness') {
      final result = await _status();
      result['command'] = normalized;
      if (arguments.containsKey('command_id')) {
        result['command_id'] = arguments['command_id'];
      }
      return result;
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
        'set_rx_participation' => await _participation(arguments, rxOnly: true),
        'set_node_participation' => await _participation(
          arguments,
          rxOnly: false,
        ),
        'get_neighbor_status' => await _neighborStatus(),
        'store_neighbor_metrics' => await _storeNeighborMetrics(arguments),
        'set_forwarding_mode' => await _setForwardingMode(arguments),
        'configure_range_test' => await _range.configure(arguments),
        'get_range_test_status' => await _rangeStatus(),
        'export_range_test' => await _range.export(),
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

  Future<Map<String, dynamic>> _participation(
    Map<String, dynamic> args, {
    required bool rxOnly,
  }) async {
    final enabled = args['enabled'] == true;
    final result = await NativeBridgeService.setResearchParticipation(
      enabled,
      rxOnly: rxOnly,
    );
    if (enabled && result['confirmed_enabled'] == true) {
      NeighborRuntime.instance.restartStatus(_clock.monotonicTimeMs());
    }
    if (!rxOnly) {
      if (enabled) {
        _startObservationWindow();
        await BleAdvertiserService().advertiseLatestOrStop();
      } else {
        await _stopObservationWindow();
      }
    }
    await _logger.logEvent(
      eventType: rxOnly
          ? 'RX_PARTICIPATION_CHANGED'
          : 'NODE_PARTICIPATION_CHANGED',
      deviceId: 'unknown',
      detail: {'requested_enabled': enabled, ...result},
    );
    return result;
  }

  Future<Map<String, dynamic>> _setForwardingMode(
    Map<String, dynamic> args,
  ) async {
    final session = await _sessions.currentSession();
    if (session == null ||
        await _sessions.currentTrial(sessionId: session.sessionId) != null) {
      throw StateError('Mode can change only between trials');
    }
    final mode = _forwardingMode(_requiredString(args, 'mode'));
    final runtime = NeighborRuntime.instance;
    await runtime.load();
    if ((mode == ForwardingMode.trickleNeighborStatus ||
            mode == ForwardingMode.trickleMpl) &&
        runtime.configuration == null) {
      throw StateError(
        'Mode ini memerlukan konfigurasi neighbor_graph_v1 dari controller',
      );
    }
    if (runtime.configuration != null) {
      await runtime.configure({
        ...runtime.configuration!,
        'transport_profile': NeighborRuntime.profile,
        'mode': mode.logValue,
      });
    }
    await (await _db).update(
      'experiment_sessions',
      {'forwarding_mode': mode.logValue},
      where: 'session_id = ?',
      whereArgs: [session.sessionId],
    );
    RelayQueueService.configureSessionMode(mode);
    return {'mode': mode.logValue};
  }

  Future<Map<String, dynamic>> _neighborStatus() async {
    final runtime = NeighborRuntime.instance;
    await runtime.load();
    final db = await _db;
    final rows = await db.query(
      'sos_messages',
      where: 'ack_received_at IS NULL',
    );
    return {
      'transport_profile': runtime.enabled ? NeighborRuntime.profile : 'legacy',
      'scope': runtime.enabled ? runtime.scope : null,
      'local_only': true,
      'network_summary': await _networkSummary(),
      'peers': runtime.controller?.peers(_clock.monotonicTimeMs()) ?? [],
      'states': [
        for (final row in rows)
          {
            'state_identity': SOSMessage.fromDbMap(row).stateIdentity.value,
            'neighbors':
                runtime.controller
                    ?.snapshot(
                      SOSMessage.fromDbMap(row).stateIdentity,
                      _clock.monotonicTimeMs(),
                    )
                    .map((k, v) => MapEntry(k.toString(), v.name)) ??
                {},
          },
      ],
    };
  }

  Future<Map<String, dynamic>?> _networkSummary() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final raw = prefs.getString('neighbor_network_summary_v1');
    if (raw == null) return null;
    final data = Map<String, dynamic>.from(jsonDecode(raw) as Map);
    final session = await _sessions.currentSession();
    return data['session_id'] == session?.sessionId ? data : null;
  }

  Future<Map<String, dynamic>> _storeNeighborMetrics(
    Map<String, dynamic> args,
  ) async {
    final raw = utf8.decode(
      base64Decode(_requiredString(args, 'summary_base64')),
    );
    final data = Map<String, dynamic>.from(jsonDecode(raw) as Map);
    final session = await _sessions.currentSession();
    if (session?.topologyLabel != NeighborRuntime.profile ||
        data['session_id'] != session?.sessionId ||
        data['measurement_version'] != 'all-node-burst-v1' ||
        data['N'] != 5) {
      throw ArgumentError('Merged summary scope/version mismatch');
    }
    final trials = await (await _db).query(
      'experiment_trials',
      where: 'trial_id = ? AND session_id = ?',
      whereArgs: [data['trial_id'], data['session_id']],
      limit: 1,
    );
    if (trials.isEmpty) throw ArgumentError('Unknown summary trial');
    await (await SharedPreferences.getInstance()).setString(
      'neighbor_network_summary_v1',
      raw,
    );
    return {'stored': true};
  }

  Future<Map<String, dynamic>> _configureSession(
    Map<String, dynamic> args,
  ) async {
    final mode = _forwardingMode(_requiredString(args, 'mode'));
    final mainExperiment = args['main_experiment'] != false;
    if ((mode == ForwardingMode.trickleNeighborStatus ||
            mode == ForwardingMode.trickleMpl) &&
        args['transport_profile'] != NeighborRuntime.profile) {
      throw ArgumentError('Neighbor mode requires neighbor_graph_v1');
    }
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
    if (args.containsKey('radio_mode')) {
      final radio = await NativeBridgeService.configureBleRadio(
        _requiredString(args, 'radio_mode'),
      );
      if (radio['ready'] != true) {
        throw StateError('RADIO_NOT_READY: ${radio['last_error']}');
      }
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
    await NeighborRuntime.instance.configure(args);
    await NativeBridgeService.setResearchRxBurstGapMs(
      session.rxBurstGapMs ?? MeshConfig.defaultRxBurstGap.inMilliseconds,
    );
    final radio = (await NativeBridgeService.getBleCapabilities())['radio'];
    if (radio is Map) {
      await _logger.logEvent(
        eventType: 'RADIO_CONFIGURED',
        deviceId: session.deviceId,
        detail: Map<String, dynamic>.from(radio),
      );
    }
    return {
      'session_id': session.sessionId,
      'mode': session.forwardingMode,
      'role': session.nodeRole,
      'gateway_enabled': session.gatewayEnabled,
      'ack_enabled': session.ackEnabled,
      'main_experiment': mainExperiment,
    };
  }

  Future<Map<String, dynamic>> _rangeStatus() async {
    final range = _range;
    await range.refresh();
    final snapshot = await range.snapshot();
    // Logcat final responses are bounded; raw tracks/events belong in the file export.
    final value = <String, dynamic>{
      for (final key in [
        'run',
        'baseline_received',
        'baseline_coded',
        'last_receive',
        'last_position',
        'farthest_observed_m',
      ])
        key: snapshot[key],
      'receive_count': (snapshot['receives'] as List? ?? []).length,
      'point_count': (snapshot['points'] as List? ?? []).length,
      'position_count': (snapshot['positions'] as List? ?? []).length,
      'diagnostic_count': (snapshot['diagnostics'] as List? ?? []).length,
    };
    value['unfinished_trials'] = await (await _db).query(
      'experiment_trials',
      columns: ['trial_id', 'session_id', 'status', 'result'],
      where: "status IN ('RUNNING','WINDOW_ENDED') AND finalized_at IS NULL",
      limit: 5,
    );
    final trialId = (snapshot['run'] as Map?)?['trial_id'];
    final trials = trialId == null
        ? <Map<String, Object?>>[]
        : await (await _db).query(
            'experiment_trials',
            columns: ['trial_id', 'status', 'result', 'finalized_at'],
            where: 'trial_id = ?',
            whereArgs: [trialId],
            limit: 1,
          );
    value['protocol_trial'] = trials.isEmpty ? null : trials.first;
    return value;
  }

  Future<Map<String, dynamic>> _startTrial(Map<String, dynamic> args) async {
    _requireValidProtocolEpoch();
    final trial = await _sessions.startTrial(
      sessionId: _requiredString(args, 'session_id'),
      trialId: _requiredString(args, 'trial_id'),
      trialCode: _requiredString(args, 'trial_code'),
      commandId: _requiredString(args, 'command_id'),
    );
    final session = await _sessions.currentSession();
    await NeighborRuntime.instance.startTrial(trial.trialId);
    if (NeighborRuntime.instance.configuration != null) {
      final participation = await NativeBridgeService.setResearchParticipation(
        true,
        rxOnly: false,
      );
      if (participation['ok'] != true) {
        throw StateError('Trial participation could not be restored');
      }
    }
    await NativeBridgeService.configureResearchPhyTelemetry({
      'sessionId': trial.sessionId,
      'trialId': trial.trialId,
      'nodeId': session?.deviceId,
      'mode': session?.forwardingMode,
      'clockOffsetMs': session?.clockOffsetMs,
      'until':
          _clock.wallTimeMs() + (session?.observationWindowMs ?? 60000) + 60000,
    });
    _startObservationWindow();
    if (NeighborRuntime.instance.statusEnabled) {
      await BleAdvertiserService().advertiseLatestOrStop();
    }
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
    final now =
        _optionalInt(args['observation_ended_at_ms']) ?? _clock.wallTimeMs();
    final db = await _db;
    await _stopObservationWindow();
    await NativeBridgeService.configureResearchPhyTelemetry({'until': 0});
    await _logger.logEvent(
      eventType: ExperimentEventTypes.trialWindowEnded,
      deviceId: SyncService().deviceId,
      eventTimestampMs: now,
      eventKey: 'TRIAL_WINDOW_ENDED|$trialId',
    );
    final changed = await db.update(
      'experiment_trials',
      {'status': 'WINDOW_ENDED', 'observation_ended_at': now},
      where: 'trial_id = ? AND status = ?',
      whereArgs: [trialId, 'RUNNING'],
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
    await _stopObservationWindow();
    final neighborProfile = NeighborRuntime.instance.configuration != null;
    await NeighborRuntime.instance.endTrial();
    await BleAdvertiserService().stopAdvertising();
    final db = await _db;
    if (neighborProfile) {
      await db.update(
        'experiment_trials',
        {
          'status': 'INVALID',
          'result': 'INVALID',
          'failure_reason': 'RESET_WITHOUT_FINAL_RESULT',
          'ended_at': _clock.wallTimeMs(),
          'finalized_at': _clock.wallTimeMs(),
        },
        where: 'trial_id = ? AND finalized_at IS NULL',
        whereArgs: [trialId],
      );
    }
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
    final sourceStarts =
        session == null || trial == null || session.nodeRole != 'SOURCE'
        ? <Map<String, Object?>>[]
        : await db.query(
            'experiment_events',
            columns: ['event_timestamp_ms', 'message_key'],
            where: 'session_id = ? AND trial_id = ? AND event_type = ?',
            whereArgs: [
              session.sessionId,
              trial.trialId,
              ExperimentEventTypes.sourceFirstAdvertiseStarted,
            ],
            orderBy: 'event_timestamp_ms ASC',
            limit: 1,
          );
    final queueCount =
        Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM relay_queue'),
        ) ??
        0;
    final epoch = ProtocolEpochReadiness.at(_clock.wallTimeMs());
    final radio = capabilities['radio'];
    await NeighborRuntime.instance.load();
    return {
      'ok': radio is! Map || radio['ready'] == true,
      'node_id': session?.deviceId,
      'android_build_id': MeshConfig.buildId,
      'build_id': MeshConfig.buildId,
      'protocol_version': MeshConfig.protocolVersion,
      'payload_length': MeshConfig.protocolLength,
      'transport_profile': NeighborRuntime.instance.configuration != null
          ? NeighborRuntime.profile
          : 'legacy',
      'transport_version': NeighborRuntime.instance.configuration != null
          ? 'resqmesh-neighbor-v1'
          : MeshConfig.protocolVersion,
      'data_frame_length': NeighborRuntime.instance.configuration != null
          ? 39
          : 17,
      'neighbor_design_version': 1,
      'supported_scheduler_semantics': ['resqmesh-trickle-mpl-v1'],
      if (NeighborRuntime.instance.configuration?['scheduler_semantics'] !=
          null) ...{
        'scheduler_semantics':
            NeighborRuntime.instance.configuration!['scheduler_semantics'],
        'buffer_retention': 'persistent_until_supersession_ack_admin',
        'mpl_parameters': {
          for (final e in NeighborRuntime.instance.configuration!.entries.where(
            (e) => e.key.startsWith('mpl_'),
          ))
            e.key: e.value,
        },
      },
      if (NeighborRuntime.instance.configuration != null) ...{
        'transmitter_id': NeighborRuntime.instance.transmitter,
        'scope': NeighborRuntime.instance.enabled
            ? NeighborRuntime.instance.scope
            : null,
        'allowed_transmitters':
            NeighborRuntime.instance.configuration!['allowed_transmitters'],
        'neighbor_parameters': NeighborParameters.fromMap(
          NeighborRuntime.instance.configuration!,
        ).toMap(),
      },
      'measurement_timing_version': 2,
      'method_design_version': 3,
      'supported_modes': ForwardingMode.values
          .map((mode) => mode.logValue)
          .toList(),
      'suppression_enabled': [
        'trickle',
        'trickle_mpl',
      ].contains(session?.forwardingMode),
      'trickle_imin_ms': MeshConfig.trickleIminMs,
      'trickle_imax_ms': MeshConfig.trickleImaxMs,
      'trickle_k': MeshConfig.trickleRedundancyConstant,
      'burst_duration_ms': MeshConfig.sosAdvertiseBurstDuration.inMilliseconds,
      'manufacturer_id': MeshConfig.manufacturerId,
      'radio': capabilities['radio'],
      'clock_valid': epoch.isValid,
      'bluetooth': capabilities['bluetoothEnabled'],
      'permissions': {
        'scan': capabilities['scanPermission'],
        'advertise': capabilities['advertisePermission'],
      },
      'scanner': capabilities['nativeScanActive'],
      'advertiser': capabilities['nativeAdvertisingActive'],
      'advertising': capabilities['nativeAdvertisingActive'],
      'mode': session?.forwardingMode,
      'session_id': session?.sessionId,
      'trial_id': trial?.trialId,
      'source_first_advertise_started_at_ms': sourceStarts.isEmpty
          ? null
          : sourceStarts.first['event_timestamp_ms'],
      'source_first_advertise_message_key': sourceStarts.isEmpty
          ? null
          : sourceStarts.first['message_key'],
      'role': session?.nodeRole,
      'protocol_active': session?.protocolActive,
      'rx_burst_gap_ms':
          session?.rxBurstGapMs ?? MeshConfig.defaultRxBurstGap.inMilliseconds,
      'expected_hop_in': session?.expectedHopIn,
      'hop_out': session?.hopOut,
      'gateway_enabled': session?.gatewayEnabled ?? false,
      'ack_enabled': session?.ackEnabled ?? false,
      'queue_size': queueCount,
      'packet_pending': queueCount > 0,
      'quiet_period_complete':
          queueCount == 0 && capabilities['nativeAdvertisingActive'] != true,
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
      'trickle_no_suppression' => ForwardingMode.trickleNoSuppression,
      'trickle_neighbor_status' => ForwardingMode.trickleNeighborStatus,
      'trickle_mpl' => ForwardingMode.trickleMpl,
      'basic' || 'basic_flooding' => ForwardingMode.basicFlooding,
      _ => throw ArgumentError('INVALID_FORWARDING_MODE: $value'),
    };
  }
}
