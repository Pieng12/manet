import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pkmproject/config/mesh_config.dart';
import 'package:pkmproject/database_schema.dart';
import 'package:pkmproject/services/android_experiment_command_service.dart';
import 'package:pkmproject/services/experiment_clock.dart';
import 'package:pkmproject/services/experiment_logger.dart';
import 'package:pkmproject/services/neighbor_runtime.dart';
import 'package:pkmproject/services/relay_queue_service.dart';
import 'package:pkmproject/services/research_session_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('id.ac.usu.resqmesh/mesh');
  late Database db;
  late AndroidExperimentCommandService commands;
  var activated = 0;
  var observationStarts = 0;
  var observationStops = 0;
  var participationOk = true;
  var previousRx = true;
  var previousTx = true;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    activated = 0;
    observationStarts = 0;
    observationStops = 0;
    participationOk = true;
    previousRx = previousTx = true;
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
          if (call.method == 'setResearchParticipation') {
            final args = Map<String, dynamic>.from(call.arguments as Map);
            final enabled = args['enabled'] == true;
            final rxOnly = args['rxOnly'] == true;
            final reactivated =
                participationOk &&
                enabled &&
                (!previousRx || (!rxOnly && !previousTx));
            if (participationOk) {
              previousRx = enabled;
              if (!rxOnly) previousTx = enabled;
            }
            return <String, Object?>{
              'ok': participationOk,
              'confirmed_enabled': participationOk ? enabled : null,
              'reactivated': reactivated,
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

  test('MPL command OFF then ON renews identity only once', () async {
    final runtime = NeighborRuntime.instance;
    await runtime.configure({
      'transport_profile': NeighborRuntime.profile,
      'node_id': 'android-source',
      'mode': 'trickle_mpl',
      'allowed_transmitters': [3],
      'scheduler_semantics': 'resqmesh-trickle-mpl-v1',
    });
    await runtime.startTrial('activation-test');
    final before = await runtime.frame();
    await commands.execute('set_rx_participation', {
      'command_id': 'rx-off',
      'enabled': false,
    });
    final on = await commands.execute('set_rx_participation', {
      'command_id': 'rx-on',
      'enabled': true,
    });
    expect(on['ok'], true);
    expect(on['local_boot_id'], before.boot + 1);
    final after = await runtime.frame();
    expect(after.boot, before.boot + 1);
    expect(after.sequence, 1);
    await commands.execute('set_rx_participation', {
      'command_id': 'rx-on-again',
      'enabled': true,
    });
    expect((await runtime.frame()).boot, after.boot);
    await runtime.endTrial();
  });

  test(
    'failed native activation cannot restart MPL discovery or consume an incarnation',
    () async {
      final runtime = NeighborRuntime.instance;
      await runtime.configure({
        'transport_profile': NeighborRuntime.profile,
        'node_id': 'android-source',
        'mode': 'trickle_mpl',
        'allowed_transmitters': [3],
        'scheduler_semantics': 'resqmesh-trickle-mpl-v1',
      });
      await runtime.startTrial('failed-activation-test');
      final before = await runtime.frame();
      final generation = runtime.mpl!.control.generation;
      previousRx = false;
      participationOk = false;
      final response = await commands.execute('set_rx_participation', {
        'command_id': 'rx-on-failed',
        'enabled': true,
      });
      expect(response['ok'], false);
      expect(runtime.mpl!.control.generation, generation);
      expect((await runtime.frame()).boot, before.boot);
      await runtime.endTrial();
    },
  );

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

  for (final mode in [
    'basic_flooding',
    'trickle_no_suppression',
    'trickle',
    'trickle_neighbor_status',
  ]) {
    test('ADB JSON array configures source adjacency for $mode', () async {
      final args = Map<String, dynamic>.from(
        jsonDecode(
              jsonEncode({
                ...configureArgs(),
                'node_id': 'android-source',
                'transport_profile': 'neighbor_graph_v1',
                'topology': 'neighbor_graph_v1',
                'mode': mode,
                'allowed_transmitters': ['3376660029', '1347088263'],
                'observation_window_ms': 180000,
              }),
            )
            as Map,
      );
      final response = await commands.execute('configure_session', args);
      expect(response['ok'], isTrue, reason: response.toString());
      final status = await commands.execute('readiness', {});
      expect(status['allowed_transmitters'], [3376660029, 1347088263]);
      expect(status['transmitter_id'], 2110340604);
      expect(status['mode'], mode);
      expect(status['gateway_enabled'], isFalse);
      expect(status['ack_enabled'], isFalse);
    });
    test(
      'adaptive configuration/readiness only enables STATUS scheduler for $mode',
      () async {
        final response = await commands.execute('configure_session', {
          ...configureArgs(),
          'node_id': 'android-source',
          'transport_profile': 'neighbor_graph_v1',
          'topology': 'neighbor_graph_v1',
          'mode': mode,
          'allowed_transmitters': [3376660029, 1347088263],
          'neighbor_status_policy': 'adaptive_v2',
          'observation_window_ms': 180000,
        });
        expect(response['ok'], isTrue, reason: response.toString());
        final ready = await commands.execute('readiness', {});
        final parameters = ready['neighbor_parameters'] as Map;
        expect(parameters['neighbor_status_policy'], 'adaptive_v2');
        expect(parameters['status_period_ms'], 60000);
        expect(parameters['freshness_ms'], 150000);
        expect(parameters['data_grace_ms'], 10000);
        expect(parameters['empty_retry_max_ms'], 32000);
        final started = await commands.execute('start_trial', {
          'command_id': 'adaptive-start',
          'session_id': 'session-external',
          'trial_id': 'adaptive-trial',
          'trial_code': 'ADAPTIVE-S0',
        });
        expect(started['ok'], isTrue, reason: started.toString());
        expect(
          NeighborRuntime.instance.statusSchedule != null,
          mode == 'trickle_neighbor_status',
        );
        expect(RelayQueueService().mode.logValue, mode);
      },
    );
  }

  test(
    'malformed native array string still fails adjacency validation',
    () async {
      final response = await commands.execute('configure_session', {
        ...configureArgs(),
        'node_id': 'android-source',
        'transport_profile': 'neighbor_graph_v1',
        'allowed_transmitters': '[Ljava.lang.String;@1234',
      });
      expect(response['ok'], isFalse);
      expect(
        response['error'],
        contains('Invalid stable transmitter adjacency'),
      );
    },
  );

  test(
    'no-suppression method is persisted and reported by the scheduler owner',
    () async {
      await commands.execute('configure_session', {
        ...configureArgs(),
        'mode': 'trickle_no_suppression',
      });
      expect(RelayQueueService().mode, ForwardingMode.trickleNoSuppression);
      final status = await commands.execute('readiness', {
        'command_id': 'ablation-ready',
      });
      expect(status['mode'], 'trickle_no_suppression');
      expect(status['suppression_enabled'], isFalse);
      expect(status['method_design_version'], 3);
      expect(status['trickle_imin_ms'], 8000);
      expect(status['trickle_imax_ms'], 256000);
    },
  );

  test(
    'neighbor reset finalizes interrupted trial without replacing completed result',
    () async {
      expect(
        (await commands.execute('configure_session', {
          ...configureArgs(),
          'transport_profile': 'neighbor_graph_v1',
          'topology': 'neighbor_graph_v1',
          'mode': 'trickle_no_suppression',
          'allowed_transmitters': [123],
        }))['ok'],
        true,
      );
      expect(
        (await commands.execute('start_trial', {
          'command_id': 'start-new',
          'session_id': 'session-external',
          'trial_id': 'interrupted',
          'trial_code': 'S0-MAIN',
        }))['ok'],
        true,
      );
      await commands.execute('reset_trial', {
        'command_id': 'reset-interrupted',
        'trial_id': 'interrupted',
      });
      expect((await db.query('experiment_trials')).single['result'], 'INVALID');
      expect(
        (await db.query('experiment_trials')).single['failure_reason'],
        'RESET_WITHOUT_FINAL_RESULT',
      );
      expect(
        (await commands.execute('configure_session', {
          ...configureArgs(),
          'command_id': 'cfg-recovery',
          'transport_profile': 'neighbor_graph_v1',
          'topology': 'neighbor_graph_v1',
          'allowed_transmitters': [123],
        }))['ok'],
        true,
      );
      expect(await db.query('experiment_events'), isNotEmpty);
    },
  );

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

  test(
    'final result correction after reset preserves archived events',
    () async {
      await commands.execute('configure_session', {
        ...configureArgs(),
        'node_id': 'android-source',
        'transport_profile': 'neighbor_graph_v1',
        'topology': 'neighbor_graph_v1',
        'mode': 'basic_flooding',
        'allowed_transmitters': [123],
      });
      await commands.execute('start_trial', {
        'command_id': 'cleanup-start',
        'session_id': 'session-external',
        'trial_id': 'cleanup-trial',
        'trial_code': 'S0_STABLE',
      });
      final initial = <String, dynamic>{
        'command_id': 'finalize-initial',
        'trial_id': 'cleanup-trial',
        'result': 'SUCCESS',
        'reason': '',
      };
      expect((await commands.execute('finalize_trial', initial))['ok'], true);
      final reset = await commands.execute('reset_trial', {
        'command_id': 'cleanup-reset',
        'trial_id': 'cleanup-trial',
      });
      expect(reset['archived_events_preserved'], true);
      final events = await db.query('experiment_events', orderBy: 'id');
      expect(events, isNotEmpty);
      final correction = await commands.execute('finalize_trial', {
        ...initial,
        'command_id': 'finalize-final-INVALID',
        'result': 'INVALID',
        'reason': 'RESET_OR_QUIET_PERIOD_FAILED',
      });
      expect(correction['ok'], true);
      expect(correction['result'], 'INVALID');
      final replay = await commands.execute('finalize_trial', initial);
      expect(replay['idempotent_replay'], true);
      expect((await db.query('experiment_trials')).single['result'], 'INVALID');
      expect(
        (await db.query('experiment_trials')).single['failure_reason'],
        'RESET_OR_QUIET_PERIOD_FAILED',
      );
      final summary = <String, dynamic>{
        'session_id': 'session-external',
        'trial_id': 'cleanup-trial',
        'measurement_version': 'all-node-burst-v1',
        'N': 5,
        'result': 'INVALID',
        'invalid_reasons': ['RESET_OR_QUIET_PERIOD_FAILED'],
        'reset_verified': false,
        'dsr_percent': 100,
      };
      final stored = await commands.execute('store_neighbor_metrics', {
        'command_id': 'network-summary-final-INVALID',
        'summary_base64': base64Encode(utf8.encode(jsonEncode(summary))),
      });
      expect(stored['ok'], true);
      final status = await commands.execute('get_neighbor_status', {
        'command_id': 'cleanup-summary-status',
      });
      expect(status['network_summary'], summary);
      expect(await db.query('experiment_events', orderBy: 'id'), events);
    },
  );

  test(
    'merged recovery summary uses existing storage and retains null delays',
    () async {
      await commands.execute('configure_session', {
        ...configureArgs(),
        'node_id': 'android-source',
        'transport_profile': 'neighbor_graph_v1',
        'topology': 'neighbor_graph_v1',
        'mode': 'basic_flooding',
        'allowed_transmitters': [123],
      });
      await commands.execute('start_trial', {
        'command_id': 'recovery-start',
        'session_id': 'session-external',
        'trial_id': 'recovery-trial',
        'trial_code': 'S2_POST_DATA_STOP',
      });
      for (final extended in [false, true]) {
        final summary = <String, dynamic>{
          'session_id': 'session-external',
          'trial_id': 'recovery-trial',
          'measurement_version': 'all-node-burst-v1',
          'N': 5,
          'dsr_percent': 80,
          if (extended) ...{
            'recovery_measurement_version': 'same-node-recovery-v1',
            'recovery_mean_ms': null,
            'recovery_eligible_targets': 1,
            'recovery_receivers': [
              {
                'receiver': 'esp-destination',
                'recovery_delay_ms': null,
                'recovery_status': 'NOT_RECOVERED_WITHIN_WINDOW',
              },
            ],
          },
        };
        final result = await commands.execute('store_neighbor_metrics', {
          'command_id': 'summary-$extended',
          'summary_base64': base64Encode(utf8.encode(jsonEncode(summary))),
        });
        expect(result['ok'], true);
        final status = await commands.execute('get_neighbor_status', {
          'command_id': 'summary-status-$extended',
        });
        expect(status['network_summary'], summary);
      }
    },
  );

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
