import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pkmproject/config/mesh_config.dart';
import 'package:pkmproject/database_schema.dart';
import 'package:pkmproject/services/android_experiment_command_service.dart';
import 'package:pkmproject/services/experiment_clock.dart';
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
  var observationStarts = 0;
  var observationStops = 0;

  setUp(() async {
    activated = 0;
    observationStarts = 0;
    observationStops = 0;
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
      startObservationWindow: () {
        observationStarts++;
      },
      stopObservationWindow: () async {
        observationStops++;
      },
      clock: FixedExperimentClock(
        wallMs: DateTime.utc(2026, 8, 1).millisecondsSinceEpoch,
        monotonicMs: 1000,
      ),
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

  test('readiness reports the configured 24-bit protocol epoch', () async {
    final result = await commands.execute('readiness', const {});
    final epoch = result['protocol_epoch'] as Map<String, dynamic>;

    expect(epoch['epoch_id'], MeshConfig.protocolEpochId);
    expect(epoch['epoch_start'], '2026-06-01T00:00:00.000Z');
    expect(epoch['representable_end'], isNotNull);
    expect(epoch['remaining_days'], greaterThan(0));
    expect(epoch['valid'], isTrue);
    expect(result['measurement_timing_version'], 2);
    expect(
      result['rx_burst_gap_ms'],
      MeshConfig.defaultRxBurstGap.inMilliseconds,
    );
  });

  test(
    'status exposes only the current trial physical source callback',
    () async {
      await commands.execute('configure_session', configureArgs());
      await commands.execute('start_trial', {
        'command_id': 'start-status',
        'session_id': 'session-external',
        'trial_id': 'trial-status',
        'trial_code': 'H2-STATUS',
      });
      final initial = await commands.execute('get_status', const {});
      expect(initial['source_first_advertise_started_at_ms'], isNull);
      for (final trialId in ['previous-trial', 'trial-status']) {
        await db.insert('experiment_events', {
          'session_id': 'session-external',
          'trial_id': trialId,
          'event_type': ExperimentEventTypes.sourceFirstAdvertiseStarted,
          'timestamp_ms': 9000,
          'event_timestamp_ms': trialId == 'trial-status' ? 1234 : 1000,
          'message_key': trialId == 'trial-status' ? '100:200' : 'old:state',
        });
      }
      final result = await commands.execute('get_status', const {});
      expect(result['source_first_advertise_started_at_ms'], 1234);
      expect(result['source_first_advertise_message_key'], '100:200');
      expect(result['trial_id'], 'trial-status');
    },
  );

  test(
    'explicit coded radio configuration is recorded and preserves readiness metadata',
    () async {
      final radio = <String, Object?>{
        'ready': true,
        'requested_mode': 'coded',
        'coding_selection_support': 'unsupported',
        'on_air_coding_verified': false,
      };
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'configureBleRadio') {
              expect(call.arguments['mode'], 'coded');
              return radio;
            }
            if (call.method == 'getBleCapabilities') return {'radio': radio};
            return true;
          });
      final result = await commands.execute(
        'configure_session',
        configureArgs()..['radio_mode'] = 'coded',
      );
      expect(result['ok'], true);
      expect((await commands.execute('readiness', {}))['radio'], radio);
      expect(
        await db.query(
          'experiment_events',
          where: 'event_type = ?',
          whereArgs: ['RADIO_CONFIGURED'],
        ),
        hasLength(1),
      );
    },
  );

  test('required S8 is rejected before creating a research session', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          channel,
          (call) async => {
            'ready': false,
            'last_error': 'S8_SELECTION_UNSUPPORTED',
          },
        );
    final result = await commands.execute(
      'configure_session',
      configureArgs()..['radio_mode'] = 'coded_s8_required',
    );
    expect(result['ok'], false);
    expect(result['error'], contains('S8_SELECTION_UNSUPPORTED'));
    expect(await db.query('experiment_sessions'), isEmpty);
  });

  test('readiness reports configured RX burst inactivity gap', () async {
    await commands.execute('configure_session', configureArgs());
    final result = await commands.execute('readiness', const {});

    expect(result['rx_burst_gap_ms'], 2400);
  });

  test('start trial fails clearly when protocol epoch is exhausted', () async {
    final endExclusiveMs = (MeshConfig.protocolEpochSeconds + (1 << 24)) * 1000;
    final sessions = ResearchSessionService(database: db);
    final expiredCommands = AndroidExperimentCommandService(
      database: db,
      sessions: sessions,
      logger: ExperimentLogger(database: db),
      activateSos: (_) async {},
      clock: FixedExperimentClock(wallMs: endExclusiveMs, monotonicMs: 1000),
      resetQuietPeriod: Duration.zero,
    );

    final result = await expiredCommands.execute('start_trial', {
      'command_id': 'expired-start',
      'session_id': 'missing-session',
      'trial_id': 'expired-trial',
      'trial_code': 'EXPIRED',
    });

    expect(result['ok'], isFalse);
    expect(result['error'], contains('PROTOCOL_EPOCH_OUT_OF_RANGE'));
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
    'end observation stops scheduling and preserves terminal event trial',
    () async {
      await commands.execute('configure_session', configureArgs());
      await commands.execute('start_trial', {
        'command_id': 'start-window',
        'session_id': 'session-external',
        'trial_id': 'trial-window',
        'trial_code': 'H2-WINDOW',
      });

      final result = await commands.execute('end_observation_window', {
        'command_id': 'end-window',
        'trial_id': 'trial-window',
        'observation_ended_at_ms': 1785542430000,
      });

      expect(result['changed'], isTrue);
      expect(observationStarts, 1);
      expect(observationStops, 1);
      final trial = (await db.query(
        'experiment_trials',
        where: 'trial_id = ?',
        whereArgs: ['trial-window'],
      )).single;
      expect(trial['status'], 'WINDOW_ENDED');
      expect(trial['observation_ended_at'], 1785542430000);
      final event = (await db.query(
        'experiment_events',
        where: 'event_type = ?',
        whereArgs: ['TRIAL_WINDOW_ENDED'],
      )).single;
      expect(event['trial_id'], 'trial-window');
      expect(event['event_timestamp_ms'], 1785542430000);
    },
  );

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
