import 'dart:convert';

import 'package:pkmproject/models/experiment_session.dart';
import 'package:pkmproject/services/ble_protocol.dart';

class TopologyDecision {
  const TopologyDecision({
    required this.acceptState,
    required this.relay,
    required this.reason,
  });

  final bool acceptState;
  final bool relay;
  final String reason;
}

class TopologyPolicy {
  const TopologyPolicy();

  TopologyDecision evaluate({
    required BlePacket packet,
    required ExperimentSession? session,
    String? observerKey,
    int? trialStartedAt,
  }) {
    if (session == null || session.sessionKind != 'RESEARCH') {
      return const TopologyDecision(
        acceptState: true,
        relay: true,
        reason: 'AUTO_SESSION',
      );
    }
    if (!session.protocolActive) {
      return const TopologyDecision(
        acceptState: false,
        relay: false,
        reason: 'NODE_INACTIVE',
      );
    }
    if (trialStartedAt != null && packet.timestampMs + 999 < trialStartedAt) {
      return const TopologyDecision(
        acceptState: false,
        relay: false,
        reason: 'PREVIOUS_TRIAL_PACKET',
      );
    }
    if (session.expectedHopIn != null &&
        packet.hopCount != session.expectedHopIn) {
      return const TopologyDecision(
        acceptState: false,
        relay: false,
        reason: 'UNEXPECTED_HOP',
      );
    }
    if (!_observerAllowed(session.allowedAdvertisersJson, observerKey)) {
      return const TopologyDecision(
        acceptState: false,
        relay: false,
        reason: 'ADVERTISER_NOT_ALLOWED',
      );
    }

    final role = session.nodeRole?.toUpperCase() ?? 'OBSERVER';
    return switch (role) {
      'SOURCE' => const TopologyDecision(
        acceptState: false,
        relay: false,
        reason: 'SOURCE_RX_IGNORED',
      ),
      'DESTINATION' => const TopologyDecision(
        acceptState: true,
        relay: false,
        reason: 'DESTINATION_ACCEPT',
      ),
      'RELAY' => const TopologyDecision(
        acceptState: true,
        relay: true,
        reason: 'RELAY_ACCEPT',
      ),
      'GATEWAY' || 'OBSERVER' => const TopologyDecision(
        acceptState: true,
        relay: false,
        reason: 'OBSERVE_ONLY',
      ),
      _ => const TopologyDecision(
        acceptState: false,
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
