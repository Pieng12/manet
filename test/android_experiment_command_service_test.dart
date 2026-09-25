import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pkmproject/config/mesh_config.dart';
import 'package:pkmproject/database_schema.dart';
import 'package:pkmproject/services/android_experiment_command_service.dart';
import 'package:pkmproject/services/experiment_logger.dart';
import 'package:pkmproject/services/relay_queue_service.dart';
import 'package:pkmproject/services/research_session_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('id.ac.usu.resqmesh/mesh');
  late Database db;
  late AndroidExperimentCommandService commands;
  var activated = 0;

  setUp(() async {
    sqfliteFfiInit();
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    for (final sql in [
      createSosMessagesTableSql,
      createRelayQueueTableSql,
      createAckTombstonesTableSql,
      createTrickleStatesTableSql,
      createTrickleObservationsTableSql,
      createProcessedBleObservationsTableSql,
      createExperimentSessionsTableSql,
      createExperimentTrialsTableSql,
      createExperimentCommandsTableSql,
      createExperimentEventsTableSql,
    ]) {
      await db.execute(sql);
    }
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'getBleCapabilities') {
            return <String, Object?>{
              'bluetoothEnabled': true,
              'scanPermission': true,
              'advertisePermission': true,
              'nativeScanActive': true,
              'nativeAdvertisingActive': false,
            };
          }
          return true;
        });
    final sessions = ResearchSessionService(database: db);
    final logger = ExperimentLogger(database: db);
    commands = AndroidExperimentCommandService(
      database: db,
      sessions: sessions,
      logger: logger,
      activateSos: (message) async {
        activated++;
        await db.insert('sos_messages', message.toDbMap());
      },
      resetQuietPeriod: Duration.zero,
    );
  });

  tearDown(() async {
    RelayQueueService.configureSessionMode(null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await db.close();
  });

  Map<String, dynamic> configureArgs({bool mainExperiment = true}) => {
    'command_id': 'configure-1',
    'session_id': 'session-external',
    'session_code': 'TRICKLE-H2',
    'node_id': 'node-a',
    'role': 'SOURCE',
    'target_hop': 2,
    'hypothesis': 'H2',
    'observation_window_ms': 30000,
    'mode': 'trickle',
    'build_id': 'test-build',
    'rx_burst_gap_ms': 2400,
    'main_experiment': mainExperiment,
    'gateway_enabled': true,
    'ack_enabled': true,
  };

  test('ADB command IDs are idempotent and create one SOS per trial', () async {
    final configured = await commands.execute(
      'configure_session',
      configureArgs(),
    );
    expect(configured['session_id'], 'session-external');
    expect(configured['gateway_enabled'], isFalse);
    expect(configured['ack_enabled'], isFalse);
    expect(RelayQueueService().mode, ForwardingMode.trickle);

    await commands.execute('start_trial', {
      'command_id': 'start-1',
      'session_id': 'session-external',
      'trial_id': 'trial-external',
      'trial_code': 'H2-T001',
    });
    final trigger = <String, dynamic>{
      'command_id': 'trigger-1',
      'trial_id': 'trial-external',
      'node_id': 'node-a',
    };
    final first = await commands.execute('trigger_sos', trigger);
    final replay = await commands.execute('trigger_sos', trigger);

    expect(first['hop'], 1);
    expect(replay['idempotent_replay'], isTrue);
    expect(activated, 1);
    expect(
      (await db.rawQuery('SELECT COUNT(*) c FROM sos_messages')).single['c'],
      1,
    );
  });

  test('reset removes protocol state but preserves archived events', () async {
    await commands.execute('configure_session', configureArgs());
    await commands.execute('start_trial', {
      'command_id': 'start-1',
      'session_id': 'session-external',
      'trial_id': 'trial-external',
      'trial_code': 'H2-T001',
    });
    await commands.execute('trigger_sos', {
      'command_id': 'trigger-1',
      'trial_id': 'trial-external',
      'node_id': 'node-a',
    });
    await db.insert('relay_queue', {
      'message_id': 'ack-test',
      'packet_type': 'ack',
      'trial_id': 'trial-external',
    });
    await db.insert('ack_tombstones', {
      'sender_crc': 99,
      'ack_timestamp_ms': 1000,
      'status': 2,
      'updated_at': 1000,
      'trial_id': 'trial-external',
    });
    await db.insert('processed_ble_observations', {
      'observation_id': 'observation-test',
      'packet_type': 'sos',
      'state': 'completed',
      'first_received_at': 1000,
      'processed_at': 1000,
      'updated_at': 1000,
      'trial_id': 'trial-external',
    });
    final eventsBefore =
        (await db.rawQuery(
              'SELECT COUNT(*) c FROM experiment_events',
            )).single['c']
            as int;

    final result = await commands.execute('reset_trial', {
      'command_id': 'reset-1',
      'trial_id': 'trial-external',
    });

    expect(result['state_cleared'], isTrue);
    expect(await db.query('sos_messages'), isEmpty);
    expect(await db.query('relay_queue'), isEmpty);
    expect(await db.query('ack_tombstones'), isEmpty);
    expect(await db.query('processed_ble_observations'), isEmpty);
    expect(
      (await db.rawQuery(
        'SELECT COUNT(*) c FROM experiment_events',
      )).single['c'],
      greaterThan(eventsBefore),
    );
  });

  test(
    'separate validation session may explicitly enable gateway and ACK',
    () async {
      final result = await commands.execute(
        'configure_session',
        configureArgs(mainExperiment: false),
      );

      expect(result['gateway_enabled'], isTrue);
      expect(result['ack_enabled'], isTrue);
      expect(result['main_experiment'], isFalse);
    },
  );
}
