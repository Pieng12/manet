import 'dart:math';

import 'package:pkmproject/config/mesh_config.dart';

class ProtocolEpochReadiness {
  const ProtocolEpochReadiness({
    required this.epochId,
    required this.epochStartMs,
    required this.representableEndMs,
    required this.remainingDays,
    required this.isValid,
  });

  static const int timestampModuloSeconds = 1 << 24;

  final String epochId;
  final int epochStartMs;
  final int representableEndMs;
  final double remainingDays;
  final bool isValid;

  factory ProtocolEpochReadiness.at(
    int nowMs, {
    int epochSeconds = MeshConfig.protocolEpochSeconds,
    String epochId = MeshConfig.protocolEpochId,
  }) {
    final startMs = epochSeconds * 1000;
    final endExclusiveMs = (epochSeconds + timestampModuloSeconds) * 1000;
    final endMs = endExclusiveMs - 1;
    return ProtocolEpochReadiness(
      epochId: epochId,
      epochStartMs: startMs,
      representableEndMs: endMs,
      remainingDays:
          max(0, endExclusiveMs - nowMs) /
          const Duration(days: 1).inMilliseconds,
      isValid: nowMs >= startMs && nowMs < endExclusiveMs,
    );
  }

  Map<String, Object> toJson() => {
    'epoch_id': epochId,
    'epoch_start': DateTime.fromMillisecondsSinceEpoch(
      epochStartMs,
      isUtc: true,
    ).toIso8601String(),
    'representable_end': DateTime.fromMillisecondsSinceEpoch(
      representableEndMs,
      isUtc: true,
    ).toIso8601String(),
    'remaining_days': remainingDays,
    'valid': isValid,
  };
}
