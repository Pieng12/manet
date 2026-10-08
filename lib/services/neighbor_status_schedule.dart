import 'dart:math';
import 'package:pkmproject/services/neighbor_status_controller.dart';

/// Local announcements only; this never marks a remote peer as HAVE.
class NeighborStatusSchedule {
  NeighborStatusSchedule(this.parameters);
  final NeighborParameters parameters;
  int nextAt = 0;
  String reason = 'DISCOVERY';
  List<String> _inventory = [];
  final Set<String> _forwarded = {};
  bool _announcement = false, _stable = false, _discovered = false;
  late int _maintenance = parameters.statusMinPeriodMs;
  late int _emptyRetry = parameters.emptyRetryMinMs;

  bool get firstForwardComplete =>
      _inventory.isNotEmpty && _inventory.every(_forwarded.contains);
  List<String> get inventory => List.unmodifiable(_inventory);
  void start(int now, int jitter) {
    _inventory = [];
    _forwarded.clear();
    _announcement = false;
    _stable = false;
    _discovered = false;
    _maintenance = parameters.statusMinPeriodMs;
    _emptyRetry = parameters.emptyRetryMinMs;
    reason = 'DISCOVERY';
    nextAt = now + 1000 + jitter;
  }

  bool syncInventory(List<String> states, int now, int jitter) {
    final sorted = [...states]..sort();
    if (sorted.join('|') == _inventory.join('|')) return false;
    final pending = _announcement;
    _inventory = sorted;
    _forwarded.clear();
    _stable = false;
    _maintenance = parameters.statusMinPeriodMs;
    _emptyRetry = parameters.emptyRetryMinMs;
    _announcement = states.isNotEmpty;
    reason = states.isEmpty || !_discovered ? 'DISCOVERY' : 'STATE_CHANGED';
    final changedAt =
        now + (states.isEmpty ? 1000 + jitter : parameters.dataGraceMs);
    nextAt = _discovered && !pending ? changedAt : min(nextAt, changedAt);
    return true;
  }

  void peerChanged(int now, int jitter) {
    _stable = false;
    _maintenance = parameters.statusMinPeriodMs;
    if (_inventory.isNotEmpty && !_announcement) {
      nextAt = min(nextAt, now + _maintenance + jitter);
    }
  }

  void stable(int now, bool allObservedHave, int jitter) {
    final value = firstForwardComplete && allObservedHave;
    if (value && !_stable) {
      _maintenance = parameters.statusPeriodMs;
      if (!_announcement) nextAt = now + _maintenance + jitter;
    }
    if (!value && _stable) {
      _maintenance = parameters.statusMinPeriodMs;
      if (!_announcement) nextAt = min(nextAt, now + _maintenance + jitter);
    }
    _stable = value;
  }

  bool dataSucceeded(String state, int now, bool allObservedHave, int jitter) {
    if (!_inventory.contains(state)) return false;
    _forwarded.add(state);
    if (!firstForwardComplete) return false;
    final coalesced = _announcement;
    _discovered = true;
    _announcement = false;
    stable(now, allObservedHave, jitter);
    reason = 'HEARTBEAT';
    nextAt = now + _maintenance + jitter;
    return coalesced;
  }

  void statusSucceeded(
    List<String> sent,
    int now,
    bool allObservedHave,
    int jitter,
  ) {
    if (([...sent]..sort()).join('|') != _inventory.join('|')) return;
    _discovered = true;
    _announcement = false;
    stable(now, allObservedHave, jitter);
    if (_inventory.isEmpty) {
      reason = 'INVENTORY_EMPTY';
      nextAt = now + _emptyRetry + jitter;
      _emptyRetry = min(_emptyRetry * 2, parameters.emptyRetryMaxMs);
    } else {
      reason = 'HEARTBEAT';
      nextAt = now + _maintenance + jitter;
      _maintenance = min(_maintenance * 2, parameters.statusPeriodMs);
    }
  }

  void failed(int now, int jitter) {
    reason = 'NATIVE_RETRY';
    nextAt = now + 1000 + jitter;
  }
}
