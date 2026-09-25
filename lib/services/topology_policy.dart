import 'dart:convert';

import 'package:pkmproject/models/experiment_session.dart';
import 'package:pkmproject/models/sos_message.dart';
import 'package:pkmproject/services/ble_protocol.dart';
import 'package:pkmproject/config/mesh_config.dart';

class TopologyDecision {
  const TopologyDecision({
    required this.acceptForState,
    required this.relay,
    this.countAsLogicalDuplicate = false,
    this.countAsTrickleConsistency = false,
    this.countAsTrickleInconsistency = false,
    required this.reason,
  });

  final bool acceptForState;
  final bool relay;
  final bool countAsLogicalDuplicate;
  final bool countAsTrickleConsistency;
  final bool countAsTrickleInconsistency;
  final String reason;

  bool get acceptState => acceptForState;

  bool get isTopologyIgnored =>
      !acceptForState &&
      !countAsLogicalDuplicate &&
      !countAsTrickleConsistency &&
      !countAsTrickleInconsistency;
}

class TopologyPolicy {
  const TopologyPolicy();

  TopologyDecision evaluate({
    required BlePacket packet,
    required ExperimentSession? session,
    SOSMessage? existingMessage,
    String? observerKey,
    int? trialStartedAt,
  }) {
    if (session == null || session.sessionKind != 'RESEARCH') {
      return const TopologyDecision(
        acceptForState: true,
        relay: true,
        reason: 'AUTO_SESSION',
      );
    }
    if (!session.protocolActive) {
      return const TopologyDecision(
        acceptForState: false,
        relay: false,
        reason: 'NODE_INACTIVE',
      );
    }
    if (trialStartedAt != null && packet.timestampMs + 999 < trialStartedAt) {
      return const TopologyDecision(
        acceptForState: false,
        relay: false,
        reason: 'PREVIOUS_TRIAL_PACKET',
      );
    }
    if (!_observerAllowed(session.allowedAdvertisersJson, observerKey)) {
      return const TopologyDecision(
        acceptForState: false,
        relay: false,
        reason: 'ADVERTISER_NOT_ALLOWED',
      );
    }

    final role = session.nodeRole?.toUpperCase() ?? 'OBSERVER';
    if (role == 'SOURCE') {
      return const TopologyDecision(
        acceptForState: false,
        relay: false,
        reason: 'SOURCE_RX_IGNORED',
      );
    }

    final expectedHop = session.expectedHopIn;
    if (expectedHop != null && packet.hopCount != expectedHop) {
      final peerHop = expectedHop >= MeshConfig.maxProtocolHop
          ? MeshConfig.maxProtocolHop
          : expectedHop + 1;
      final sameMessage =
          existingMessage != null &&
          packet.messageKey == existingMessage.messageKey;
      if (role == 'RELAY' && packet.hopCount == peerHop && sameMessage) {
        final sameState =
            packet.stateIdentity.value == existingMessage.stateIdentity.value;
        return TopologyDecision(
          acceptForState: false,
          relay: false,
          countAsLogicalDuplicate: sameState,
          countAsTrickleConsistency: sameState,
          countAsTrickleInconsistency: !sameState,
          reason: sameState
              ? 'PARALLEL_RELAY_CONSISTENT'
              : 'PARALLEL_RELAY_INCONSISTENT',
        );
      }
      return const TopologyDecision(
        acceptForState: false,
        relay: false,
        reason: 'UNEXPECTED_HOP',
      );
    }

    return switch (role) {
      'DESTINATION' => const TopologyDecision(
        acceptForState: true,
        relay: false,
        reason: 'DESTINATION_ACCEPT',
      ),
      'RELAY' => const TopologyDecision(
        acceptForState: true,
        relay: true,
        reason: 'RELAY_ACCEPT',
      ),
      'GATEWAY' || 'OBSERVER' => const TopologyDecision(
        acceptForState: true,
        relay: false,
        reason: 'OBSERVE_ONLY',
      ),
      _ => const TopologyDecision(
        acceptForState: false,
        relay: false,
        reason: 'UNKNOWN_ROLE',
      ),
    };
  }

  bool _observerAllowed(String? raw, String? observerKey) {
    if (raw == null || raw.trim().isEmpty) return true;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return false;
      final allowed = decoded.map((value) => value.toString()).toSet();
      return observerKey != null && allowed.contains(observerKey);
    } catch (_) {
      return false;
    }
  }
}
