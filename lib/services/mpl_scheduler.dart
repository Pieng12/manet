import 'dart:math';

import 'package:pkmproject/models/message_identity.dart';
import 'package:pkmproject/services/ble_protocol.dart';
import 'package:pkmproject/services/neighbor_status_controller.dart';
import 'package:pkmproject/services/neighbor_transport.dart';

/// BLE adaptation of RFC 7731 timers; stopping a timer never deletes its buffer.
class MplParameters {
  static const defaults = <String, int>{
    'mpl_data_imin_ms': 8000,
    'mpl_data_imax_ms': 256000,
    'mpl_data_k': 1,
    'mpl_data_expirations': 5,
    'mpl_control_imin_ms': 4000,
    'mpl_control_imax_ms': 32000,
    'mpl_control_k': 1,
    'mpl_control_expirations': 4,
    'mpl_repair_cooldown_ms': 8000,
    'mpl_repair_budget': 2,
    'mpl_repair_expiry_ms': 60000,
    'mpl_bootstrap_opportunities': 2,
    'mpl_retry_ms': 1000,
    'mpl_retry_limit': 3,
    'mpl_probe_interval_ms': 60000,
    'mpl_probe_limit': 0,
    'mpl_freshness_ms': 150000,
    'mpl_discovery_jitter_ms': 1500,
  };
  MplParameters([Map<String, dynamic> values = const {}])
    : values = {
        for (final e in defaults.entries)
          e.key: values[e.key] as int? ?? e.value,
      } {
    for (final e in this.values.entries) {
      if (e.value < 0 || e.value > 0x1fffffff) {
        throw ArgumentError('Invalid MPL parameter: ${e.key}');
      }
    }
    for (final kind in ['data', 'control']) {
      final imin = this['${kind}_imin_ms'], imax = this['${kind}_imax_ms'];
      if (imin < 2000 ||
          imax < imin ||
          imax % imin != 0 ||
          ((imax ~/ imin) & ((imax ~/ imin) - 1)) != 0 ||
          this['${kind}_k'] < 1 ||
          this['${kind}_expirations'] < 1 ||
          this['${kind}_expirations'] > 32) {
        throw ArgumentError('Unsafe MPL $kind timer');
      }
    }
    if (this['repair_cooldown_ms'] < this['data_imin_ms'] ||
        this['repair_expiry_ms'] < this['repair_cooldown_ms'] ||
        this['repair_budget'] < 1 ||
        this['repair_budget'] > 8 ||
        this['bootstrap_opportunities'] > 8 ||
        this['retry_limit'] < 1 ||
        this['retry_limit'] > 8 ||
        this['retry_ms'] < 250 ||
        this['freshness_ms'] < this['control_imin_ms'] ||
        this['probe_limit'] > 8 ||
        this['probe_interval_ms'] < this['control_imax_ms']) {
      throw ArgumentError('Unsafe MPL repair/discovery bounds');
    }
  }
  final Map<String, int> values;
  int operator [](String key) => values['mpl_$key']!;
}

typedef MplDiagnostic = void Function(Map<String, Object> event);

class MplTimer {
  MplTimer(this.kind, this.key, this.parameters, this.random, this.emit);
  final String kind, key;
  final MplParameters parameters;
  final Random random;
  final MplDiagnostic emit;
  bool active = false, evaluated = false, pending = false;
  int interval = 0, start = 0, transmit = 0, end = 0, c = 0, e = 0;
  int generation = 0, retryAt = 0, attempts = 0;
  int _lastAdvancedAt = 0;
  String reason = 'NEW_STATE';
  int get k => parameters['${kind}_k'];
  int get nextAt => !active
      ? max(end, _lastAdvancedAt) + 86400000
      : pending
      ? retryAt
      : evaluated
      ? end
      : transmit;
  Map<String, Object> fields(int now) => {
    'timer_kind': kind,
    'timer_key': key,
    'generation': generation,
    'interval_ms': interval,
    'interval_started_at_monotonic_ms': start,
    'transmit_at_monotonic_ms': transmit,
    'interval_end_at_monotonic_ms': end,
    'consistency_count': c,
    'k': k,
    'expiration_count': e,
    'expiration_limit': parameters['${kind}_expirations'],
    'active': active,
    'monotonic_ms': now,
    'reason': reason,
  };
  void log(String event, int now, [Map<String, Object> extra = const {}]) =>
      emit({...fields(now), ...extra, 'event': 'MPL_$event'});
  void _interval(int at, int size) {
    start = at;
    interval = size;
    end = at + size;
    transmit = at + size ~/ 2 + random.nextInt(size - size ~/ 2);
    c = 0;
    evaluated = false;
    pending = false;
    attempts = 0;
    generation++;
    log('INTERVAL_STARTED', at);
  }

  bool reset(int now, String cause, {bool external = false}) {
    advance(now);
    reason = cause;
    // RFC 6206: repeated inconsistencies at Imin must not keep moving t.
    if (active && interval == parameters['${kind}_imin_ms'] && !external) {
      e = 0;
      log('RESET_DEFERRED', now, {'reason': 'ALREADY_AT_IMIN'});
      return false;
    }
    active = true;
    e = 0;
    _interval(now, parameters['${kind}_imin_ms']);
    log('TIMER_RESTARTED', now);
    return true;
  }

  void advance(int now) {
    _lastAdvancedAt = max(_lastAdvancedAt, now);
    while (active && now >= end) {
      if (!evaluated || pending) {
        log('TX_MISSED', now, {'reason': 'SCHEDULER_LATE'});
      }
      e++;
      log('INTERVAL_ENDED', end);
      if (e >= parameters['${kind}_expirations']) {
        active = false;
        pending = false;
        log('TIMER_STOPPED', end, {
          'reason': 'EXPIRATION_LIMIT',
          'buffer_retained': true,
        });
        break;
      }
      _interval(end, min(interval * 2, parameters['${kind}_imax_ms']));
    }
  }

  void consistent(
    int physicalAt,
    int now, {
    Map<String, Object> proof = const {},
  }) {
    advance(now);
    if (!active || physicalAt < start || physicalAt >= end) return;
    final before = c++;
    log('C_INCREMENT', now, {
      'c_before': before,
      'c_after': c,
      'physical_received_monotonic_ms': physicalAt,
      ...proof,
    });
  }

  bool opportunity(int now, {bool protected = false, bool slot = true}) {
    advance(now);
    if (!active || now < nextAt || (evaluated && !pending)) return false;
    if (!evaluated) {
      evaluated = true;
      log('TX_OPPORTUNITY', now, {'override': protected});
      if (c >= k && !protected) {
        log('TX_SUPPRESSED', now);
        return false;
      }
      pending = true;
      retryAt = now;
      log('TX_ALLOWED', now, {'override': protected});
    }
    if (!slot) {
      retryAt = min(end, now + 100);
      log('TX_DEFERRED', now, {'reason': 'DATA_SLOT_PROTECTED'});
      return false;
    }
    return now < end;
  }

  bool nativeResult(int token, int now, bool success) {
    if (token != generation || !active || !pending || now >= end) {
      log('CALLBACK_IGNORED', now, {'callback_generation': token});
      return false;
    }
    log(success ? 'NATIVE_STARTED' : 'NATIVE_FAILED', now);
    if (success) {
      pending = false;
      return true;
    }
    attempts++;
    if (attempts >= parameters['retry_limit']) {
      pending = false;
      log('TX_MISSED', now, {'reason': 'NATIVE_RETRY_EXHAUSTED'});
    } else {
      retryAt = min(end, now + parameters['retry_ms']);
    }
    return false;
  }
}

class _Repair {
  _Repair(this.state, this.peer, this.boot, this.until);
  final String state;
  final int peer, boot, until;
  int used = 0, next = 0, resets = 0;
  bool expiryReported = false;
}

class _ControlDemand {
  _ControlDemand(
    this.peer,
    this.boot,
    this.signature,
    this.until,
    this.offered,
  );
  final int peer, boot, until;
  final String signature;
  final List<StateIdentity> offered;
  int next = 0, resets = 0;
}

class MplScheduler {
  MplScheduler({
    required this.scope,
    MplParameters? parameters,
    Random? random,
    MplDiagnostic? diagnostic,
  }) : parameters = parameters ?? MplParameters(),
       random = random ?? Random(),
       diagnostic = diagnostic ?? ((_) {}) {
    control = MplTimer(
      'control',
      'scope:$scope',
      this.parameters,
      this.random,
      _emit,
    );
    neighbors = NeighborStatusController(
      scope: scope,
      parameters: NeighborParameters(
        // Only evidence/freshness is reused; MPL, not this legacy period, schedules CONTROL.
        statusPeriodMs: 1000,
        freshnessMs: this.parameters['freshness_ms'],
      ),
    );
  }
  static const semantics = 'resqmesh-trickle-mpl-v1';
  final int scope;
  final MplParameters parameters;
  final Random random;
  final MplDiagnostic diagnostic;
  late final MplTimer control;
  late final NeighborStatusController neighbors;
  final Map<String, MplTimer> data = {};
  final Map<String, StateIdentity> buffer = {};
  final Map<String, _Repair> _repairs = {};
  final Map<int, _ControlDemand> _demands = {};
  int bootstrap = 0, inventoryGeneration = 0, probes = 0, probeAt = 0;
  int _now = 0;
  bool get deficit => _demands.values.any(
    (d) =>
        d.until > _now &&
        neighbors
            .peers(_now)
            .any(
              (p) =>
                  p['transmitter_id'] == d.peer &&
                  p['boot_id'] == d.boot &&
                  p['fresh'] == true,
            ) &&
        d.offered.any((p) => !buffer.values.any((s) => covers(s, p))),
  );
  void _emit(Map<String, Object> fields) => diagnostic({
    ...fields,
    'scope': scope,
    'scheduler_semantics': semantics,
    'inventory_generation': inventoryGeneration,
  });
  void discover(int now) {
    bootstrap = parameters['bootstrap_opportunities'];
    control.reset(
      now + random.nextInt(parameters['discovery_jitter_ms'] + 1),
      'BLE_BOOTSTRAP',
      external: true,
    );
    _emit({
      'event': 'MPL_DISCOVERY',
      'monotonic_ms': now,
      'bootstrap_remaining': bootstrap,
    });
  }

  void sync(Iterable<StateIdentity> inventory, int now) {
    final next = {for (final state in inventory) state.value: state};
    final changed =
        next.keys.toSet().difference(buffer.keys.toSet()).isNotEmpty ||
        buffer.keys.toSet().difference(next.keys.toSet()).isNotEmpty;
    data.removeWhere((key, timer) => !next.containsKey(key));
    _repairs.removeWhere((key, repair) => !next.containsKey(repair.state));
    for (final state in next.values) {
      if (!data.containsKey(state.value)) {
        data[state.value] = MplTimer(
          'data',
          state.value,
          parameters,
          random,
          _emit,
        )..reset(now, 'BUFFER_INSERT');
      }
    }
    buffer
      ..clear()
      ..addAll(next);
    if (changed) {
      inventoryGeneration++;
      control.reset(now, 'INVENTORY_CHANGED');
    }
    tick(now);
  }

  void tick(int now) {
    _now = now;
    control.advance(now);
    for (final timer in data.values) {
      timer.advance(now);
    }
    for (final change in neighbors.takeChanges(now)) {
      _emit({...change, 'monotonic_ms': now});
    }
    for (final repair in _repairs.values) {
      if (now >= repair.until && !repair.expiryReported) {
        repair.expiryReported = true;
        _emit({
          'event': 'MPL_REPAIR_EXPIRED',
          'monotonic_ms': now,
          'timer_key': repair.state,
          'peer_id': repair.peer,
          'peer_boot': repair.boot,
          'episode_until': repair.until,
        });
      }
      if (now >= repair.until ||
          repair.used >= parameters['repair_budget'] ||
          repair.resets >= parameters['repair_budget']) {
        continue;
      }
      final state = buffer[repair.state];
      if (state == null ||
          neighbors.knowledge(repair.peer, state, now) !=
              NeighborKnowledge.missing) {
        continue;
      }
      if (now >= repair.next) {
        repair.resets++;
        data[repair.state]!.reset(now, 'MISSING_PEER');
        // Reserve reset eligibility, not successful transmission budget.
        repair.next = now + parameters['repair_cooldown_ms'];
        _emit({
          'event': 'MPL_REPAIR_RESET',
          'timer_key': repair.state,
          'peer_id': repair.peer,
          'peer_boot': repair.boot,
          'monotonic_ms': now,
          'budget_used': repair.used,
          'budget_limit': parameters['repair_budget'],
          'episode_until': repair.until,
          'reset_budget_used': repair.resets,
        });
        _emit({
          'event': 'MPL_REPAIR_DEFERRED',
          'monotonic_ms': now,
          'timer_key': repair.state,
          'peer_id': repair.peer,
          'peer_boot': repair.boot,
          'reason': 'RESET_COOLDOWN',
          'next_eligible_at': repair.next,
        });
      }
    }
    for (final demand in _demands.values) {
      final peer = neighbors
          .peers(now)
          .where((p) => p['transmitter_id'] == demand.peer);
      if (now >= demand.until ||
          demand.resets >= parameters['repair_budget'] ||
          peer.isEmpty ||
          peer.single['fresh'] != true ||
          now < demand.next) {
        continue;
      }
      demand.resets++;
      control.reset(now, 'INVENTORY_MISMATCH');
      demand.next = now + parameters['repair_cooldown_ms'];
    }
    if (!control.active && probes < parameters['probe_limit']) {
      if (probeAt == 0) probeAt = now + parameters['probe_interval_ms'];
      if (now >= probeAt) {
        probes++;
        probeAt = 0;
        discover(now);
      }
    }
  }

  bool receive(
    NeighborFrame frame,
    int physicalAt,
    int now, {
    bool newState = false,
  }) {
    if (frame.type == NeighborFrameType.status &&
        frame.inventory.map((s) => s.messageKey.senderCrc).toSet().length !=
            frame.inventory.length) {
      _emit({
        'event': 'MPL_CONTROL_CLASSIFIED',
        'monotonic_ms': now,
        'reason': 'AMBIGUOUS_UNKNOWN',
        'peer_id': frame.transmitter,
        'peer_boot': frame.boot,
      });
      return false;
    }
    if (!neighbors.observe(frame, physicalAt, now)) return false;
    if (_demands[frame.transmitter]?.boot != frame.boot) {
      _demands.remove(frame.transmitter);
    }
    final proof = <String, Object>{
      'peer_id': frame.transmitter,
      'peer_boot': frame.boot,
      'transmission_sequence': frame.sequence,
    };
    _emit({
      'event': 'MPL_RX_CLASSIFIED',
      'monotonic_ms': now,
      'physical_received_monotonic_ms': physicalAt,
      'peer_id': frame.transmitter,
      'peer_boot': frame.boot,
      'transmission_sequence': frame.sequence,
      'frame_type': frame.type.name,
      'snapshot_complete': frame.complete,
      'inventory': frame.inventory.map((s) => s.value).join('|'),
    });
    _repairs.removeWhere(
      (key, r) =>
          r.peer == frame.transmitter &&
          (r.boot != frame.boot ||
              (buffer.containsKey(r.state) &&
                  neighbors.knowledge(r.peer, buffer[r.state]!, now) ==
                      NeighborKnowledge.have)),
    );
    if (frame.type == NeighborFrameType.data) {
      final state = frame.inner == null
          ? null
          : BlePacket.unpack(frame.inner!)?.stateIdentity;
      if (state != null && !newState) {
        data[state.value]?.consistent(physicalAt, now, proof: proof);
      }
      return true;
    }
    if (!frame.complete || buffer.length > NeighborFrame.capacity) {
      _emit({
        'event': 'MPL_CONTROL_CLASSIFIED',
        'monotonic_ms': now,
        'reason': 'PARTIAL_UNKNOWN',
        'peer_id': frame.transmitter,
        'peer_boot': frame.boot,
      });
      return true;
    }
    final missing = buffer.values
        .where(
          (s) =>
              neighbors.knowledge(frame.transmitter, s, now) ==
              NeighborKnowledge.missing,
        )
        .toList();
    final offered = frame.inventory
        .where((p) => !buffer.values.any((l) => covers(l, p)))
        .toList();
    if (missing.isEmpty && offered.isEmpty) {
      _demands.remove(frame.transmitter);
      control.consistent(physicalAt, now, proof: proof);
    } else {
      final sorted = ([
        for (final s in frame.inventory) s.value,
      ]..sort()).join('|');
      final signature = '$sorted@$inventoryGeneration';
      final previous = _demands[frame.transmitter];
      if (previous == null ||
          previous.boot != frame.boot ||
          previous.signature != signature) {
        _demands[frame.transmitter] = _ControlDemand(
          frame.transmitter,
          frame.boot,
          signature,
          now + parameters['repair_expiry_ms'],
          offered,
        );
      }
      for (final s in missing) {
        final key = '${s.value}|${frame.transmitter}|${frame.boot}';
        // An unchanged request with a new sequence is still the same bounded episode.
        final isNew = !_repairs.containsKey(key);
        _repairs.putIfAbsent(
          key,
          () => _Repair(
            s.value,
            frame.transmitter,
            frame.boot,
            now + parameters['repair_expiry_ms'],
          ),
        );
        if (isNew) {
          _emit({
            'event': 'MPL_REPAIR_PENDING',
            'timer_key': s.value,
            'monotonic_ms': now,
            'peer_id': frame.transmitter,
            'peer_boot': frame.boot,
            'budget_used': 0,
            'budget_limit': parameters['repair_budget'],
            'episode_until': now + parameters['repair_expiry_ms'],
          });
        }
      }
      tick(now);
    }
    _emit({
      'event': 'MPL_CONTROL_CLASSIFIED',
      'monotonic_ms': now,
      'reason': missing.isEmpty && offered.isEmpty ? 'CONSISTENT' : 'MISMATCH',
      'peer_id': frame.transmitter,
      'peer_boot': frame.boot,
      'missing_states': missing.map((s) => s.value).join('|'),
      'offered_states': offered.map((s) => s.value).join('|'),
    });
    return true;
  }

  static bool covers(StateIdentity local, StateIdentity peer) {
    if (local.messageKey.senderCrc != peer.messageKey.senderCrc) return false;
    if (local.messageKey.protocolTimestampMs !=
        peer.messageKey.protocolTimestampMs) {
      return local.messageKey.protocolTimestampMs >
          peer.messageKey.protocolTimestampMs;
    }
    int priority(int s) => s == 1
        ? 0
        : s == 0
        ? 1
        : 2;
    return local.value == peer.value ||
        local.isAck ||
        (!peer.isAck &&
            priority(local.statusIndex) > priority(peer.statusIndex));
  }

  bool repairProtected(String state, int now) => _repairs.values.any(
    (r) =>
        r.state == state &&
        now < r.until &&
        r.used < parameters['repair_budget'] &&
        buffer.containsKey(state) &&
        neighbors.knowledge(r.peer, buffer[state]!, now) ==
            NeighborKnowledge.missing,
  );
  bool dataDue(String state, int now) {
    tick(now);
    return data[state]?.opportunity(
          now,
          protected: repairProtected(state, now),
        ) ??
        false;
  }

  bool controlDue(int now, {bool slot = true}) {
    tick(now);
    return control.opportunity(
      now,
      protected: bootstrap > 0 || deficit,
      slot: slot,
    );
  }

  void dataResult(String state, int token, int now, bool success) {
    if (data[state]?.nativeResult(token, now, success) != true) return;
    for (final r in _repairs.values.where(
      (r) =>
          r.state == state &&
          now < r.until &&
          r.used < parameters['repair_budget'],
    )) {
      r.used++;
      _emit({
        'event': 'MPL_REPAIR_COMPLETED',
        'timer_key': state,
        'peer_id': r.peer,
        'peer_boot': r.boot,
        'budget_used': r.used,
        'budget_limit': parameters['repair_budget'],
        'episode_until': r.until,
        'monotonic_ms': now,
      });
    }
  }

  void controlResult(int token, int inventoryToken, int now, bool success) {
    if (inventoryToken != inventoryGeneration) {
      control.log('CALLBACK_IGNORED', now, {
        'reason': 'INVENTORY_GENERATION_CHANGED',
        'callback_inventory_generation': inventoryToken,
      });
      return;
    }
    if (control.nativeResult(token, now, success) && bootstrap > 0) bootstrap--;
  }

  int get nextControlAt {
    var next = min(control.nextAt, probeAt == 0 ? control.nextAt : probeAt);
    for (final r in _repairs.values) {
      if (r.until > _now &&
          r.used < parameters['repair_budget'] &&
          r.resets < parameters['repair_budget'] &&
          buffer.containsKey(r.state) &&
          neighbors.knowledge(r.peer, buffer[r.state]!, _now) ==
              NeighborKnowledge.missing) {
        next = min(next, r.next);
      }
    }
    for (final d in _demands.values) {
      if (d.until > _now &&
          d.resets < parameters['repair_budget'] &&
          neighbors
              .peers(_now)
              .any(
                (p) => p['transmitter_id'] == d.peer && p['fresh'] == true,
              )) {
        next = min(next, d.next);
      }
    }
    return next;
  }
}
