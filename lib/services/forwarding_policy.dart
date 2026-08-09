import 'package:pkmproject/config/mesh_config.dart';
import 'package:pkmproject/models/forwarding_decision.dart';
import 'package:pkmproject/models/sos_message.dart';
import 'package:pkmproject/services/ble_protocol.dart';
import 'package:pkmproject/utils/sos_status_priority.dart';

class ForwardingPolicy {
  const ForwardingPolicy({
    this.mode = MeshConfig.forwardingMode,
    this.adaptiveBackoffBase = MeshConfig.adaptiveBackoffBase,
    this.adaptiveBackoffMax = MeshConfig.adaptiveBackoffMax,
  });

  final ForwardingMode mode;
  final Duration adaptiveBackoffBase;
  final Duration adaptiveBackoffMax;

  ForwardingDecision decideSos({
    required BlePacket packet,
    required int nowMs,
    SOSMessage? existingMessage,
    int? ownSenderCrc,
  }) {
    if (packet.isAck ||
        packet.latitude == null ||
        packet.longitude == null ||
        !_isCoordinateValid(packet.latitude!, -90.0, 90.0) ||
        !_isCoordinateValid(packet.longitude!, -180.0, 180.0) ||
        packet.timestampMs > nowMs + MeshConfig.maxClockSkew.inMilliseconds ||
        packet.hopCount < 0) {
      return const ForwardingDecision(
        shouldStore: false,
        shouldRelay: false,
        reason: ForwardingDecisionReason.dropInvalid,
      );
    }

    if (ownSenderCrc != null && packet.senderCrc == ownSenderCrc) {
      return const ForwardingDecision(
        shouldStore: false,
        shouldRelay: false,
        reason: ForwardingDecisionReason.dropOwnPacket,
      );
    }

    if (_isSuppressedByAck(existingMessage, packet)) {
      return const ForwardingDecision(
        shouldStore: false,
        shouldRelay: false,
        reason: ForwardingDecisionReason.dropAcked,
      );
    }

    final staleOrDuplicate = _staleOrDuplicateReason(packet, existingMessage);
    if (staleOrDuplicate != null) {
      return ForwardingDecision(
        shouldStore: false,
        shouldRelay: false,
        reason: staleOrDuplicate,
      );
    }

    final nextHopCount = _saturateHop(packet.hopCount + 1);
    if (mode == ForwardingMode.basicFlooding) {
      return ForwardingDecision(
        shouldStore: true,
        shouldRelay: true,
        reason: ForwardingDecisionReason.relayAccepted,
        nextHopCount: nextHopCount,
      );
    }

    if (packet.status == SOSMessageStatus.cancelled ||
        packet.status == SOSMessageStatus.resolved) {
      return ForwardingDecision(
        shouldStore: true,
        shouldRelay: true,
        reason: ForwardingDecisionReason.relayAccepted,
        nextHopCount: nextHopCount,
      );
    }

    if (_hasNewerTimestamp(packet, existingMessage)) {
      return ForwardingDecision(
        shouldStore: true,
        shouldRelay: true,
        reason: ForwardingDecisionReason.relayAccepted,
        nextHopCount: nextHopCount,
      );
    }

    final lastRelayedAt = existingMessage?.lastRelayedAt ?? 0;
    final backoff = adaptiveBackoffForRelayCount(
      existingMessage?.relayCount ?? 0,
    );
    if (lastRelayedAt > 0 && nowMs - lastRelayedAt < backoff.inMilliseconds) {
      return ForwardingDecision(
        shouldStore: true,
        shouldRelay: false,
        reason: ForwardingDecisionReason.dropCooldown,
        nextEligibleAt: lastRelayedAt + backoff.inMilliseconds,
      );
    }

    return ForwardingDecision(
      shouldStore: true,
      shouldRelay: true,
      reason: ForwardingDecisionReason.relayAccepted,
      nextHopCount: nextHopCount,
    );
  }

  bool _isSuppressedByAck(SOSMessage? message, BlePacket packet) {
    if (message == null) return false;
    final hasAckState =
        message.localState == 'acked' ||
        message.localState == 'synced' ||
        message.ackReceivedAt != null;
    if (!hasAckState) return false;
    final ackTimestamp = message.ackReceivedAt;
    if (ackTimestamp == null) return false;
    return ackTimestamp >= packet.timestampMs;
  }

  bool _hasNewerTimestamp(BlePacket packet, SOSMessage? message) {
    if (message == null) return false;
    return packet.timestampMs > message.updatedAt;
  }

  ForwardingDecisionReason? _staleOrDuplicateReason(
    BlePacket packet,
    SOSMessage? message,
  ) {
    if (message == null) return null;
    if (message.updatedAt > packet.timestampMs) {
      return ForwardingDecisionReason.dropStale;
    }
    if (message.updatedAt < packet.timestampMs) return null;
    if (message.status != packet.status) {
      return sosStatusPriority(packet.status) <=
              sosStatusPriority(message.status)
          ? ForwardingDecisionReason.dropStale
          : null;
    }

    final incomingBestHop = _saturateHop(packet.hopCount + 1);
    if (incomingBestHop < message.hopCount) return null;

    return ForwardingDecisionReason.dropDuplicate;
  }

  Duration adaptiveBackoffForRelayCount(int relayCount) {
    final exponent = relayCount.clamp(0, 8);
    final baseMs = adaptiveBackoffBase.inMilliseconds;
    final candidateMs = baseMs * (1 << exponent);
    final cappedMs = candidateMs > adaptiveBackoffMax.inMilliseconds
        ? adaptiveBackoffMax.inMilliseconds
        : candidateMs;
    return Duration(milliseconds: cappedMs);
  }

  int _saturateHop(int hopCount) {
    if (hopCount < 0) return 0;
    if (hopCount > MeshConfig.maxProtocolHop) {
      return MeshConfig.maxProtocolHop;
    }
    return hopCount;
  }

  bool _isCoordinateValid(double value, double min, double max) {
    return value.isFinite && value >= min && value <= max;
  }
}
