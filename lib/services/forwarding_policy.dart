import 'package:pkmproject/config/mesh_config.dart';
import 'package:pkmproject/models/forwarding_decision.dart';
import 'package:pkmproject/models/sos_message.dart';
import 'package:pkmproject/services/ble_protocol.dart';

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

    if (_isAcked(existingMessage)) {
      return const ForwardingDecision(
        shouldStore: false,
        shouldRelay: false,
        reason: ForwardingDecisionReason.dropAcked,
      );
    }

    if (_isDuplicateOrOlder(packet, existingMessage)) {
      return const ForwardingDecision(
        shouldStore: false,
        shouldRelay: false,
        reason: ForwardingDecisionReason.dropDuplicate,
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

  bool _isAcked(SOSMessage? message) {
    if (message == null) return false;
    return message.localState == 'acked' ||
        message.localState == 'synced' ||
        message.ackReceivedAt != null;
  }

  bool _isDuplicateOrOlder(BlePacket packet, SOSMessage? message) {
    if (message == null) return false;
    if (message.updatedAt > packet.timestampMs) return true;
    if (message.updatedAt < packet.timestampMs) return false;
    if (message.status != packet.status) {
      return _statusPriority(packet.status) <= _statusPriority(message.status);
    }

    final incomingBestHop = _saturateHop(packet.hopCount + 1);
    if (incomingBestHop < message.hopCount) return false;

    return true;
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

  int _statusPriority(SOSMessageStatus status) {
    return switch (status) {
      SOSMessageStatus.active => 0,
      SOSMessageStatus.cancelled => 1,
      SOSMessageStatus.resolved => 1,
    };
  }
}
