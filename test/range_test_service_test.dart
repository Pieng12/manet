import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pkmproject/database_schema.dart';
import 'package:pkmproject/services/experiment_clock.dart';
import 'package:pkmproject/services/android_experiment_command_service.dart';
import 'package:pkmproject/services/range_test_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Database pilot, protocol;
  late FixedExperimentClock clock;
  late RangeTestService service;
  var failTelemetry = false;
  final telemetry = <Map<String, dynamic>>[];

  Future<int> receive(
    String observation, {
    int? time,
    int hop = 1,
    String type = 'BLE_PACKET_RECEIVED',
    int crc = 123,
  }) async {
    return protocol.insert('experiment_events', {
      'session_id': 'run',
      'trial_id': 'trial',
      'event_type': type,
      'timestamp_ms': clock.wallMs + 100000,
      'event_timestamp_ms': time ?? clock.wallMs,
      'sender_crc': crc,
      'protocol_timestamp_ms': 1000000,
      'packet_type': 'sos',
      'status': 'active',
      'hop_in': hop,
      'rssi': -101,
      'observation_id': observation,
    });
  }

  Future<void> prepare() async {
    await service.configure({
      'run_id': 'run',
      'session_id': 'run',
      'trial_id': 'trial',
      'source_sender_crc': 123,
      'source_timestamp_ms': 1000000,
      'source_latitude': 0.0,
      'source_longitude': 0.0,
    });
  }

  Future<void> start() async {
    await prepare();
    await receive('baseline');
    telemetry.add({
      'observation_id': 'baseline',
      'primary_phy': 3,
      'secondary_phy': 3,
      'legacy': false,
    });
    await service.refresh();
    await service.configure({'run_id': 'run', 'action': 'start'});
  }

  void advance(int ms) {
    clock.wallMs += ms;
    clock.monotonicMs += ms;
  }

  setUp(() async {
    sqfliteFfiInit();
    pilot = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    protocol = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    for (final sql in RangeTestService.schema) {
      await pilot.execute(sql);
    }
    for (final sql in [
      createExperimentSessionsTableSql,
      createExperimentTrialsTableSql,
      createExperimentEventsTableSql,
      createExperimentCommandsTableSql,
    ]) {
      await protocol.execute(sql);
    }
    await protocol.insert('experiment_sessions', {
      'session_id': 'run',
      'device_id': 'phone',
      'device_model': 'test',
      'android_version': 'test',
      'forwarding_mode': 'basic_flooding',
      'max_hop': 63,
      'message_lifetime_ms': 0,
      'relay_cooldown_ms': 1000,
      'started_at': 1000000,
      'node_role': 'DESTINATION',
      'expected_hop_in': 1,
      'build_id': 'test-build',
    });
    await protocol.insert('experiment_trials', {
      'trial_id': 'trial',
      'session_id': 'run',
      'trial_number': 1,
      'trial_code': 'H1',
      'started_at': 1000000,
      'status': 'RUNNING',
    });
    clock = FixedExperimentClock(wallMs: 1000000, monotonicMs: 0);
    telemetry.clear();
    failTelemetry = false;
    service = RangeTestService(
      storage: pilot,
      protocol: protocol,
      clock: clock,
      enableTelemetry: (_, _) async {},
      telemetry: () async {
        if (failTelemetry) throw StateError('telemetry write failed');
        return {'run_id': 'run', 'samples': telemetry};
      },
    );
  });

  tearDown(() async {
    await pilot.close();
    await protocol.close();
  });

  test(
    'diagnostic commands configure pilot and expose unfinished old trial',
    () async {
      final commands = AndroidExperimentCommandService(
        database: protocol,
        rangeService: service,
        clock: clock,
      );
      final configured = await commands.execute('configure_range_test', {
        'command_id': 'configure-pilot',
        'run_id': 'run',
        'session_id': 'run',
        'trial_id': 'trial',
        'source_sender_crc': 123,
        'source_timestamp_ms': 1000000,
      });
      expect(configured['ok'], isTrue);
      await protocol.update('experiment_trials', {'status': 'WINDOW_ENDED'});
      final result = await commands.execute('get_range_test_status', {
        'command_id': 'status-pilot',
      });
      expect(result['ok'], isTrue);
      expect(
        (result['unfinished_trials'] as List).single['status'],
        'WINDOW_ENDED',
      );
      expect(
        (await protocol.query('experiment_trials')).single['finalized_at'],
        isNull,
      );
      expect(
        (await commands.execute('configure_range_test', {
          'command_id': 'configure-pilot',
        }))['idempotent_replay'],
        isTrue,
      );
    },
  );

  test(
    'SOS identity filters timestamp, kind, status and session independently',
    () {
      final run = {
        'session_id': 'run',
        'trial_id': 'trial',
        'source_sender_crc': 123,
        'source_timestamp_ms': 1000000,
      };
      final event = {
        'session_id': 'run',
        'trial_id': 'trial',
        'sender_crc': 123,
        'protocol_timestamp_ms': 1000000,
        'event_type': 'BLE_PACKET_RECEIVED',
        'packet_type': 'sos',
        'status': 'active',
        'hop_in': 1,
      };
      expect(RangeTestService.matches(event, run), isTrue);
      for (final entry in {
        'session_id': 'other',
        'trial_id': 'other',
        'protocol_timestamp_ms': 1001000,
        'packet_type': 'ack',
        'status': 'resolved',
        'hop_in': 2,
      }.entries) {
        expect(
          RangeTestService.matches({...event, entry.key: entry.value}, run),
          isFalse,
        );
      }
    },
  );

  test('GPS quality, age, finite coordinates and nearest receive-time fix', () {
    const fix = RangeFix(10000, 0, 0.001, 20);
    expect(fix.usableAt(15000), isTrue);
    expect(fix.usableAt(15001), isFalse);
    expect(const RangeFix(10000, 0, 0, 20.01).usableAt(10000), isFalse);
    expect(const RangeFix(10000, 91, 0, 1).usableAt(10000), isFalse);
    expect(RangeFix.validCoordinate(double.nan, 0), isFalse);
    expect(RangeFix.nearest([const RangeFix(0, 0, 0, 1), fix], 11000), fix);
  });

  test(
    'GPS near-source warning considers both radii without zeroing distance',
    () {
      final quality = RangeGpsDistance.assess(11.6, 10.7, 4.3);
      expect(quality['gps_accuracy_radii_sum_m'], 15);
      expect(
        quality['gps_distance_quality'],
        'not_distinguishable_from_location_uncertainty',
      );
      expect(
        RangeGpsDistance.assess(100, 5, 4)['gps_distance_quality'],
        'gps_estimate',
      );
      expect(
        RangeGpsDistance.assess(100, 5, null)['gps_distance_quality'],
        'source_uncertainty_unknown',
      );
      expect(
        RangeGpsDistance.assess(100, 21, 4)['gps_distance_quality'],
        'unavailable_or_inaccurate',
      );
      expect(
        RangeGpsDistance.assess(double.nan, 5, 4)['gps_distance_quality'],
        'unavailable_or_inaccurate',
      );
    },
  );

  test('manual 3D requires both values and permits zero and signed height', () {
    expect(
      RangePointMeasurement(horizontalM: 3, heightDifferenceM: -4).distance3dM,
      5,
    );
    expect(
      RangePointMeasurement(horizontalM: 0, heightDifferenceM: 0).distance3dM,
      0,
    );
    expect(
      RangePointMeasurement(horizontalM: 0, heightDifferenceM: -3).distance3dM,
      3,
    );
    expect(RangePointMeasurement(horizontalM: 3).distance3dM, isNull);
    expect(RangePointMeasurement(heightDifferenceM: 4).distance3dM, isNull);
    expect(RangePointMeasurement().toJson()['measurement_method'], isNull);
  });

  test('manual measurements reject negative horizontal, NaN and infinity', () {
    for (final value in [-1.0, double.nan, double.infinity]) {
      expect(
        () => RangePointMeasurement(horizontalM: value),
        throwsArgumentError,
      );
    }
    expect(
      () => RangePointMeasurement(heightDifferenceM: double.infinity),
      throwsArgumentError,
    );
    expect(() => RangePointMeasurement(method: 'rssi'), throwsArgumentError);
    expect(() => RangePointMeasurement(note: 'x' * 501), throwsArgumentError);
  });

  test(
    'point measurements survive reopening without GPS or protocol edits',
    () async {
      await start();
      advance(1);
      await service.startPoint(
        scannerActive: true,
        measurement: RangePointMeasurement(
          horizontalM: 3,
          heightDifferenceM: -4,
          note: 'Lantai 1, dekat tangga',
        ),
      );
      advance(1000);
      await receive('manual-point');
      await service.refresh();
      advance(59000);
      await service.refresh();
      final reopened = RangeTestService(
        storage: pilot,
        protocol: protocol,
        clock: clock,
        enableTelemetry: (_, _) async {},
        telemetry: () async => {},
      );
      final data = await reopened.snapshot();
      final point = (data['points'] as List).single;
      final rx = (data['receives'] as List).last;
      expect(point['status'], 'completed');
      expect(point['measured_horizontal_m'], 3);
      expect(point['height_difference_m'], -4);
      expect(point['measured_3d_m'], 5);
      expect(rx['point_id'], point['point_id']);
      expect(rx['measurement_method'], 'tape_measure');
      expect(rx['point_note'], 'Lantai 1, dekat tangga');
      expect(rx['distance_m'], isNull);
      expect(rx['location'], isNull);
      expect(data['farthest_received_manual_horizontal_m'], 3);
      expect(data['farthest_received_manual_3d_m'], 5);
      expect(await protocol.query('experiment_events'), hasLength(2));
    },
  );

  test(
    'GPS raw distance is retained separately from measured horizontal',
    () async {
      await start();
      advance(1);
      await service.startPoint(
        scannerActive: true,
        measurement: RangePointMeasurement(horizontalM: 0.5),
      );
      await service.recordFix(RangeFix(clock.wallMs, 0, 0.0001, 12));
      await receive('nearby');
      advance(1);
      await service.refresh();
      final sample = ((await service.snapshot())['receives'] as List).last;
      expect(sample['distance_m'], closeTo(11.12, 0.1));
      expect(sample['measured_horizontal_m'], 0.5);
      expect(sample['measured_3d_m'], isNull);
      expect(sample['gps_distance_quality'], 'source_uncertainty_unknown');
    },
  );

  test(
    'cancelled and nonreceiving points never inflate manual receive summary',
    () async {
      await start();
      advance(1);
      await service.startPoint(
        scannerActive: true,
        measurement: RangePointMeasurement(
          horizontalM: 1000,
          heightDifferenceM: 100,
        ),
      );
      advance(1);
      await receive('cancelled-rx');
      await service.refresh();
      await service.cancelPoint('APP_BACKGROUND');
      advance(1);
      await service.startPoint(
        scannerActive: true,
        measurement: RangePointMeasurement(horizontalM: 999),
      );
      advance(60000);
      await service.refresh();
      final data = await service.snapshot();
      expect(data['farthest_received_manual_horizontal_m'], isNull);
      expect(data['farthest_received_manual_3d_m'], isNull);
    },
  );

  test(
    'manual values do not carry into next point or RX outside point window',
    () async {
      await start();
      advance(1);
      await service.startPoint(
        scannerActive: true,
        measurement: RangePointMeasurement(horizontalM: 5),
      );
      advance(60000);
      await receive('at-end');
      await service.refresh();
      await service.startPoint(scannerActive: true);
      advance(1);
      await receive('next-point');
      await service.refresh();
      final data = await service.snapshot();
      expect((data['points'] as List).last['measured_horizontal_m'], isNull);
      final rx = data['receives'] as List;
      expect(rx[1]['measured_horizontal_m'], isNull);
      expect(rx.last['measured_horizontal_m'], isNull);
    },
  );

  test(
    'physical receive time drives GPS distance, not UI refresh time',
    () async {
      await prepare();
      await service.recordFix(const RangeFix(1000000, 0, 0.001, 5));
      await receive('one', time: 1000000);
      advance(12000);
      await service.refresh();
      final rx = ((await service.snapshot())['receives'] as List).single;
      expect(rx['timestamp_ms'], 1000000);
      expect(rx['distance_m'], closeTo(111.2, 1));
      expect(rx['location']['timestamp_ms'], 1000000);
      expect((await service.latest())!['source_accuracy_m'], isNull);
    },
  );

  test(
    'bad or absent GPS preserves RX, with no manufactured distance',
    () async {
      await prepare();
      await service.recordFix(const RangeFix(1000000, 0, 0.001, 21));
      await receive('one');
      await service.refresh();
      final status = await service.snapshot();
      expect(status['baseline_received'], isTrue);
      expect(status['farthest_observed_m'], isNull);
      expect((status['receives'] as List).single['location'], isNull);
    },
  );

  test(
    'cursor drains more than 500 events and counts logical duplicates',
    () async {
      await prepare();
      for (var i = 0; i < 510; i++) {
        await receive('obs-$i');
      }
      await receive('obs-0');
      await receive('accepted', type: 'BLE_PACKET_ACCEPTED');
      await receive('wrong-crc', crc: 456);
      await receive('wrong-hop', hop: 2);
      await service.refresh();
      await service.refresh();
      expect((await service.snapshot())['receives'], hasLength(510));
      expect((await pilot.query('range_runs')).single['cursor'], 514);
      expect(await protocol.query('experiment_events'), hasLength(514));
    },
  );

  test(
    'baseline requires actual Coded RX, not requested configuration',
    () async {
      await prepare();
      await receive('one');
      await service.refresh();
      await expectLater(
        service.configure({'run_id': 'run', 'action': 'start'}),
        throwsStateError,
      );
      telemetry.add({
        'observation_id': 'one',
        'primary_phy': 1,
        'secondary_phy': 0,
        'legacy': true,
      });
      await service.refresh();
      expect((await service.snapshot())['baseline_coded'], isFalse);
      telemetry[0] = {
        'observation_id': 'one',
        'primary_phy': 3,
        'secondary_phy': 3,
        'legacy': false,
      };
      await service.refresh();
      await service.configure({'run_id': 'run', 'action': 'start'});
      expect((await service.latest())!['status'], 'running');
    },
  );

  test(
    'telemetry failure cannot prevent canonical receive persistence',
    () async {
      await prepare();
      failTelemetry = true;
      await receive('one');
      await service.refresh();
      final status = await service.snapshot();
      expect(status['receives'], hasLength(1));
      expect(
        (status['diagnostics'] as List).single['code'],
        'PHY_TELEMETRY_UNAVAILABLE',
      );
    },
  );

  test('point uses 60 monotonic seconds and records observed RX', () async {
    await start();
    await service.startPoint(scannerActive: true);
    advance(59000);
    await receive('point');
    await service.refresh();
    expect(
      ((await service.snapshot())['points'] as List).single['status'],
      'running',
    );
    advance(1000);
    await service.refresh();
    final point = ((await service.snapshot())['points'] as List).single;
    expect(point['status'], 'completed');
    expect(point['receive_result'], 'received');
    expect(point['receive_count'], 2);
  });

  test(
    'background cancels point without discarding receive evidence',
    () async {
      await start();
      await service.startPoint(scannerActive: true);
      await service.cancelPoint('APP_BACKGROUND');
      final status = await service.snapshot();
      expect((status['points'] as List).single['reason'], 'APP_BACKGROUND');
      expect(status['receives'], hasLength(1));
    },
  );

  test(
    'restart and clock jump invalidate point, never fabricate completion',
    () async {
      await start();
      await service.startPoint(scannerActive: true);
      clock.wallMs += 10000;
      await service.refresh();
      expect(
        ((await service.snapshot())['points'] as List).single['reason'],
        'CLOCK_CHANGED',
      );
      await service.startPoint(scannerActive: true);
      final restarted = RangeTestService(
        storage: pilot,
        protocol: protocol,
        clock: FixedExperimentClock(
          wallMs: clock.wallMs,
          monotonicMs: 0,
          monotonicDomainId: 'new-boot',
        ),
        telemetry: () async => {},
        enableTelemetry: (_, _) async {},
      );
      await restarted.refresh();
      expect(
        ((await restarted.snapshot())['points'] as List).last['reason'],
        'APP_RESTARTED',
      );
    },
  );

  test('scanner failure and session end prohibit new point', () async {
    await start();
    await expectLater(
      service.startPoint(scannerActive: false),
      throwsStateError,
    );
    advance(RangeTestService.durationMs);
    await service.refresh();
    expect((await service.latest())!['status'], 'finished');
    await expectLater(
      service.startPoint(scannerActive: true),
      throwsStateError,
    );
  });

  test(
    'background command isolate cannot invalidate UI monotonic timer',
    () async {
      await start();
      await service.startPoint(scannerActive: true);
      final commands = RangeTestService(
        storage: pilot,
        protocol: protocol,
        observePoints: false,
        clock: FixedExperimentClock(
          wallMs: clock.wallMs,
          monotonicMs: 500,
          monotonicDomainId: 'background-isolate',
        ),
        telemetry: () async => {},
        enableTelemetry: (_, _) async {},
      );
      await commands.refresh();
      expect(
        ((await commands.snapshot())['points'] as List).single['status'],
        'running',
      );
      advance(60000);
      await service.refresh();
      expect(
        ((await service.snapshot())['points'] as List).single['status'],
        'completed',
      );
    },
  );

  test(
    'status command stays below logcat limit while file retains full backlog',
    () async {
      await prepare();
      for (var i = 0; i < 510; i++) {
        await receive('observation-$i');
      }
      final commands = AndroidExperimentCommandService(
        database: protocol,
        rangeService: service,
        clock: clock,
      );
      final status = await commands.execute('get_range_test_status', {
        'command_id': 'compact-status',
      });
      expect(status['receive_count'], 510);
      expect(jsonEncode(status).length, lessThan(3500));
      expect(status.containsKey('receives'), isFalse);
      expect((await service.snapshot())['receives'], hasLength(510));
    },
  );

  test(
    'export preserves identity, physical times and independent raw data',
    () async {
      await start();
      final dir = await Directory.systemTemp.createTemp('range-export-test-');
      try {
        final result = await service.export(directory: dir);
        final json = jsonDecode(
          await File(result['json_path'] as String).readAsString(),
        );
        expect(json['run']['algorithm'], 'basic_flooding');
        expect(json['receives'][0]['observation_id'], 'baseline');
        expect(json['receives'][0]['timestamp_ms'], 1000000);
        expect(await protocol.query('experiment_events'), hasLength(1));
      } finally {
        await dir.delete(recursive: true);
      }
    },
  );
}
