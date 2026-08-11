import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pkmproject/database_schema.dart';
import 'package:pkmproject/services/experiment_export_service.dart';
import 'package:pkmproject/services/experiment_logger.dart';
import 'package:pkmproject/services/research_session_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Database db;
  late Directory tempDir;
  late ExperimentLogger logger;

  setUp(() async {
    sqfliteFfiInit();
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await db.execute(createExperimentSessionsTableSql);
    await db.execute(createExperimentTrialsTableSql);
    await db.execute(createExperimentEventsTableSql);
    tempDir = await Directory.systemTemp.createTemp('resqmesh_export_test_');
    logger = ExperimentLogger(database: db);
  });

  tearDown(() async {
    await db.close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('creates experiment session and records RSSI event', () async {
    final session = await logger.ensureSession(deviceId: 'device-a');

    await logger.logEvent(
      eventType: ExperimentEventTypes.blePacketReceived,
      deviceId: 'device-a',
      messageId: 'msg-1',
      senderCrc: 12345,
      hopCount: 2,
      rssi: -71,
      payloadHash: 'SOS:12345:1:1',
      detail: {'kind': 'sos'},
    );

    final events = await logger.events(sessionId: session.sessionId);

    expect(events, hasLength(1));
    expect(events.single.rssi, -71);
    expect(events.single.hopCount, 2);
    expect(events.single.payloadHash, 'SOS:12345:1:1');
    expect(await logger.eventCount(sessionId: session.sessionId), 1);
  });

  test('exports experiment data to JSON and CSV', () async {
    final session = await logger.ensureSession(deviceId: 'device-a');
    await logger.logEvent(
      eventType: ExperimentEventTypes.gatewayUploadSucceeded,
      deviceId: 'device-a',
      detail: {'latency_ms': 1200},
    );
    final exporter = ExperimentExportService(
      logger: logger,
      researchSessionService: ResearchSessionService(database: db),
      outputDir: tempDir,
    );

    final jsonFile = await exporter.exportJson(sessionId: session.sessionId);
    final csvFile = await exporter.exportCsv(sessionId: session.sessionId);

    final jsonPayload =
        jsonDecode(await jsonFile.readAsString()) as Map<String, dynamic>;
    final csvPayload = await csvFile.readAsString();

    expect(jsonPayload['events'], isA<List<dynamic>>());
    expect(csvPayload, contains('GATEWAY_UPLOAD_SUCCEEDED'));
    expect(csvPayload, contains('session_id,session_name,trial_id'));
    expect(csvPayload, contains('detail'));
  });
}
