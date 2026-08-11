import 'package:flutter_test/flutter_test.dart';
import 'package:pkmproject/database_schema.dart';
import 'package:pkmproject/services/experiment_logger.dart';
import 'package:pkmproject/services/research_session_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Database db;
  late ResearchSessionService research;
  late ExperimentLogger logger;

  setUp(() async {
    sqfliteFfiInit();
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await db.execute(createExperimentSessionsTableSql);
    await db.execute(createExperimentTrialsTableSql);
    await db.execute(createExperimentEventsTableSql);
    research = ResearchSessionService(database: db);
    logger = ExperimentLogger(database: db);
  });

  tearDown(() async {
    await db.close();
  });

  test('create session and current session stores research metadata', () async {
    final session = await research.startSession(
      deviceId: 'device-a',
      name: 'CEF-H3',
      nodeRole: 'RELAY',
      targetHop: 3,
      topologyLabel: 'A -> R -> B',
      scenarioLabel: 'HOP-3',
      notes: 'baseline',
    );

    final current = await research.currentSession();

    expect(current!.sessionId, session.sessionId);
    expect(current.name, 'CEF-H3');
    expect(current.nodeRole, 'RELAY');
    expect(current.targetHop, 3);
    expect(current.status, 'RUNNING');
    expect(current.sessionKind, 'RESEARCH');
    expect(current.forwardingMode, isNot('manually_selected'));
  });

  test('create trial numbering increments after terminal result', () async {
    final session = await research.startSession(
      deviceId: 'device-a',
      name: 'CTRL-H3',
      nodeRole: 'RELAY',
      targetHop: 3,
      topologyLabel: 'A -> R -> B',
      scenarioLabel: 'LOS-5M',
    );

    final first = await research.startTrial(
      sessionId: session.sessionId,
      trialCodePrefix: 'CTRL-H3',
    );
    await research.finishTrial(first.trialId, result: 'SUCCESS');
    final second = await research.startTrial(
      sessionId: session.sessionId,
      trialCodePrefix: 'CTRL-H3',
    );

    expect(first.trialNumber, 1);
    expect(first.trialCode, 'CTRL-H3-001');
    expect(second.trialNumber, 2);
    expect(second.trialCode, 'CTRL-H3-002');
  });

  test('start trial rejects when another trial is running', () async {
    final session = await research.startSession(
      deviceId: 'device-a',
      name: 'CTRL-H3',
      nodeRole: 'RELAY',
      targetHop: 3,
      topologyLabel: 'A -> R -> B',
      scenarioLabel: 'LOS-5M',
    );

    await research.startTrial(sessionId: session.sessionId);

    expect(
      () => research.startTrial(sessionId: session.sessionId),
      throwsA(isA<StateError>()),
    );
  });

  test(
    'AUTO session stays separate from active RESEARCH session query',
    () async {
      await logger.logEvent(
        eventType: ExperimentEventTypes.serviceStarted,
        deviceId: 'device-a',
      );

      expect(await research.currentSession(), isNull);

      final researchSession = await research.startSession(
        deviceId: 'device-a',
        name: 'FIELD',
        nodeRole: 'SOURCE',
        targetHop: 1,
        topologyLabel: 'A -> B',
        scenarioLabel: 'P10',
      );

      final rows = await db.query(
        'experiment_sessions',
        orderBy: 'started_at ASC',
      );
      expect(
        rows.map((row) => row['session_kind']),
        containsAll(['AUTO', 'RESEARCH']),
      );
      expect(
        (await research.currentSession())?.sessionId,
        researchSession.sessionId,
      );
    },
  );

  test('invalid trial remains stored and auditable', () async {
    final session = await research.startSession(
      deviceId: 'device-a',
      name: 'CTRL-H3',
      nodeRole: 'RELAY',
      targetHop: 3,
      topologyLabel: 'A -> R -> B',
      scenarioLabel: 'LOS-5M',
    );
    final trial = await research.startTrial(sessionId: session.sessionId);

    await research.invalidateTrial(trial.trialId, notes: 'user error');
    final trials = await research.trialsForSession(session.sessionId);

    expect(trials, hasLength(1));
    expect(trials.single.status, 'INVALID');
    expect(trials.single.result, 'INVALID');
    expect(trials.single.notes, 'user error');
  });

  test(
    'events are associated with correct running session and trial',
    () async {
      final session = await research.startSession(
        deviceId: 'device-a',
        name: 'CTRL-H3',
        nodeRole: 'DESTINATION',
        targetHop: 3,
        topologyLabel: 'A -> R -> B',
        scenarioLabel: 'LOS-5M',
      );
      final trial = await research.startTrial(sessionId: session.sessionId);

      await logger.logEvent(
        eventType: ExperimentEventTypes.blePacketReceived,
        deviceId: 'device-a',
        payloadHash: 'SOS:1',
        rssi: -67,
      );
      final events = await logger.events(
        sessionId: session.sessionId,
        trialId: trial.trialId,
      );

      expect(events, hasLength(1));
      expect(events.single.trialId, trial.trialId);
      expect(events.single.nodeRole, 'DESTINATION');
      expect(events.single.eventTimestampMs, isNotNull);
    },
  );

  test('logger does not use stale cached session across instances', () async {
    final autoLogger = ExperimentLogger(database: db);
    await autoLogger.logEvent(
      eventType: ExperimentEventTypes.serviceStarted,
      deviceId: 'device-a',
    );
    final researchSession = await research.startSession(
      deviceId: 'device-a',
      name: 'NEW-SESSION',
      nodeRole: 'DESTINATION',
      targetHop: 2,
      topologyLabel: 'A -> R -> B',
      scenarioLabel: 'P10',
    );
    final otherLoggerInstance = ExperimentLogger(database: db);

    await otherLoggerInstance.logEvent(
      eventType: ExperimentEventTypes.blePacketReceived,
      deviceId: 'device-a',
      eventTimestampMs: 1234,
      elapsedRealtimeMs: 5678,
      protocolTimestampMs: 9000,
      packetType: 'sos',
      status: 'active',
      hopIn: 1,
    );

    final events = await otherLoggerInstance.events(
      sessionId: researchSession.sessionId,
    );
    expect(events, hasLength(1));
    expect(events.single.eventTimestampMs, 1234);
    expect(events.single.elapsedRealtimeMs, 5678);
    expect(events.single.protocolTimestampMs, 9000);
    expect(events.single.packetType, 'sos');
    expect(events.single.hopIn, 1);
  });

  test('running trial timeout marks explicit FAILED/TIMEOUT', () async {
    final session = await research.startSession(
      deviceId: 'device-a',
      name: 'TIMEOUT',
      nodeRole: 'DESTINATION',
      targetHop: 2,
      topologyLabel: 'A -> B',
      scenarioLabel: 'P10',
      trialTimeoutSeconds: 60,
    );
    final trial = await research.startTrial(sessionId: session.sessionId);

    final updated = await research.applyTimeoutIfNeeded(
      sessionId: session.sessionId,
      nowMs: trial.startedAt + 60001,
    );
    final trials = await research.trialsForSession(session.sessionId);

    expect(updated, 1);
    expect(trials.single.status, 'COMPLETED');
    expect(trials.single.result, 'FAILED');
    expect(trials.single.failureReason, 'TIMEOUT');
  });
}
