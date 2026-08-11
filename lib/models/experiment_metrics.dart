class NumericStats {
  final int count;
  final num? min;
  final num? max;
  final double? mean;
  final double? median;

  const NumericStats({
    required this.count,
    this.min,
    this.max,
    this.mean,
    this.median,
  });

  static NumericStats fromSamples(List<num> samples) {
    if (samples.isEmpty) return const NumericStats(count: 0);
    final sorted = [...samples]..sort();
    final sum = sorted.fold<num>(0, (total, value) => total + value);
    final middle = sorted.length ~/ 2;
    final median = sorted.length.isOdd
        ? sorted[middle].toDouble()
        : ((sorted[middle - 1] + sorted[middle]) / 2).toDouble();
    return NumericStats(
      count: sorted.length,
      min: sorted.first,
      max: sorted.last,
      mean: sum / sorted.length,
      median: median,
    );
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
  });

  NumericStats get hopStats => hopInStats;
}
