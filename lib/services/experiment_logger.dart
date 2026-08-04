import 'dart:convert';

import 'package:pkmproject/config/mesh_config.dart';
import 'package:pkmproject/models/experiment_event.dart';
import 'package:pkmproject/models/experiment_session.dart';
import 'package:pkmproject/services/database_helper.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

class ExperimentEventTypes {
  static const sosCreated = 'SOS_CREATED';
  static const bleAdvertiseRequested = 'BLE_ADVERTISE_REQUESTED';
  static const bleAdvertiseStarted = 'BLE_ADVERTISE_STARTED';
  static const bleAdvertiseFailed = 'BLE_ADVERTISE_FAILED';
  static const blePacketReceived = 'BLE_PACKET_RECEIVED';
  static const blePacketStored = 'BLE_PACKET_STORED';
  static const blePacketDuplicate = 'BLE_PACKET_DUPLICATE';
  static const bleRelayQueued = 'BLE_RELAY_QUEUED';
  static const bleRelayStarted = 'BLE_RELAY_STARTED';
  static const bleRelayDropped = 'BLE_RELAY_DROPPED';
  static const messageExpired = 'MESSAGE_EXPIRED';
  static const ackReceived = 'ACK_RECEIVED';
  static const ackAccepted = 'ACK_ACCEPTED';
  static const gatewayDetected = 'GATEWAY_DETECTED';
  static const gatewayUploadStarted = 'GATEWAY_UPLOAD_STARTED';
  static const gatewayUploadSucceeded = 'GATEWAY_UPLOAD_SUCCEEDED';
  static const gatewayUploadFailed = 'GATEWAY_UPLOAD_FAILED';
  static const serviceStarted = 'SERVICE_STARTED';
  static const serviceStopped = 'SERVICE_STOPPED';
  static const relayStateRecovered = 'RELAY_STATE_RECOVERED';
}

class ExperimentLogger {
  ExperimentLogger({Database? database, DatabaseHelper? databaseHelper})
    : _database = database,
      _databaseHelper = databaseHelper ?? DatabaseHelper();

  final Database? _database;
  final DatabaseHelper _databaseHelper;

  ExperimentSession? _currentSession;

  Future<Database> get _db async => _database ?? _databaseHelper.database;

  Future<ExperimentSession> ensureSession({
    required String deviceId,
    String deviceModel = 'unknown',
    String androidVersion = 'unknown',
  }) async {
    if (_currentSession != null && _currentSession!.endedAt == null) {
      return _currentSession!;
    }

    final db = await _db;
    final rows = await db.query(
      'experiment_sessions',
      where: 'ended_at IS NULL',
      orderBy: 'started_at DESC',
      limit: 1,
    );
    if (rows.isNotEmpty) {
      _currentSession = ExperimentSession.fromDbMap(rows.first);
      return _currentSession!;
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    final session = ExperimentSession(
      sessionId: const Uuid().v4(),
      deviceId: deviceId,
      deviceModel: deviceModel,
      androidVersion: androidVersion,
      forwardingMode: MeshConfig.forwardingMode.name,
      maxHop: MeshConfig.defaultMaxHop,
      messageLifetimeMs: MeshConfig.defaultMessageLifetime.inMilliseconds,
      relayCooldownMs: MeshConfig.relayCooldown.inMilliseconds,
      startedAt: now,
    );
    await db.insert('experiment_sessions', session.toDbMap());
    _currentSession = session;
    return session;
  }

  Future<ExperimentSession?> currentSession() async {
    if (_currentSession != null) return _currentSession;
    final db = await _db;
    final rows = await db.query(
      'experiment_sessions',
      orderBy: 'started_at DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    _currentSession = ExperimentSession.fromDbMap(rows.first);
    return _currentSession;
  }

  Future<void> endCurrentSession() async {
    final session = await currentSession();
    if (session == null || session.endedAt != null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final db = await _db;
    await db.update(
      'experiment_sessions',
      {'ended_at': now},
      where: 'session_id = ?',
      whereArgs: [session.sessionId],
    );
    _currentSession = null;
  }

  Future<void> logEvent({
    required String eventType,
    required String deviceId,
    String? messageId,
    int? senderCrc,
    int? hopCount,
    int? rssi,
    String? payloadHash,
    Map<String, dynamic>? detail,
  }) async {
    final session = await ensureSession(deviceId: deviceId);
    final event = ExperimentEvent(
      sessionId: session.sessionId,
      eventType: eventType,
      messageId: messageId,
      senderCrc: senderCrc,
      timestampMs: DateTime.now().millisecondsSinceEpoch,
      hopCount: hopCount,
      rssi: rssi,
      payloadHash: payloadHash,
      detailJson: detail == null ? null : jsonEncode(detail),
    );
    final db = await _db;
    await db.insert('experiment_events', event.toDbMap());
  }

  Future<int> eventCount({String? sessionId}) async {
    final db = await _db;
    final rows = sessionId == null
        ? await db.rawQuery('SELECT COUNT(*) AS count FROM experiment_events')
        : await db.rawQuery(
            'SELECT COUNT(*) AS count FROM experiment_events WHERE session_id = ?',
            [sessionId],
          );
    return rows.first['count'] as int? ?? 0;
  }

  Future<List<ExperimentEvent>> events({String? sessionId}) async {
    final db = await _db;
    final rows = await db.query(
      'experiment_events',
      where: sessionId == null ? null : 'session_id = ?',
      whereArgs: sessionId == null ? null : [sessionId],
      orderBy: 'timestamp_ms ASC, id ASC',
    );
    return rows.map(ExperimentEvent.fromDbMap).toList();
  }
}
