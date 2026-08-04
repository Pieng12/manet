import 'package:pkmproject/config/mesh_config.dart';
import 'package:pkmproject/models/forwarding_decision.dart';
import 'package:pkmproject/models/sos_message.dart';
import 'package:pkmproject/services/ble_protocol.dart';

class ForwardingPolicy {
  const ForwardingPolicy({
    this.mode = MeshConfig.forwardingMode,
    this.maxHop = MeshConfig.defaultMaxHop,
    this.maxRelayCount = MeshConfig.maxRelayCount,
    this.messageLifetime = MeshConfig.defaultMessageLifetime,
    this.relayCooldown = MeshConfig.relayCooldown,
  });

  final ForwardingMode mode;
  final int maxHop;
  final int maxRelayCount;
  final Duration messageLifetime;
  final Duration relayCooldown;

  ForwardingDecision decideSos({
    required BlePacket packet,
    required int nowMs,
    SOSMessage? existingMessage,
    int? ownSenderCrc,
  }) {
    if (packet.isAck ||
        packet.latitude == null ||
        packet.longitude == null ||
        packet.hopCount > MeshConfig.maxProtocolHop) {
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

    final expiresAt = packet.timestampMs + messageLifetime.inMilliseconds;
    if (nowMs >= expiresAt) {
      return const ForwardingDecision(
        shouldStore: true,
        shouldRelay: false,
        reason: ForwardingDecisionReason.dropExpired,
      );
    }

    if (packet.hopCount >= maxHop) {
      return ForwardingDecision(
        shouldStore: true,
        shouldRelay: false,
        reason: ForwardingDecisionReason.dropMaxHop,
        nextHopCount: packet.hopCount,
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

    final nextHopCount = packet.hopCount + 1;
    if (mode == ForwardingMode.basicFlooding) {
      return ForwardingDecision(
        shouldStore: true,
        shouldRelay: true,
        reason: ForwardingDecisionReason.relayAccepted,
        nextHopCount: nextHopCount,
      );
    }

    if ((existingMessage?.relayCount ?? 0) >= maxRelayCount) {
      return const ForwardingDecision(
        shouldStore: true,
        shouldRelay: false,
        reason: ForwardingDecisionReason.dropMaxRelay,
      );
    }

    final lastRelayedAt = existingMessage?.lastRelayedAt ?? 0;
    if (lastRelayedAt > 0 &&
        nowMs - lastRelayedAt < relayCooldown.inMilliseconds) {
      return ForwardingDecision(
        shouldStore: true,
        shouldRelay: false,
        reason: ForwardingDecisionReason.dropCooldown,
        nextEligibleAt: lastRelayedAt + relayCooldown.inMilliseconds,
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
    return message.updatedAt >= packet.timestampMs;
  }
}
