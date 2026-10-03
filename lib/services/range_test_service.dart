import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:geolocator/geolocator.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import 'database_helper.dart';
import 'experiment_clock.dart';
import 'native_bridge_service.dart';

typedef RangeTelemetryReader = Future<Map<String, dynamic>> Function();

class RangeFix {
  const RangeFix(
    this.timestampMs,
    this.latitude,
    this.longitude,
    this.accuracy,
  );
  final int timestampMs;
  final double latitude;
  final double longitude;
  final double accuracy;

  bool usableAt(int at) =>
      validCoordinate(latitude, longitude) &&
      accuracy.isFinite &&
      accuracy >= 0 &&
      accuracy <= 20 &&
      (timestampMs - at).abs() <= 5000;

  Map<String, Object> toJson() => {
    'timestamp_ms': timestampMs,
    'latitude': latitude,
    'longitude': longitude,
    'accuracy_m': accuracy,
  };

  factory RangeFix.fromJson(Map<String, dynamic> value) => RangeFix(
    (value['timestamp_ms'] as num).toInt(),
    (value['latitude'] as num).toDouble(),
    (value['longitude'] as num).toDouble(),
    (value['accuracy_m'] as num).toDouble(),
  );

  static bool validCoordinate(double lat, double lon) =>
      lat.isFinite &&
      lon.isFinite &&
      lat >= -90 &&
      lat <= 90 &&
      lon >= -180 &&
      lon <= 180;

  static RangeFix? nearest(Iterable<RangeFix> fixes, int at) {
    RangeFix? best;
    for (final fix in fixes) {
      if (fix.usableAt(at) &&
          (best == null ||
              (fix.timestampMs - at).abs() < (best.timestampMs - at).abs())) {
        best = fix;
      }
    }
    return best;
  }
}

/// Pilot storage never owns the BLE scheduler or writes protocol state.
class RangeTestService {
  RangeTestService({
    Database? storage,
    Database? protocol,
    ClockSource? clock,
    RangeTelemetryReader? telemetry,
    Future<void> Function(String, int)? enableTelemetry,
    this.observePoints = true,
  }) : _storage = storage,
       _protocol = protocol,
       clock = clock ?? ExperimentClock.instance,
       _telemetry = telemetry ?? NativeBridgeService.getRangeRxTelemetry,
       _enableTelemetry =
           enableTelemetry ?? NativeBridgeService.configureRangeTelemetry;

  static const durationMs = 20 * 60 * 1000;
  static const pointDurationMs = 60000;
  static const schema = [
    'CREATE TABLE IF NOT EXISTS range_runs (run_id TEXT PRIMARY KEY, created_at INTEGER NOT NULL, cursor INTEGER NOT NULL DEFAULT 0, data TEXT NOT NULL)',
    'CREATE TABLE IF NOT EXISTS range_positions (id INTEGER PRIMARY KEY AUTOINCREMENT, run_id TEXT NOT NULL, timestamp_ms INTEGER NOT NULL, data TEXT NOT NULL)',
    'CREATE TABLE IF NOT EXISTS range_receives (run_id TEXT NOT NULL, event_id INTEGER NOT NULL, observation_id TEXT, data TEXT NOT NULL, PRIMARY KEY(run_id,event_id), UNIQUE(run_id,observation_id))',
    'CREATE TABLE IF NOT EXISTS range_points (point_id TEXT PRIMARY KEY, run_id TEXT NOT NULL, data TEXT NOT NULL)',
    'CREATE TABLE IF NOT EXISTS range_diagnostics (id INTEGER PRIMARY KEY AUTOINCREMENT, run_id TEXT NOT NULL, timestamp_ms INTEGER NOT NULL, data TEXT NOT NULL)',
  ];
  Database? _storage;
  final Database? _protocol;
  final ClockSource clock;
  // Only the foreground UI owns its isolate-local monotonic point timer.
  final bool observePoints;
  final RangeTelemetryReader _telemetry;
  final Future<void> Function(String, int) _enableTelemetry;
  bool _refreshing = false;

  Future<Database> get store async {
    return _storage ??= await openDatabase(
      p.join(await getDatabasesPath(), 'resqmesh_range_pilot.db'),
      version: 1,
      onCreate: (db, _) async {
        for (final sql in schema) {
          await db.execute(sql);
        }
      },
    );
  }

  Future<Database> get protocol async =>
      _protocol ?? await DatabaseHelper().database;
  Map<String, dynamic> _decode(Map<String, Object?> row) =>
      Map<String, dynamic>.from(jsonDecode(row['data'] as String) as Map);

  Future<Map<String, dynamic>?> latest() async {
    final rows = await (await store).query(
      'range_runs',
      orderBy: 'created_at DESC',
      limit: 1,
    );
    return rows.isEmpty ? null : _decode(rows.first);
  }

  Future<void> _saveRun(Map<String, dynamic> run) async {
    await (await store).update(
      'range_runs',
      {'data': jsonEncode(run)},
      where: 'run_id = ?',
      whereArgs: [run['run_id']],
    );
  }

  Future<Map<String, dynamic>> configure(Map<String, dynamic> args) async {
    final runId = args['run_id']?.toString() ?? '';
    if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(runId)) {
      throw ArgumentError('MISSING_run_id');
    }
    final existing = await (await store).query(
      'range_runs',
      where: 'run_id = ?',
      whereArgs: [runId],
    );
    if (args['action'] != null &&
        !const ['start', 'finish'].contains(args['action'])) {
      throw ArgumentError('INVALID_RANGE_ACTION');
    }
    if (args['action'] != null &&
        existing.isNotEmpty &&
        (await latest())?['run_id'] != runId) {
      throw StateError('RANGE_NOT_CURRENT');
    }
    if (args['action'] == 'start') {
      if (existing.isEmpty) {
        throw StateError('RANGE_NOT_PREPARED');
      }
      final run = _decode(existing.first);
      if (run['status'] != 'prepared') {
        return run;
      }
      final status = await snapshot();
      if (run['source_latitude'] == null ||
          status['baseline_received'] != true ||
          status['baseline_coded'] != true) {
        throw StateError('SOURCE_POSITION_OR_CODED_BASELINE_MISSING');
      }
      run['status'] = 'running';
      run['started_at_ms'] = clock.wallTimeMs();
      run['ends_at_ms'] = clock.wallTimeMs() + durationMs;
      await _enableTelemetry(runId, run['ends_at_ms'] as int);
      await _saveRun(run);
      return run;
    }
    if (args['action'] == 'finish') {
      if (existing.isEmpty) {
        throw StateError('RANGE_NOT_PREPARED');
      }
      await refresh();
      await cancelPoint('COLLECTION_STARTED');
      final run = _decode(
        (await (await store).query(
          'range_runs',
          where: 'run_id = ?',
          whereArgs: [runId],
        )).first,
      );
      run['status'] = 'finished';
      await _saveRun(run);
      await _enableTelemetry(runId, clock.wallTimeMs());
      return run;
    }
    if (existing.isNotEmpty) {
      return _decode(existing.first);
    }
    final previous = await latest();
    if (previous != null &&
        const ['prepared', 'running'].contains(previous['status'])) {
      throw StateError('RANGE_PILOT_STILL_ACTIVE');
    }
    final db = await protocol;
    final sessionId = args['session_id']?.toString();
    final trialId = args['trial_id']?.toString();
    final sessions = await db.query(
      'experiment_sessions',
      where: 'session_id = ?',
      whereArgs: [sessionId],
    );
    final trials = await db.query(
      'experiment_trials',
      where: 'trial_id = ? AND session_id = ? AND status = ?',
      whereArgs: [trialId, sessionId, 'RUNNING'],
    );
    if (sessions.isEmpty ||
        trials.isEmpty ||
        sessions.first['node_role'] != 'DESTINATION' ||
        sessions.first['forwarding_mode'] != 'basic_flooding' ||
        sessions.first['ack_enabled'] != 0 ||
        sessions.first['gateway_enabled'] != 0 ||
        sessions.first['expected_hop_in'] != 1) {
      throw StateError('RANGE_REQUIRES_BASIC_H1_DESTINATION_TRIAL');
    }
    final crc = (args['source_sender_crc'] as num?)?.toInt();
    final timestamp = (args['source_timestamp_ms'] as num?)?.toInt();
    if (crc == null ||
        crc < 0 ||
        crc > 0xffffffff ||
        timestamp == null ||
        timestamp <= 0) {
      throw ArgumentError('INVALID_SOURCE_IDENTITY');
    }
    final run = <String, dynamic>{
      'run_id': runId,
      'session_id': sessionId,
      'trial_id': trialId,
      'status': 'prepared',
      'created_at_ms': clock.wallTimeMs(),
      'algorithm': 'basic_flooding',
      'direction': 'esp_to_android',
      'source_sender_crc': crc,
      'source_timestamp_ms': timestamp,
      'source_latitude': null,
      'source_longitude': null,
      'source_accuracy_m': null,
      'source_position_method': null,
      'android_build_id': sessions.first['build_id'],
      'coding': 'unknown',
      'point_duration_ms': pointDurationMs,
    };
    await (await store).insert('range_runs', {
      'run_id': runId,
      'created_at': clock.wallTimeMs(),
      'data': jsonEncode(run),
    });
    await _enableTelemetry(runId, clock.wallTimeMs() + durationMs + 600000);
    if (args['source_latitude'] is num && args['source_longitude'] is num) {
      await setSource(
        (args['source_latitude'] as num).toDouble(),
        (args['source_longitude'] as num).toDouble(),
        'manual',
      );
    }
    return (await latest())!;
  }

  Future<void> setSource(
    double lat,
    double lon,
    String method, {
    double? accuracy,
  }) async {
    if (!RangeFix.validCoordinate(lat, lon) ||
        !const ['gps', 'manual', 'map_pin'].contains(method)) {
      throw ArgumentError('INVALID_SOURCE_POSITION');
    }
    if (method == 'gps' &&
        (accuracy == null ||
            !accuracy.isFinite ||
            accuracy < 0 ||
            accuracy > 20)) {
      throw ArgumentError('SOURCE_GPS_INACCURATE');
    }
    final run = await latest();
    if (run == null || run['status'] != 'prepared') {
      throw StateError('SOURCE_POSITION_LOCKED');
    }
    run['source_latitude'] = lat;
    run['source_longitude'] = lon;
    run['source_position_method'] = method;
    run['source_accuracy_m'] = method == 'gps' ? accuracy : null;
    run['source_position_at_ms'] = clock.wallTimeMs();
    await _saveRun(run);
  }

  Future<void> recordFix(RangeFix fix) async {
    if (!RangeFix.validCoordinate(fix.latitude, fix.longitude) ||
        !fix.accuracy.isFinite ||
        fix.accuracy < 0) {
      return;
    }
    final run = await latest();
    if (run == null || !const ['prepared', 'running'].contains(run['status'])) {
      return;
    }
    await (await store).insert('range_positions', {
      'run_id': run['run_id'],
      'timestamp_ms': fix.timestampMs,
      'data': jsonEncode(fix.toJson()),
    });
  }

  Future<List<Map<String, dynamic>>> rows(String table, String runId) async =>
      (await (await store).query(
        table,
        where: 'run_id = ?',
        whereArgs: [runId],
      )).map(_decode).toList();

  static bool matches(Map<String, dynamic> event, Map<String, dynamic> run) =>
      event['event_type'] == 'BLE_PACKET_RECEIVED' &&
      event['session_id'] == run['session_id'] &&
      event['trial_id'] == run['trial_id'] &&
      event['sender_crc'] == run['source_sender_crc'] &&
      event['protocol_timestamp_ms'] == run['source_timestamp_ms'] &&
      event['packet_type'] == 'sos' &&
      event['status'] == 'active' &&
      event['hop_in'] == 1;

  Future<void> refresh() async {
    if (_refreshing) {
      return;
    }
    _refreshing = true;
    try {
      final run = await latest();
      if (run == null) {
        return;
      }
      final db = await store;
      final cursorRow = (await db.query(
        'range_runs',
        columns: ['cursor'],
        where: 'run_id = ?',
        whereArgs: [run['run_id']],
      )).first;
      final protocolDb = await protocol;
      var cursor = cursorRow['cursor'] as int;
      final highWater =
          (await protocolDb.rawQuery(
                'SELECT COALESCE(MAX(id),0) AS last_id FROM experiment_events',
              )).first['last_id']
              as int;
      while (cursor < highWater) {
        final events = await protocolDb.query(
          'experiment_events',
          where: 'session_id = ? AND trial_id = ? AND id > ? AND id <= ?',
          whereArgs: [run['session_id'], run['trial_id'], cursor, highWater],
          orderBy: 'id ASC',
          limit: 500,
        );
        await db.transaction((tx) async {
          for (final event in events) {
            if (!matches(Map<String, dynamic>.from(event), run)) {
              continue;
            }
            final rx = <String, dynamic>{
              'event_id': event['id'],
              'observation_id': event['observation_id'],
              'timestamp_ms':
                  event['event_timestamp_ms'] ?? event['timestamp_ms'],
              'sender_crc': event['sender_crc'],
              'protocol_timestamp_ms': event['protocol_timestamp_ms'],
              'hop_in': event['hop_in'],
              'rssi': event['rssi'],
              'message_key': event['message_key'],
              'packet_type': event['packet_type'],
              'status': event['status'],
              'primary_phy': null,
              'secondary_phy': null,
              'legacy': null,
              'coded_verified': false,
              'distance_m': null,
              'location': null,
            };
            await tx.insert('range_receives', {
              'run_id': run['run_id'],
              'event_id': event['id'],
              'observation_id': event['observation_id'],
              'data': jsonEncode(rx),
            }, conflictAlgorithm: ConflictAlgorithm.ignore);
          }
          if (events.isNotEmpty) {
            await tx.update(
              'range_runs',
              {'cursor': events.last['id']},
              where: 'run_id = ?',
              whereArgs: [run['run_id']],
            );
          }
        });
        if (events.length < 500) {
          break;
        }
        cursor = events.last['id'] as int;
      }
      Map<String, dynamic> telemetry = {};
      try {
        telemetry = await _telemetry();
      } catch (error) {
        await diagnostic('PHY_TELEMETRY_UNAVAILABLE', error.toString());
      }
      final phy = <String, Map<String, dynamic>>{};
      if (telemetry['run_id'] == run['run_id']) {
        for (final value in (telemetry['samples'] as List? ?? [])) {
          final entry = Map<String, dynamic>.from(value as Map);
          phy[entry['observation_id'].toString()] = entry;
        }
      }
      final fixes = (await rows(
        'range_positions',
        run['run_id'] as String,
      )).map(RangeFix.fromJson).toList();
      for (final row in await db.query(
        'range_receives',
        where: 'run_id = ?',
        whereArgs: [run['run_id']],
      )) {
        final rx = _decode(row);
        final original = jsonEncode(rx);
        final radio = phy[rx['observation_id']];
        if (radio != null) {
          rx['telemetry_received_at_ms'] = radio['received_at'];
          rx['primary_phy'] = radio['primary_phy'];
          rx['secondary_phy'] = radio['secondary_phy'];
          rx['legacy'] = radio['legacy'];
          rx['coded_verified'] =
              radio['primary_phy'] == 3 &&
              radio['secondary_phy'] == 3 &&
              radio['legacy'] == false;
        }
        final fix = RangeFix.nearest(
          fixes,
          (rx['timestamp_ms'] as num).toInt(),
        );
        if (fix != null && run['source_latitude'] != null) {
          rx['location'] = fix.toJson();
          rx['distance_m'] = Geolocator.distanceBetween(
            (run['source_latitude'] as num).toDouble(),
            (run['source_longitude'] as num).toDouble(),
            fix.latitude,
            fix.longitude,
          );
        }
        if (jsonEncode(rx) != original) {
          await db.update(
            'range_receives',
            {'data': jsonEncode(rx)},
            where: 'run_id = ? AND event_id = ?',
            whereArgs: [run['run_id'], row['event_id']],
          );
        }
      }
      if (observePoints) await _tickPoint(run);
      if (run['status'] == 'running' &&
          clock.wallTimeMs() >= (run['ends_at_ms'] as int)) {
        run['status'] = 'finished';
        await _saveRun(run);
      }
      if (run['status'] == 'prepared' &&
          clock.wallTimeMs() - (run['created_at_ms'] as int) > 600000) {
        run['status'] = 'interrupted';
        await _saveRun(run);
        await diagnostic('PREPARATION_TIMEOUT', 'Persiapan melebihi 10 menit');
      }
    } finally {
      _refreshing = false;
    }
  }

  Future<void> diagnostic(String code, String detail) async {
    final run = await latest();
    if (run == null) {
      return;
    }
    final prior = await rows('range_diagnostics', run['run_id'] as String);
    if (prior.isNotEmpty &&
        prior.last['code'] == code &&
        clock.wallTimeMs() - (prior.last['timestamp_ms'] as int) < 10000) {
      return;
    }
    await (await store).insert('range_diagnostics', {
      'run_id': run['run_id'],
      'timestamp_ms': clock.wallTimeMs(),
      'data': jsonEncode({
        'timestamp_ms': clock.wallTimeMs(),
        'code': code,
        'detail': detail,
      }),
    });
  }

  Future<void> startPoint({required bool scannerActive}) async {
    final run = await latest();
    if (run == null ||
        run['status'] != 'running' ||
        !scannerActive ||
        run['source_latitude'] == null ||
        (run['ends_at_ms'] as int) - clock.wallTimeMs() < pointDurationMs) {
      throw StateError('POINT_NOT_READY_OR_SESSION_ENDING');
    }
    if ((await rows(
      'range_points',
      run['run_id'] as String,
    )).any((v) => v['status'] == 'running')) {
      throw StateError('POINT_ALREADY_RUNNING');
    }
    final point = <String, dynamic>{
      'point_id': const Uuid().v4(),
      'started_at_ms': clock.wallTimeMs(),
      'planned_end_ms': clock.wallTimeMs() + pointDurationMs,
      'status': 'running',
      'monotonic_start_ms': clock.monotonicTimeMs(),
      'monotonic_domain': clock.monotonicDomainId,
    };
    await (await store).insert('range_points', {
      'point_id': point['point_id'],
      'run_id': run['run_id'],
      'data': jsonEncode(point),
    });
  }

  Future<void> _tickPoint(Map<String, dynamic> run) async {
    for (final point in await rows('range_points', run['run_id'] as String)) {
      if (point['status'] != 'running') {
        continue;
      }
      if (point['monotonic_domain'] != clock.monotonicDomainId) {
        await cancelPoint('APP_RESTARTED');
        return;
      }
      final elapsed =
          clock.monotonicTimeMs() - (point['monotonic_start_ms'] as int);
      if ((clock.wallTimeMs() - (point['started_at_ms'] as int) - elapsed)
              .abs() >
          2000) {
        await cancelPoint('CLOCK_CHANGED');
        return;
      }
      if (elapsed < pointDurationMs) {
        continue;
      }
      point['status'] = 'completed';
      point['ended_at_ms'] = point['planned_end_ms'];
      await (await store).update(
        'range_points',
        {'data': jsonEncode(point)},
        where: 'point_id = ?',
        whereArgs: [point['point_id']],
      );
    }
  }

  Future<void> cancelPoint(String reason) async {
    final run = await latest();
    if (run == null) {
      return;
    }
    var cancelled = false;
    for (final point in await rows('range_points', run['run_id'] as String)) {
      if (point['status'] != 'running') {
        continue;
      }
      point['status'] = 'invalid';
      point['ended_at_ms'] = clock.wallTimeMs();
      point['reason'] = reason;
      cancelled = true;
      await (await store).update(
        'range_points',
        {'data': jsonEncode(point)},
        where: 'point_id = ?',
        whereArgs: [point['point_id']],
      );
    }
    if (cancelled) await diagnostic(reason, 'Pengamatan titik dibatalkan');
  }

  Future<Map<String, dynamic>> snapshot() async {
    final run = await latest();
    if (run == null) {
      return {'run': null};
    }
    final id = run['run_id'] as String;
    final rx = await rows('range_receives', id);
    for (final sample in rx) {
      final time = sample['timestamp_ms'] as int;
      sample['phase'] =
          run['started_at_ms'] == null || time < (run['started_at_ms'] as int)
          ? 'baseline'
          : time >= (run['ends_at_ms'] as int)
          ? 'after_session'
          : 'session';
      sample['location_quality'] = sample['location'] == null
          ? 'unavailable_or_inaccurate'
          : 'usable_hp_fix';
      sample['location_time_delta_ms'] = sample['location'] == null
          ? null
          : ((sample['location'] as Map)['timestamp_ms'] as int) - time;
    }
    rx.sort(
      (a, b) => (a['timestamp_ms'] as int).compareTo(b['timestamp_ms'] as int),
    );
    final points = await rows('range_points', id);
    for (final point in points) {
      final end = point['ended_at_ms'] ?? clock.wallTimeMs();
      final receives = rx
          .where(
            (v) =>
                (v['timestamp_ms'] as int) >= (point['started_at_ms'] as int) &&
                (v['timestamp_ms'] as int) < (end as int),
          )
          .toList();
      point['receive_count'] = receives.length;
      point['receive_result'] = receives.isEmpty
          ? 'no_receive_observed'
          : 'received';
      final distances = receives
          .map((v) => v['distance_m'])
          .whereType<num>()
          .toList();
      point['farthest_observed_m'] = distances.isEmpty
          ? null
          : distances.reduce(math.max);
    }
    final positions = await rows('range_positions', id);
    final distances = rx
        .where((v) => v['phase'] == 'session')
        .map((v) => v['distance_m'])
        .whereType<num>()
        .toList();
    return {
      'run': run,
      'points': points,
      'receives': rx,
      'positions': positions,
      'diagnostics': await rows('range_diagnostics', id),
      'baseline_received': rx.isNotEmpty,
      'baseline_coded': rx.any((v) => v['coded_verified'] == true),
      'last_receive': rx.isEmpty ? null : rx.last,
      'last_position': positions.isEmpty ? null : positions.last,
      'farthest_observed_m': distances.isEmpty
          ? null
          : distances.reduce(math.max),
    };
  }

  Future<Map<String, dynamic>> export({Directory? directory}) async {
    await refresh();
    final data = await snapshot();
    final run = data['run'] as Map<String, dynamic>?;
    if (run == null) {
      throw StateError('NO_RANGE_PILOT');
    }
    final dir = directory ?? await getApplicationDocumentsDirectory();
    final file = File(p.join(dir.path, 'range_${run['run_id']}.json'));
    await file.writeAsString(const JsonEncoder.withIndent('  ').convert(data));
    return {'run_id': run['run_id'], 'json_path': file.path};
  }
}
