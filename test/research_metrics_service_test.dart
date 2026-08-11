import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pkmproject/config/mesh_config.dart';
import 'package:pkmproject/models/experiment_event.dart';
import 'package:pkmproject/models/experiment_metrics.dart';
import 'package:pkmproject/models/experiment_trial.dart';
import 'package:pkmproject/services/experiment_logger.dart';
import 'package:pkmproject/services/research_metrics_service.dart';

void main() {
  final service = ResearchMetricsService();

  ExperimentEvent event(
    String type,
    int timestamp, {
    String? payloadHash = 'packet-a',
    int? hop,
    int? rssi,
    Map<String, dynamic>? detail,
  }) {
    return ExperimentEvent(
      sessionId: 'session-a',
      trialId: 'trial-a',
      eventType: type,
      timestampMs: timestamp,
      eventTimestampMs: timestamp,
      payloadHash: payloadHash,
      hopCount: hop,
      rssi: rssi,
      detailJson: detail == null ? null : jsonEncode(detail),
    );
  }

  ExperimentTrial trial(
    int number, {
    String status = 'COMPLETED',
    String? result,
  }) {
    return ExperimentTrial(
      trialId: 'trial-$number',
      sessionId: 'session-a',
      trialNumber: number,
      trialCode: 'T-${number.toString().padLeft(3, '0')}',
      startedAt: 1000,
      status: status,
      result: result,
    );
  }

  test('numeric stats handle mean median odd even min max and empty', () {
    final odd = NumericStats.fromSamples([5, 1, 9]);
    final even = NumericStats.fromSamples([10, 2, 4, 8]);
    final empty = NumericStats.fromSamples([]);

    expect(odd.min, 1);
    expect(odd.max, 9);
    expect(odd.mean, closeTo(5, 0.001));
    expect(odd.median, 5);
    expect(even.median, 6);
    expect(empty.count, 0);
    expect(empty.mean, isNull);
  });

  test('DSR excludes invalid trials from denominator', () {
    final metrics = service.calculate(
      events: const [],
      trials: [
        for (var i = 1; i <= 29; i++) trial(i, result: 'SUCCESS'),
        trial(30, result: 'FAILED'),
        trial(31, status: 'INVALID', result: 'INVALID'),
      ],
    );

    expect(metrics.successfulTrials, 29);
    expect(metrics.validCompletedTrials, 30);
    expect(metrics.dsrPercent, closeTo(96.67, 0.01));
  });

  test('duplicate ratio excludes stale events from duplicate numerator', () {
    final metrics = service.calculate(
      events: [
        event(ExperimentEventTypes.blePacketStored, 1000),
        event(ExperimentEventTypes.blePacketStored, 1001),
        event(ExperimentEventTypes.blePacketDuplicate, 1002),
        event(ExperimentEventTypes.blePacketStale, 1003),
      ],
      trials: const [],
    );

    expect(metrics.acceptedCount, 2);
    expect(metrics.duplicateCount, 1);
    expect(metrics.staleCount, 1);
    expect(metrics.duplicateRatioPercent, closeTo(33.33, 0.01));
  });

  test('hop validation accepts expected increments and saturated 63', () {
    expect(service.validateHop(hopIn: 0, hopOut: 1).passed, true);
    expect(service.validateHop(hopIn: 1, hopOut: 2).passed, true);
    expect(
      service
          .validateHop(
            hopIn: MeshConfig.maxProtocolHop,
            hopOut: MeshConfig.maxProtocolHop,
          )
          .passed,
      true,
    );
    final failed = service.validateHop(hopIn: 1, hopOut: 3);
    expect(failed.passed, false);
    expect(failed.expectedHopOut, 2);
  });

  test('local relay latency is calculated and missing pair is N/A', () {
    final samples = service.localLatencySamples(
      [
        event(ExperimentEventTypes.blePacketReceived, 1000),
        event(ExperimentEventTypes.bleRelayStarted, 1286),
      ],
      startType: ExperimentEventTypes.blePacketReceived,
      endType: ExperimentEventTypes.bleRelayStarted,
    );
    final missing = service.localLatencySamples(
      [event(ExperimentEventTypes.blePacketReceived, 1000)],
      startType: ExperimentEventTypes.blePacketReceived,
      endType: ExperimentEventTypes.bleRelayStarted,
    );

    expect(samples, [286]);
    expect(missing, isEmpty);
  });

  test(
    'E2E latency is not fabricated without source and destination evidence',
    () {
      final none = service.endToEndLatencySamples([
        event(ExperimentEventTypes.blePacketReceived, 1000),
        event(ExperimentEventTypes.bleRelayStarted, 1200),
      ]);
      final available = service.endToEndLatencySamples([
        event('SOURCE_FIRST_ADVERTISE', 1000, payloadHash: 'p'),
        event('DESTINATION_FIRST_RECEIVE', 3420, payloadHash: 'p'),
      ]);

      expect(none, isEmpty);
      expect(available, [2420]);
    },
  );

  test('RSSI stats are calculated correctly', () {
    final metrics = service.calculate(
      events: [
        event(ExperimentEventTypes.blePacketReceived, 1000, rssi: -80),
        event(ExperimentEventTypes.blePacketReceived, 1100, rssi: -60),
        event(ExperimentEventTypes.blePacketReceived, 1200, rssi: -70),
      ],
      trials: const [],
    );

    expect(metrics.rssiStats.min, -80);
    expect(metrics.rssiStats.max, -60);
    expect(metrics.rssiStats.mean, closeTo(-70, 0.001));
    expect(metrics.rssiStats.median, -70);
  });

  test('ACK duplicate stale invalid and termination latency stay separate', () {
    final metrics = service.calculate(
      events: [
        event(ExperimentEventTypes.ackReceived, 1000),
        event(ExperimentEventTypes.ackTransactionCommitted, 1010),
        event(ExperimentEventTypes.ackDuplicate, 1020),
        event(ExperimentEventTypes.ackRejectedOlder, 1030),
        event(
          ExperimentEventTypes.bleRelayDropped,
          1040,
          detail: {'reason': 'ACK_ACTIVE_REJECTED'},
        ),
        event(ExperimentEventTypes.ackReceived, 2000, payloadHash: 'ack-a'),
        event('LOCAL_RELAY_STOPPED', 2300, payloadHash: 'ack-a'),
      ],
      trials: const [],
    );

    expect(metrics.ackReceivedCount, 2);
    expect(metrics.ackAcceptedCount, 1);
    expect(metrics.ackDuplicateCount, 1);
    expect(metrics.ackStaleCount, 1);
    expect(metrics.ackInvalidCount, 1);
    expect(metrics.ackTerminationLatencyMs.median, 300);
  });

  test('advertise requested is not counted as successful TX', () {
    final metrics = service.calculate(
      events: [
        event(ExperimentEventTypes.bleAdvertiseRequested, 1000),
        event(ExperimentEventTypes.bleAdvertiseStarted, 1010),
        event(ExperimentEventTypes.bleRelayStarted, 1020),
      ],
      trials: const [],
    );

    expect(metrics.txAttemptCount, 1);
    expect(metrics.txSuccessCount, 1);
    expect(metrics.relaySlotCount, 1);
  });
}
