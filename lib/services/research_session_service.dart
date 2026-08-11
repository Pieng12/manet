import 'package:pkmproject/config/mesh_config.dart';
import 'package:pkmproject/models/experiment_session.dart';
import 'package:pkmproject/models/experiment_trial.dart';
import 'package:pkmproject/services/database_helper.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

class ResearchSessionService {
  ResearchSessionService({Database? database, DatabaseHelper? databaseHelper})
    : _database = database,
      _databaseHelper = databaseHelper ?? DatabaseHelper();

  final Database? _database;
  final DatabaseHelper _databaseHelper;

  Future<Database> get _db async => _database ?? _databaseHelper.database;

  Future<ExperimentSession> startSession({
    required String deviceId,
    required String name,
    required String nodeRole,
    required int targetHop,
    required String topologyLabel,
    required String scenarioLabel,
    String? notes,
    int? trialTimeoutSeconds,
    String deviceModel = 'unknown',
    String androidVersion = 'unknown',
    String appVersion = 'research',
    String? deviceManufacturer,
    int? androidSdk,
    String? appVersionCode,
    String? buildId,
  }) async {
    final db = await _db;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.update(
      'experiment_sessions',
      {'ended_at': now, 'status': 'COMPLETED'},
      where: 'session_kind = ? AND ended_at IS NULL',
      whereArgs: const ['RESEARCH'],
    );
    final session = ExperimentSession(
      sessionId: const Uuid().v4(),
      deviceId: deviceId,
      deviceModel: deviceModel,
      androidVersion: androidVersion,
      forwardingMode: MeshConfig.forwardingMode.logValue,
      maxHop: MeshConfig.legacyHopMetadata,
      messageLifetimeMs: MeshConfig.defaultMessageLifetime.inMilliseconds,
      relayCooldownMs: MeshConfig.relayCooldown.inMilliseconds,
      startedAt: now,
      name: name.trim().isEmpty ? _defaultSessionName(now) : name.trim(),
      nodeRole: nodeRole,
      targetHop: targetHop,
      topologyLabel: topologyLabel.trim(),
      scenarioLabel: scenarioLabel.trim(),
      notes: notes?.trim(),
      status: 'RUNNING',
      appVersion: appVersion,
      trialTimeoutSeconds: trialTimeoutSeconds,
      sessionKind: 'RESEARCH',
      deviceManufacturer: deviceManufacturer,
      androidSdk: androidSdk,
      appVersionCode: appVersionCode,
      buildId: buildId ?? MeshConfig.buildId,
    );
    await db.insert('experiment_sessions', session.toDbMap());
    return session;
  }

  Future<ExperimentSession?> currentSession() async {
    final db = await _db;
    final rows = await db.query(
      'experiment_sessions',
      where: 'session_kind = ? AND ended_at IS NULL',
      whereArgs: const ['RESEARCH'],
      orderBy: 'started_at DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return ExperimentSession.fromDbMap(rows.first);
  }

  Future<void> endSession(String sessionId) async {
    final db = await _db;
    await db.update(
      'experiment_sessions',
      {
        'ended_at': DateTime.now().millisecondsSinceEpoch,
        'status': 'COMPLETED',
      },
      where: 'session_id = ?',
      whereArgs: [sessionId],
    );
  }

  Future<ExperimentTrial> startTrial({
    required String sessionId,
    String? trialCodePrefix,
    String? notes,
  }) async {
    final db = await _db;
    return db.transaction((txn) async {
      final running = await txn.query(
        'experiment_trials',
        where: 'session_id = ? AND status = ?',
        whereArgs: [sessionId, 'RUNNING'],
        limit: 1,
      );
      if (running.isNotEmpty) {
        throw StateError('A trial is already RUNNING');
      }
      final countRows = await txn.rawQuery(
        'SELECT MAX(trial_number) AS max_trial FROM experiment_trials WHERE session_id = ?',
        [sessionId],
      );
      final nextNumber = (countRows.first['max_trial'] as int? ?? 0) + 1;
      final prefix = (trialCodePrefix == null || trialCodePrefix.trim().isEmpty)
          ? sessionId.substring(0, 8).toUpperCase()
          : trialCodePrefix.trim();
      final trial = ExperimentTrial(
        trialId: const Uuid().v4(),
        sessionId: sessionId,
        trialNumber: nextNumber,
        trialCode: '$prefix-${nextNumber.toString().padLeft(3, '0')}',
        startedAt: DateTime.now().millisecondsSinceEpoch,
        status: 'RUNNING',
        notes: notes?.trim(),
      );
      await txn.insert('experiment_trials', trial.toDbMap());
      return trial;
    });
  }

  Future<ExperimentTrial?> currentTrial({String? sessionId}) async {
    final db = await _db;
    final where = sessionId == null
        ? 'status = ?'
        : 'session_id = ? AND status = ?';
    final whereArgs = sessionId == null
        ? <Object>['RUNNING']
        : <Object>[sessionId, 'RUNNING'];
    final rows = await db.query(
      'experiment_trials',
      where: where,
      whereArgs: whereArgs,
      orderBy: 'started_at DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return ExperimentTrial.fromDbMap(rows.first);
  }

  Future<List<ExperimentTrial>> trialsForSession(String sessionId) async {
    final db = await _db;
    final rows = await db.query(
      'experiment_trials',
      where: 'session_id = ?',
      whereArgs: [sessionId],
      orderBy: 'trial_number ASC',
    );
    return rows.map(ExperimentTrial.fromDbMap).toList();
  }

  Future<void> finishTrial(
    String trialId, {
    String status = 'COMPLETED',
    String? result,
    String? failureReason,
    String? notes,
  }) async {
    final db = await _db;
    await db.update(
      'experiment_trials',
      {
        'ended_at': DateTime.now().millisecondsSinceEpoch,
        'status': status,
        'result': result,
        'failure_reason': failureReason,
        'notes': notes,
      },
      where: 'trial_id = ?',
      whereArgs: [trialId],
    );
  }

  Future<int> applyTimeoutIfNeeded({String? sessionId, int? nowMs}) async {
    final db = await _db;
    final sessions = await db.query(
      'experiment_sessions',
      where: sessionId == null
          ? 'session_kind = ? AND ended_at IS NULL AND trial_timeout_seconds IS NOT NULL'
          : 'session_id = ? AND trial_timeout_seconds IS NOT NULL',
      whereArgs: sessionId == null ? const ['RESEARCH'] : [sessionId],
    );
    var updated = 0;
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    for (final row in sessions) {
      final session = ExperimentSession.fromDbMap(row);
      final timeout = session.trialTimeoutSeconds;
      if (timeout == null || timeout <= 0) continue;
      final trials = await db.query(
        'experiment_trials',
        where: 'session_id = ? AND status = ?',
        whereArgs: [session.sessionId, 'RUNNING'],
      );
      for (final trialRow in trials) {
        final trial = ExperimentTrial.fromDbMap(trialRow);
        if (now - trial.startedAt < timeout * 1000) continue;
        updated += await db.update(
          'experiment_trials',
          {
            'ended_at': now,
            'status': 'COMPLETED',
            'result': 'FAILED',
            'failure_reason': 'TIMEOUT',
          },
          where: 'trial_id = ? AND status = ?',
          whereArgs: [trial.trialId, 'RUNNING'],
        );
      }
    }
    return updated;
  }

  Future<ExperimentSession?> sessionById(String sessionId) async {
    final db = await _db;
    final rows = await db.query(
      'experiment_sessions',
      where: 'session_id = ?',
      whereArgs: [sessionId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return ExperimentSession.fromDbMap(rows.first);
  }

  Future<void> invalidateTrial(String trialId, {String? notes}) {
    return finishTrial(
      trialId,
      status: 'INVALID',
      result: 'INVALID',
      failureReason: 'USER_ERROR',
      notes: notes,
    );
  }

  static String _defaultSessionName(int nowMs) {
    final date = DateTime.fromMillisecondsSinceEpoch(nowMs);
    final y = date.year.toString().padLeft(4, '0');
    final m = date.month.toString().padLeft(2, '0');
    final d = date.day.toString().padLeft(2, '0');
    return 'EXP-$y-$m-$d';
  }
}
