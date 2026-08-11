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
    int? senderCrc,
    int? hop,
    int? hopIn,
    int? hopOut,
    int? rssi,
    int? elapsedRealtimeMs,
    int? protocolTimestampMs,
    String? packetType,
    String? status,
    Map<String, dynamic>? detail,
  }) {
    return ExperimentEvent(
      sessionId: 'session-a',
      trialId: 'trial-a',
      eventType: type,
      senderCrc: senderCrc,
      timestampMs: timestamp,
      eventTimestampMs: timestamp,
      elapsedRealtimeMs: elapsedRealtimeMs,
      protocolTimestampMs: protocolTimestampMs,
      packetType: packetType,
      status: status,
      hopIn: hopIn,
      hopOut: hopOut,
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
        event(ExperimentEventTypes.blePacketStored, 1000, packetType: 'sos'),
        event(ExperimentEventTypes.blePacketAccepted, 1001, packetType: 'sos'),
        event(ExperimentEventTypes.blePacketDuplicate, 1002, packetType: 'sos'),
        event(ExperimentEventTypes.blePacketStale, 1003, packetType: 'sos'),
        event(ExperimentEventTypes.blePacketStale, 1004, packetType: 'ack'),
      ],
      trials: const [],
    );

    expect(metrics.acceptedCount, 1);
    expect(metrics.duplicateCount, 1);
    expect(metrics.staleCount, 1);
    expect(metrics.duplicateRatioPercent, closeTo(50, 0.01));
  });

  test('logical duplicate ratio is policy-level and excludes stale', () {
    final metrics = service.calculate(
      events: [
        event(ExperimentEventTypes.blePacketAccepted, 1000, packetType: 'sos'),
        event(ExperimentEventTypes.blePacketDuplicate, 1001, packetType: 'sos'),
        event(ExperimentEventTypes.blePacketDuplicate, 1002, packetType: 'sos'),
        event(ExperimentEventTypes.blePacketDuplicate, 1003, packetType: 'sos'),
        event(ExperimentEventTypes.blePacketStale, 1004, packetType: 'sos'),
      ],
      trials: const [],
    );

    expect(metrics.acceptedCount, 1);
    expect(metrics.duplicateCount, 3);
    expect(metrics.staleCount, 1);
    expect(metrics.duplicateRatioPercent, closeTo(75, 0.01));
  });

  test('SOS duplicate metric excludes ACK duplicate events', () {
    final metrics = service.calculate(
      events: [
        event(ExperimentEventTypes.blePacketAccepted, 1000, packetType: 'sos'),
        for (var i = 0; i < 3; i++)
          event(
            ExperimentEventTypes.blePacketDuplicate,
            1010 + i,
            packetType: 'sos',
          ),
        for (var i = 0; i < 5; i++)
          event(
            ExperimentEventTypes.blePacketDuplicate,
            1020 + i,
            packetType: 'ack',
          ),
        for (var i = 0; i < 5; i++)
          event(ExperimentEventTypes.ackDuplicate, 1030 + i, packetType: 'ack'),
      ],
      trials: const [],
    );

    expect(metrics.acceptedCount, 1);
    expect(metrics.duplicateCount, 3);
    expect(metrics.ackDuplicateCount, 5);
    expect(metrics.duplicateRatioPercent, closeTo(75, 0.01));
  });

  test('SOS duplicate ratio is zero when only ACK duplicates exist', () {
    final metrics = service.calculate(
      events: [
        event(ExperimentEventTypes.blePacketAccepted, 1000, packetType: 'sos'),
        for (var i = 0; i < 10; i++)
          event(
            ExperimentEventTypes.blePacketDuplicate,
            1010 + i,
            packetType: 'ack',
          ),
      ],
      trials: const [],
    );

    expect(metrics.acceptedCount, 1);
    expect(metrics.duplicateCount, 0);
    expect(metrics.duplicateRatioPercent, 0);
  });

  test(
    'SOS duplicate ratio is N/A when no SOS accepted or duplicate exists',
    () {
      final metrics = service.calculate(
        events: [
          event(
            ExperimentEventTypes.blePacketDuplicate,
            1000,
            packetType: 'ack',
          ),
        ],
        trials: const [],
      );

      expect(metrics.acceptedCount, 0);
      expect(metrics.duplicateCount, 0);
      expect(metrics.duplicateRatioPercent, isNull);
    },
  );

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
        event(
          ExperimentEventTypes.blePacketReceived,
          1000,
          packetType: 'sos',
          rssi: -80,
        ),
        event(
          ExperimentEventTypes.blePacketReceived,
          1100,
          packetType: 'sos',
          rssi: -60,
        ),
        event(
          ExperimentEventTypes.blePacketReceived,
          1200,
          packetType: 'sos',
          rssi: -70,
        ),
        event(
          ExperimentEventTypes.blePacketReceived,
          1300,
          packetType: 'ack',
          rssi: -20,
        ),
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
        event(
          ExperimentEventTypes.sosRelayTerminatedByAck,
          2300,
          payloadHash: 'ack-a',
        ),
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

  test('RSSI stats only use BLE_PACKET_RECEIVED samples', () {
    final metrics = service.calculate(
      events: [
        event(
          ExperimentEventTypes.blePacketReceived,
          1000,
          packetType: 'sos',
          rssi: -80,
        ),
        event(
          ExperimentEventTypes.blePacketReceived,
          1005,
          packetType: 'ack',
          rssi: -20,
        ),
        event(
          ExperimentEventTypes.bleRelayStarted,
          1010,
          packetType: 'sos',
          rssi: -10,
        ),
      ],
      trials: const [],
    );

    expect(metrics.rssiStats.count, 1);
    expect(metrics.rssiStats.mean, -80);
  });

  test(
    'current packet snapshot correlates accepted RX and TX by logical key',
    () {
      final metrics = service.calculate(
        events: [
          event(
            ExperimentEventTypes.blePacketAccepted,
            1000,
            payloadHash: 'payload-hop-2',
            senderCrc: 111,
            hopIn: 2,
            rssi: -71,
            protocolTimestampMs: 900000,
            packetType: 'sos',
            status: 'active',
            detail: {'from_server': false},
          ),
          event(
            ExperimentEventTypes.bleRelayStarted,
            1100,
            payloadHash: 'payload-hop-3',
            senderCrc: 111,
            protocolTimestampMs: 900000,
            packetType: 'sos',
            status: 'active',
            hopOut: 3,
          ),
          event(
            ExperimentEventTypes.bleRelayStarted,
            1200,
            payloadHash: 'payload-b',
            hopOut: 9,
          ),
        ],
        trials: const [],
      );

      expect(metrics.currentPacket?.payloadHash, 'payload-hop-2');
      expect(metrics.currentPacket?.hopIn, 2);
      expect(metrics.currentPacket?.hopOut, 3);
      expect(metrics.currentPacket?.protocolTimestampMs, 900000);
      expect(metrics.currentPacket?.rssi, -71);
    },
  );

  test('local latency uses elapsedRealtime when present', () {
    final samples = service.localLatencySamples(
      [
        event(
          ExperimentEventTypes.blePacketReceived,
          1000,
          elapsedRealtimeMs: 5000,
        ),
        event(
          ExperimentEventTypes.bleRelayStarted,
          900,
          elapsedRealtimeMs: 5120,
        ),
      ],
      startType: ExperimentEventTypes.blePacketReceived,
      endType: ExperimentEventTypes.bleRelayStarted,
    );

    expect(samples, [120]);
  });

  test('local latency uses wall clocks when only start has monotonic', () {
    final samples = service.localLatencySamples(
      [
        event(
          ExperimentEventTypes.blePacketReceived,
          1000,
          elapsedRealtimeMs: 5000,
        ),
        event(ExperimentEventTypes.bleRelayStarted, 1286),
      ],
      startType: ExperimentEventTypes.blePacketReceived,
      endType: ExperimentEventTypes.bleRelayStarted,
    );

    expect(samples, [286]);
  });

  test('local latency uses wall clocks when only end has monotonic', () {
    final samples = service.localLatencySamples(
      [
        event(ExperimentEventTypes.blePacketReceived, 1000),
        event(
          ExperimentEventTypes.bleRelayStarted,
          1286,
          elapsedRealtimeMs: 999999,
        ),
      ],
      startType: ExperimentEventTypes.blePacketReceived,
      endType: ExperimentEventTypes.bleRelayStarted,
    );

    expect(samples, [286]);
  });

  test('negative local latency is ignored', () {
    final samples = service.localLatencySamples(
      [
        event(ExperimentEventTypes.blePacketReceived, 2000),
        event(ExperimentEventTypes.bleRelayStarted, 1000),
      ],
      startType: ExperimentEventTypes.blePacketReceived,
      endType: ExperimentEventTypes.bleRelayStarted,
    );

    expect(samples, isEmpty);
  });

  test('E2E latency ignores monotonic clocks and uses wall time only', () {
    final samples = service.endToEndLatencySamples([
      event(
        'SOURCE_FIRST_ADVERTISE',
        1000,
        payloadHash: 'e2e',
        elapsedRealtimeMs: 999999,
      ),
      event(
        'DESTINATION_FIRST_RECEIVE',
        3420,
        payloadHash: 'e2e',
        elapsedRealtimeMs: 100,
      ),
    ]);

    expect(samples, [2420]);
  });

  test(
    'local relay latency correlates logical state across changed payload hash',
    () {
      final samples = service.localLatencySamples(
        [
          event(
            ExperimentEventTypes.blePacketReceived,
            1000,
            payloadHash: 'HASH-HOP-1',
            senderCrc: 123,
            protocolTimestampMs: 100000,
            packetType: 'sos',
            status: 'active',
            hopIn: 1,
          ),
          event(
            ExperimentEventTypes.bleRelayStarted,
            1286,
            payloadHash: 'HASH-HOP-2',
            senderCrc: 123,
            protocolTimestampMs: 100000,
            packetType: 'sos',
            status: 'active',
            hopOut: 2,
          ),
        ],
        startType: ExperimentEventTypes.blePacketReceived,
        endType: ExperimentEventTypes.bleRelayStarted,
      );

      expect(samples, [286]);
    },
  );

  test(
    'ACK termination latency uses later termination event and logical key',
    () {
      final metrics = service.calculate(
        events: [
          event(
            ExperimentEventTypes.ackReceived,
            10000,
            payloadHash: 'ACK-RX-HASH',
            senderCrc: 321,
            protocolTimestampMs: 9000,
            packetType: 'ack',
            status: 'resolved',
            elapsedRealtimeMs: 510000,
          ),
          event(
            ExperimentEventTypes.sosRelayTerminatedByAck,
            10145,
            payloadHash: 'ACK-END-HASH',
            senderCrc: 321,
            protocolTimestampMs: 9000,
            packetType: 'ack',
            status: 'resolved',
          ),
        ],
        trials: const [],
      );

      expect(metrics.ackTerminationLatencyMs.median, 145);
      expect(metrics.ackTerminationLatencyMs.median, isNot(0));
    },
  );

  test('hop samples use only RX and actual relay start canonical events', () {
    final metrics = service.calculate(
      events: [
        event(
          ExperimentEventTypes.blePacketReceived,
          1000,
          hopIn: 1,
          senderCrc: 1,
          protocolTimestampMs: 1000,
          packetType: 'sos',
          status: 'active',
        ),
        event(ExperimentEventTypes.sosTransactionCommitted, 1001, hopIn: 1),
        event(ExperimentEventTypes.blePacketAccepted, 1002, hopIn: 1),
        event(ExperimentEventTypes.blePacketStored, 1003, hopOut: 2),
        event(ExperimentEventTypes.bleRelayQueued, 1004, hopOut: 2),
        event(
          ExperimentEventTypes.bleRelayStarted,
          1100,
          hopOut: 2,
          senderCrc: 1,
          protocolTimestampMs: 1000,
          packetType: 'sos',
          status: 'active',
        ),
      ],
      trials: const [],
    );

    expect(metrics.hopInStats.count, 1);
    expect(metrics.hopOutStats.count, 1);
  });

  test('SOS hop descriptive stats exclude ACK hop samples', () {
    final metrics = service.calculate(
      events: [
        event(
          ExperimentEventTypes.blePacketReceived,
          1000,
          packetType: 'sos',
          hopIn: 1,
        ),
        event(
          ExperimentEventTypes.blePacketReceived,
          1001,
          packetType: 'sos',
          hopIn: 2,
        ),
        event(
          ExperimentEventTypes.blePacketReceived,
          1002,
          packetType: 'ack',
          hopIn: 5,
        ),
        event(
          ExperimentEventTypes.bleRelayStarted,
          1010,
          packetType: 'sos',
          hopOut: 2,
        ),
        event(
          ExperimentEventTypes.bleRelayStarted,
          1011,
          packetType: 'sos',
          hopOut: 3,
        ),
        event(
          ExperimentEventTypes.bleRelayStarted,
          1012,
          packetType: 'ack',
          hopOut: 6,
        ),
      ],
      trials: const [],
    );

    expect(metrics.hopInStats.count, 2);
    expect(metrics.hopInStats.min, 1);
    expect(metrics.hopInStats.max, 2);
    expect(metrics.hopOutStats.count, 2);
    expect(metrics.hopOutStats.min, 2);
    expect(metrics.hopOutStats.max, 3);
  });

  test(
    'hop validation correlates accepted RX and relay start by logical state',
    () {
      HopValidation? validationFor(int hopIn, int hopOut) {
        return service.latestHopValidationFromEvents([
          event(
            ExperimentEventTypes.blePacketAccepted,
            1000,
            payloadHash: 'rx-$hopIn',
            senderCrc: 99,
            protocolTimestampMs: 100000,
            packetType: 'sos',
            status: 'active',
            hopIn: hopIn,
          ),
          event(
            ExperimentEventTypes.bleRelayStarted,
            1100,
            payloadHash: 'tx-$hopOut',
            senderCrc: 99,
            protocolTimestampMs: 100000,
            packetType: 'sos',
            status: 'active',
            hopOut: hopOut,
          ),
        ]);
      }

      expect(validationFor(1, 2)?.passed, true);
      expect(validationFor(63, 63)?.passed, true);
      expect(validationFor(1, 3)?.passed, false);
    },
  );

  test('current packet does not show TX before actual relay start', () {
    final metrics = service.calculate(
      events: [
        event(
          ExperimentEventTypes.blePacketAccepted,
          1000,
          payloadHash: 'rx-hop-1',
          senderCrc: 77,
          protocolTimestampMs: 100000,
          packetType: 'sos',
          status: 'active',
          hopIn: 1,
        ),
        event(
          ExperimentEventTypes.blePacketStored,
          1010,
          payloadHash: 'stored-hop-2',
          senderCrc: 77,
          protocolTimestampMs: 100000,
          packetType: 'sos',
          status: 'active',
          hopOut: 2,
        ),
        event(
          ExperimentEventTypes.bleRelayQueued,
          1020,
          payloadHash: 'queued-hop-2',
          senderCrc: 77,
          protocolTimestampMs: 100000,
          packetType: 'sos',
          status: 'active',
          hopOut: 2,
        ),
      ],
      trials: const [],
    );

    expect(metrics.currentPacket?.receivedAtMs, 1000);
    expect(metrics.currentPacket?.hopOut, isNull);
    expect(metrics.currentPacket?.advertisedAtMs, isNull);
    expect(metrics.currentPacket?.storedAtMs, 1010);
    expect(metrics.currentPacket?.relayQueuedAtMs, 1020);
  });

  test(
    'current packet populates advertised fields only from relay started',
    () {
      final metrics = service.calculate(
        events: [
          event(
            ExperimentEventTypes.blePacketAccepted,
            1000,
            payloadHash: 'rx-hop-1',
            senderCrc: 77,
            protocolTimestampMs: 100000,
            packetType: 'sos',
            status: 'active',
            hopIn: 1,
          ),
          event(
            ExperimentEventTypes.bleRelayStarted,
            1286,
            payloadHash: 'tx-hop-2',
            senderCrc: 77,
            protocolTimestampMs: 100000,
            packetType: 'sos',
            status: 'active',
            hopOut: 2,
          ),
          event(
            ExperimentEventTypes.bleRelayStarted,
            2286,
            payloadHash: 'tx-hop-2-repeat',
            senderCrc: 77,
            protocolTimestampMs: 100000,
            packetType: 'sos',
            status: 'active',
            hopOut: 2,
          ),
        ],
        trials: const [],
      );

      expect(metrics.currentPacket?.hopOut, 2);
      expect(metrics.currentPacket?.advertisedAtMs, 1286);
    },
  );

  test(
    'initial relay latency uses accepted RX and repeated relay slots once',
    () {
      final samples = service.initialRelayLatencySamples([
        event(
          ExperimentEventTypes.blePacketAccepted,
          1000,
          senderCrc: 5,
          protocolTimestampMs: 9000,
          packetType: 'sos',
          status: 'active',
          hopIn: 0,
        ),
        event(
          ExperimentEventTypes.bleRelayStarted,
          1300,
          senderCrc: 5,
          protocolTimestampMs: 9000,
          packetType: 'sos',
          status: 'active',
          hopOut: 1,
        ),
        event(
          ExperimentEventTypes.bleRelayStarted,
          11300,
          senderCrc: 5,
          protocolTimestampMs: 9000,
          packetType: 'sos',
          status: 'active',
          hopOut: 1,
        ),
        event(
          ExperimentEventTypes.bleRelayStarted,
          21300,
          senderCrc: 5,
          protocolTimestampMs: 9000,
          packetType: 'sos',
          status: 'active',
          hopOut: 1,
        ),
      ]);

      expect(samples, [300]);
    },
  );

  test('duplicate RX does not replace accepted RX for latency', () {
    final metrics = service.calculate(
      events: [
        event(
          ExperimentEventTypes.blePacketReceived,
          1000,
          senderCrc: 5,
          protocolTimestampMs: 9000,
          packetType: 'sos',
          status: 'active',
          hopIn: 0,
        ),
        event(
          ExperimentEventTypes.blePacketAccepted,
          1000,
          senderCrc: 5,
          protocolTimestampMs: 9000,
          packetType: 'sos',
          status: 'active',
          hopIn: 0,
        ),
        event(
          ExperimentEventTypes.blePacketReceived,
          1150,
          senderCrc: 5,
          protocolTimestampMs: 9000,
          packetType: 'sos',
          status: 'active',
          hopIn: 1,
        ),
        event(
          ExperimentEventTypes.blePacketDuplicate,
          1150,
          senderCrc: 5,
          protocolTimestampMs: 9000,
          packetType: 'sos',
          status: 'active',
          hopIn: 1,
        ),
        event(
          ExperimentEventTypes.bleRelayStarted,
          1300,
          senderCrc: 5,
          protocolTimestampMs: 9000,
          packetType: 'sos',
          status: 'active',
          hopOut: 1,
        ),
      ],
      trials: const [],
    );

    expect(metrics.localRelayLatencyMs.count, 1);
    expect(metrics.localRelayLatencyMs.median, 300);
  });

  test('duplicate RX does not replace accepted hop for hop correctness', () {
    final validation = service.latestHopValidationFromEvents([
      event(
        ExperimentEventTypes.blePacketAccepted,
        1000,
        senderCrc: 5,
        protocolTimestampMs: 9000,
        packetType: 'sos',
        status: 'active',
        hopIn: 0,
      ),
      event(
        ExperimentEventTypes.blePacketReceived,
        1150,
        senderCrc: 5,
        protocolTimestampMs: 9000,
        packetType: 'sos',
        status: 'active',
        hopIn: 1,
      ),
      event(
        ExperimentEventTypes.blePacketDuplicate,
        1150,
        senderCrc: 5,
        protocolTimestampMs: 9000,
        packetType: 'sos',
        status: 'active',
        hopIn: 1,
      ),
      event(
        ExperimentEventTypes.bleRelayStarted,
        1300,
        senderCrc: 5,
        protocolTimestampMs: 9000,
        packetType: 'sos',
        status: 'active',
        hopOut: 1,
      ),
      event(
        ExperimentEventTypes.bleRelayStarted,
        2300,
        senderCrc: 5,
        protocolTimestampMs: 9000,
        packetType: 'sos',
        status: 'active',
        hopOut: 1,
      ),
    ]);

    expect(validation?.hopIn, 0);
    expect(validation?.hopOut, 1);
    expect(validation?.passed, true);
  });

  test('current packet ignores later duplicate raw RX', () {
    final metrics = service.calculate(
      events: [
        event(
          ExperimentEventTypes.blePacketAccepted,
          1000,
          senderCrc: 7,
          protocolTimestampMs: 9000,
          packetType: 'sos',
          status: 'active',
          hopIn: 0,
        ),
        event(
          ExperimentEventTypes.blePacketStored,
          1050,
          senderCrc: 7,
          protocolTimestampMs: 9000,
          packetType: 'sos',
          status: 'active',
        ),
        event(
          ExperimentEventTypes.bleRelayQueued,
          1100,
          senderCrc: 7,
          protocolTimestampMs: 9000,
          packetType: 'sos',
          status: 'active',
        ),
        event(
          ExperimentEventTypes.bleRelayStarted,
          1300,
          senderCrc: 7,
          protocolTimestampMs: 9000,
          packetType: 'sos',
          status: 'active',
          hopOut: 1,
        ),
        event(
          ExperimentEventTypes.blePacketReceived,
          10000,
          senderCrc: 7,
          protocolTimestampMs: 9000,
          packetType: 'sos',
          status: 'active',
          hopIn: 1,
        ),
        event(
          ExperimentEventTypes.blePacketDuplicate,
          10000,
          senderCrc: 7,
          protocolTimestampMs: 9000,
          packetType: 'sos',
          status: 'active',
          hopIn: 1,
        ),
      ],
      trials: const [],
    );

    expect(metrics.currentPacket?.receivedAtMs, 1000);
    expect(metrics.currentPacket?.storedAtMs, 1050);
    expect(metrics.currentPacket?.relayQueuedAtMs, 1100);
    expect(metrics.currentPacket?.advertisedAtMs, 1300);
    expect(metrics.currentPacket?.hopIn, 0);
    expect(metrics.currentPacket?.hopOut, 1);
  });

  test('current packet does not attach old TX to newer accepted lifecycle', () {
    final metrics = service.calculate(
      events: [
        event(
          ExperimentEventTypes.blePacketAccepted,
          1000,
          senderCrc: 9,
          protocolTimestampMs: 9000,
          packetType: 'sos',
          status: 'active',
          hopIn: 0,
        ),
        event(
          ExperimentEventTypes.bleRelayStarted,
          1300,
          senderCrc: 9,
          protocolTimestampMs: 9000,
          packetType: 'sos',
          status: 'active',
          hopOut: 1,
        ),
        event(
          ExperimentEventTypes.blePacketAccepted,
          5000,
          senderCrc: 9,
          protocolTimestampMs: 9000,
          packetType: 'sos',
          status: 'active',
          hopIn: 0,
        ),
      ],
      trials: const [],
    );

    expect(metrics.currentPacket?.receivedAtMs, 5000);
    expect(metrics.currentPacket?.advertisedAtMs, isNull);
    expect(metrics.currentPacket?.hopOut, isNull);
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
