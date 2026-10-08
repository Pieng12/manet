import 'package:pkmproject/models/message_identity.dart';
import 'package:pkmproject/services/ble_protocol.dart';
import 'package:pkmproject/services/neighbor_transport.dart';

enum NeighborKnowledge { have, missing, unknown }

class NeighborParameters {
  const NeighborParameters({
    this.statusPeriodMs = 12000,
    this.statusBurstMs = 500,
    this.freshnessMs = 45000,
    this.discoveryJitterMs = 1500,
    this.resetCooldownMs = 8000,
    this.capacity = 16,
    this.policy = 'periodic_v1',
    this.statusMinPeriodMs = 15000,
    this.emptyRetryMinMs = 4000,
    this.emptyRetryMaxMs = 32000,
    this.dataGraceMs = 10000,
  });
  final String policy;
  bool get adaptive => policy == 'adaptive_v2';
  final int statusPeriodMs,
      statusBurstMs,
      freshnessMs,
      discoveryJitterMs,
      resetCooldownMs,
      capacity,
      statusMinPeriodMs,
      emptyRetryMinMs,
      emptyRetryMaxMs,
      dataGraceMs;
  factory NeighborParameters.fromMap(Map<String, dynamic> values) {
    final policy = values['neighbor_status_policy'] as String? ?? 'periodic_v1';
    return NeighborParameters(
      policy: policy,
      statusPeriodMs:
          values['status_period_ms'] as int? ??
          (policy == 'adaptive_v2' ? 60000 : 12000),
      freshnessMs:
          values['freshness_ms'] as int? ??
          (policy == 'adaptive_v2' ? 150000 : 45000),
      statusBurstMs: values['status_burst_ms'] as int? ?? 500,
      discoveryJitterMs: values['discovery_jitter_ms'] as int? ?? 1500,
      resetCooldownMs: values['reset_cooldown_ms'] as int? ?? 8000,
      capacity: values['neighbor_capacity'] as int? ?? 16,
      statusMinPeriodMs: values['status_min_period_ms'] as int? ?? 15000,
      emptyRetryMinMs: values['empty_retry_min_ms'] as int? ?? 4000,
      emptyRetryMaxMs: values['empty_retry_max_ms'] as int? ?? 32000,
      dataGraceMs: values['data_grace_ms'] as int? ?? 10000,
    );
  }
  Map<String, Object> toMap() => {
    'neighbor_status_policy': policy,
    'status_period_ms': statusPeriodMs,
    'freshness_ms': freshnessMs,
    'status_burst_ms': statusBurstMs,
    'discovery_jitter_ms': discoveryJitterMs,
    'reset_cooldown_ms': resetCooldownMs,
    'neighbor_capacity': capacity,
    if (adaptive) ...{
      'status_min_period_ms': statusMinPeriodMs,
      'empty_retry_min_ms': emptyRetryMinMs,
      'empty_retry_max_ms': emptyRetryMaxMs,
      'data_grace_ms': dataGraceMs,
    },
  };
  void validate() {
    if (!{'periodic_v1', 'adaptive_v2'}.contains(policy) ||
        statusPeriodMs < 1000 ||
        statusPeriodMs > 0x7fffffff ~/ 4 ||
        freshnessMs > 0x7fffffff ||
        discoveryJitterMs > 0x7fffffff ~/ 4 ||
        statusBurstMs < 250 ||
        statusBurstMs > 2000 ||
        freshnessMs < statusPeriodMs * 2 ||
        discoveryJitterMs < 0 ||
        resetCooldownMs < 1000 ||
        capacity < 5 ||
        capacity > 64 ||
        (adaptive &&
            (statusMinPeriodMs < 1000 ||
                statusMinPeriodMs > statusPeriodMs ||
                emptyRetryMinMs < 1000 ||
                emptyRetryMaxMs < emptyRetryMinMs ||
                emptyRetryMaxMs > 0x7fffffff ~/ 4 ||
                dataGraceMs < 1000 ||
                dataGraceMs > 0x7fffffff ~/ 4 ||
                freshnessMs <
                    2 *
                        (statusPeriodMs +
                            discoveryJitterMs +
                            statusBurstMs)))) {
      throw ArgumentError('Unsafe neighbor parameters');
    }
  }
}

class _Neighbor {
  _Neighbor(this.boot, this.sequence, this.at, this.complete, this.states);
  final int boot, sequence, at;
  final bool complete;
  final List<StateIdentity> states;
}

class NeighborStatusController {
  NeighborStatusController({
    required this.scope,
    this.parameters = const NeighborParameters(),
  }) {
    parameters.validate();
  }
  final int scope;
  final NeighborParameters parameters;
  final Map<int, _Neighbor> _neighbors = {};
  final Set<String> _seen = {};
  final Set<String> _forwarded = {};
  final Set<int> _expired = {};
  final List<Map<String, Object>> _changes = [];
  int? _lastRepair;
  final Set<int> _repairPending = {};
  int? _reportedCooldown;
  bool peerChanged = false;

  bool observe(NeighborFrame frame, int receivedMonotonicMs, int nowMs) {
    peerChanged = false;
    if (frame.scope != scope ||
        receivedMonotonicMs > nowMs ||
        nowMs - receivedMonotonicMs > parameters.freshnessMs ||
        _seen.contains(frame.burstIdentity)) {
      return false;
    }
    final previous = _neighbors[frame.transmitter];
    if (previous == null && _neighbors.length >= parameters.capacity) {
      return false;
    }
    if (previous != null &&
        (receivedMonotonicMs < previous.at ||
            frame.boot < previous.boot ||
            (frame.boot == previous.boot &&
                frame.sequence <= previous.sequence))) {
      return false;
    }
    _seen.add(frame.burstIdentity);
    if (previous == null) {
      _changes.add({
        'event': 'NEIGHBOR_DISCOVERED',
        'transmitter_id': frame.transmitter,
        'boot_id': frame.boot,
        'transmission_sequence': frame.sequence,
        'scope': scope,
        'observed_at': receivedMonotonicMs,
      });
    }
    _expired.remove(frame.transmitter);
    final packet = frame.inner == null ? null : BlePacket.unpack(frame.inner!);
    final states = packet == null
        ? (frame.complete ? frame.inventory : <StateIdentity>[])
        : [packet.stateIdentity];
    final complete = frame.type == NeighborFrameType.status && frame.complete;
    peerChanged =
        previous == null ||
        previous.boot != frame.boot ||
        nowMs - previous.at > parameters.freshnessMs ||
        previous.states
            .map((s) => s.value)
            .toSet()
            .difference(states.map((s) => s.value).toSet())
            .isNotEmpty ||
        states
            .map((s) => s.value)
            .toSet()
            .difference(previous.states.map((s) => s.value).toSet())
            .isNotEmpty;
    if (previous == null ||
        previous.boot != frame.boot ||
        previous.complete != complete ||
        previous.states.map((s) => s.value).join('|') !=
            states.map((s) => s.value).join('|') ||
        nowMs - previous.at > parameters.freshnessMs) {
      _repairPending.add(frame.transmitter);
    }
    // Only the latest sequence per neighbor is required; bounded replay memory.
    if (_seen.length > parameters.capacity * 8) _seen.remove(_seen.first);
    _neighbors[frame.transmitter] = _Neighbor(
      frame.boot,
      frame.sequence,
      receivedMonotonicMs,
      complete,
      states,
    );
    return true;
  }

  NeighborKnowledge knowledge(int id, StateIdentity local, int nowMs) {
    final peer = _neighbors[id];
    if (peer == null ||
        nowMs < peer.at ||
        nowMs - peer.at > parameters.freshnessMs) {
      return NeighborKnowledge.unknown;
    }
    for (final state in peer.states) {
      if (state.value == local.value) return NeighborKnowledge.have;
      // A newer state is evidence not to repair backwards, including tombstones.
      if (state.messageKey.senderCrc == local.messageKey.senderCrc &&
          (state.messageKey.protocolTimestampMs >
                  local.messageKey.protocolTimestampMs ||
              (state.messageKey == local.messageKey &&
                  (state.isAck ||
                      _priority(state.statusIndex) >
                          _priority(local.statusIndex))))) {
        return NeighborKnowledge.have;
      }
    }
    return peer.complete
        ? NeighborKnowledge.missing
        : NeighborKnowledge.unknown;
  }

  static int _priority(int status) => switch (status) {
    1 => 0,
    0 => 1,
    _ => 2,
  };

  Map<int, NeighborKnowledge> snapshot(StateIdentity state, int nowMs) => {
    for (final id in _neighbors.keys) id: knowledge(id, state, nowMs),
  };

  List<Map<String, Object>> takeChanges(int nowMs) {
    for (final entry in _neighbors.entries) {
      if (nowMs - entry.value.at > parameters.freshnessMs &&
          _expired.add(entry.key)) {
        _changes.add({
          'event': 'NEIGHBOR_STATUS_EXPIRED',
          'transmitter_id': entry.key,
          'boot_id': entry.value.boot,
          'transmission_sequence': entry.value.sequence,
          'scope': scope,
          'status_age_ms': nowMs - entry.value.at,
        });
      }
    }
    final result = List<Map<String, Object>>.of(_changes);
    _changes.clear();
    return result;
  }

  List<Map<String, Object>> peers(int nowMs) => [
    for (final entry in _neighbors.entries)
      {
        'transmitter_id': entry.key,
        'boot_id': entry.value.boot,
        'sequence': entry.value.sequence,
        'status_age_ms': nowMs - entry.value.at,
        'complete': entry.value.complete,
        'fresh':
            nowMs >= entry.value.at &&
            nowMs - entry.value.at <= parameters.freshnessMs,
      },
  ];

  bool statusHasSlot(int nowMs, int? nextDataMs) =>
      nextDataMs == null || nextDataMs - nowMs > parameters.statusBurstMs + 250;

  String decision(
    StateIdentity state,
    int nowMs, {
    required bool firstForwardPending,
  }) {
    if (firstForwardPending && !_forwarded.contains(state.value)) {
      return 'INITIAL_FORWARD_PENDING';
    }
    final statuses = snapshot(state, nowMs).values;
    if (statuses.contains(NeighborKnowledge.missing)) return 'FRESH_MISSING';
    if (statuses.isEmpty || statuses.contains(NeighborKnowledge.unknown)) {
      return 'UNKNOWN_OR_NO_NEIGHBORS';
    }
    return 'ALL_OBSERVED_HAVE';
  }

  void started(StateIdentity state) => _forwarded.add(state.value);

  void requestMissingPeer(int transmitter, StateIdentity state, int nowMs) {
    if (parameters.adaptive &&
        knowledge(transmitter, state, nowMs) == NeighborKnowledge.missing) {
      _repairPending.add(transmitter);
    }
  }

  bool repairAllowed(
    StateIdentity state,
    int nowMs,
    int intervalMs,
    int iminMs,
  ) {
    if (_repairPending.isEmpty || intervalMs <= iminMs) {
      return false;
    }
    if (_lastRepair != null &&
        nowMs - _lastRepair! < parameters.resetCooldownMs) {
      if (_reportedCooldown != _lastRepair &&
          _repairPending.any(
            (id) => knowledge(id, state, nowMs) != NeighborKnowledge.have,
          )) {
        _reportedCooldown = _lastRepair;
        _changes.add({
          'event': 'REPAIR_DEFERRED_COOLDOWN',
          'scope': scope,
          'next_repair_eligible_at': _lastRepair! + parameters.resetCooldownMs,
          'reason': 'RESET_COOLDOWN',
        });
      }
      return false;
    }
    final values = _repairPending
        .map((id) => knowledge(id, state, nowMs))
        .toList();
    _repairPending.clear();
    if (!values.contains(NeighborKnowledge.missing) &&
        !values.contains(NeighborKnowledge.unknown)) {
      return false;
    }
    _lastRepair = nowMs;
    _reportedCooldown = null;
    return true;
  }
}
