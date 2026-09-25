import 'dart:math';

class NumericStats {
  final int count;
  final num? min;
  final num? max;
  final double? mean;
  final double? median;
  final double? sampleStandardDeviation;
  final double? q1;
  final double? q3;
  final double? iqr;

  const NumericStats({
    required this.count,
    this.min,
    this.max,
    this.mean,
    this.median,
    this.sampleStandardDeviation,
    this.q1,
    this.q3,
    this.iqr,
  });

  static NumericStats fromSamples(List<num> samples) {
    if (samples.isEmpty) return const NumericStats(count: 0);
    final sorted = [...samples]..sort();
    final sum = sorted.fold<num>(0, (total, value) => total + value);
    final middle = sorted.length ~/ 2;
    final median = sorted.length.isOdd
        ? sorted[middle].toDouble()
        : ((sorted[middle - 1] + sorted[middle]) / 2).toDouble();
    final mean = sum / sorted.length;
    final sampleVariance = sorted.length < 2
        ? null
        : sorted.fold<double>(
                0,
                (total, value) => total + pow(value - mean, 2).toDouble(),
              ) /
              (sorted.length - 1);
    final lower = sorted.sublist(0, sorted.length ~/ 2);
    final upper = sorted.sublist((sorted.length + 1) ~/ 2);
    final q1 = _median(lower);
    final q3 = _median(upper);
    return NumericStats(
      count: sorted.length,
      min: sorted.first,
      max: sorted.last,
      mean: mean,
      median: median,
      sampleStandardDeviation: sampleVariance == null
          ? null
          : sqrt(sampleVariance),
      q1: q1,
      q3: q3,
      iqr: q1 == null || q3 == null ? null : q3 - q1,
    );
  }

  static double? _median(List<num> sorted) {
    if (sorted.isEmpty) return null;
    final middle = sorted.length ~/ 2;
    return sorted.length.isOdd
        ? sorted[middle].toDouble()
        : ((sorted[middle - 1] + sorted[middle]) / 2).toDouble();
  }
}

class HopValidation {
  final int hopIn;
  final int hopOut;
  final int expectedHopOut;

  const HopValidation({
    required this.hopIn,
    required this.hopOut,
    required this.expectedHopOut,
  });

  bool get passed => hopOut == expectedHopOut;
}

class CurrentPacketSnapshot {
  final int? senderCrc;
  final int? protocolTimestampMs;
  final String? status;
  final String? packetType;
  final int? hopIn;
  final int? hopOut;
  final int? rssi;
  final bool? fromServer;
  final String? payloadHash;
  final int? receivedAtMs;
  final int? storedAtMs;
  final int? relayQueuedAtMs;
  final int? advertisedAtMs;

  const CurrentPacketSnapshot({
    this.senderCrc,
    this.protocolTimestampMs,
    this.status,
    this.packetType,
    this.hopIn,
    this.hopOut,
    this.rssi,
    this.fromServer,
    this.payloadHash,
    this.receivedAtMs,
    this.storedAtMs,
    this.relayQueuedAtMs,
    this.advertisedAtMs,
  });
}

class ExperimentMetrics {
  final int successfulTrials;
  final int validCompletedTrials;
  final double? dsrPercent;
  final int acceptedCount;
  final int duplicateCount;
  final int staleCount;
  final int invalidCount;
  final int ackSuppressedCount;
  final double? duplicateRatioPercent;
  final int ackReceivedCount;
  final int ackAcceptedCount;
  final int ackDuplicateCount;
  final int ackStaleCount;
  final int ackInvalidCount;
  final int txAttemptCount;
  final int txSuccessCount;
  final int relaySlotCount;
  final double? transmissionOverhead;
  final NumericStats rssiStats;
  final NumericStats hopInStats;
  final NumericStats hopOutStats;
  final NumericStats localRelayLatencyMs;
  final NumericStats e2eLatencyMs;
  final NumericStats ackTerminationLatencyMs;
  final HopValidation? latestHopValidation;
  final CurrentPacketSnapshot? currentPacket;
  final bool e2eRequiresPeerLog;
  final bool requiresMergedPeerLogs;

  const ExperimentMetrics({
    required this.successfulTrials,
    required this.validCompletedTrials,
    required this.dsrPercent,
    required this.acceptedCount,
    required this.duplicateCount,
    required this.staleCount,
    required this.invalidCount,
    required this.ackSuppressedCount,
    required this.duplicateRatioPercent,
    required this.ackReceivedCount,
    required this.ackAcceptedCount,
    required this.ackDuplicateCount,
    required this.ackStaleCount,
    required this.ackInvalidCount,
    required this.txAttemptCount,
    required this.txSuccessCount,
    required this.relaySlotCount,
    required this.transmissionOverhead,
    required this.rssiStats,
    required this.hopInStats,
    required this.hopOutStats,
    required this.localRelayLatencyMs,
    required this.e2eLatencyMs,
    required this.ackTerminationLatencyMs,
    required this.latestHopValidation,
    required this.currentPacket,
    required this.e2eRequiresPeerLog,
    required this.requiresMergedPeerLogs,
  });

  NumericStats get hopStats => hopInStats;
}
