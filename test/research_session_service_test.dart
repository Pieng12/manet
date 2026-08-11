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
  });

  test('create trial and trial numbering increments correctly', () async {
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
    final second = await research.startTrial(
      sessionId: session.sessionId,
      trialCodePrefix: 'CTRL-H3',
    );

    expect(first.trialNumber, 1);
    expect(first.trialCode, 'CTRL-H3-001');
    expect(second.trialNumber, 2);
    expect(second.trialCode, 'CTRL-H3-002');
  });

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
}
