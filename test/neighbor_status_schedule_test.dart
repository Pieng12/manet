import 'package:flutter_test/flutter_test.dart';
import 'package:pkmproject/services/neighbor_status_controller.dart';
import 'package:pkmproject/services/neighbor_status_schedule.dart';

void main() {
  final parameters = NeighborParameters.fromMap({
    'neighbor_status_policy': 'adaptive_v2',
  });
  NeighborStatusSchedule schedule() =>
      NeighborStatusSchedule(parameters)..start(0, 0);
  test('legacy defaults and adaptive parameters are explicit and safe', () {
    expect(NeighborParameters.fromMap({}).statusPeriodMs, 12000);
    expect(NeighborParameters.fromMap({}).policy, 'periodic_v1');
    expect(parameters.statusPeriodMs, 60000);
    expect(parameters.freshnessMs, 150000);
    expect(parameters.toMap()['data_grace_ms'], 10000);
    expect(
      () => NeighborParameters.fromMap({
        'neighbor_status_policy': 'bad',
      }).validate(),
      throwsArgumentError,
    );
    expect(
      () => NeighborParameters.fromMap({
        'neighbor_status_policy': 'adaptive_v2',
        'freshness_ms': 120000,
      }).validate(),
      throwsArgumentError,
    );
  });
  test('discovery and empty retries 4 8 16 32 continue with jitter', () {
    final s = schedule()..start(100, 1500);
    expect(s.nextAt, 2600);
    for (final interval in [4000, 8000, 16000, 32000, 32000, 32000]) {
      final now = s.nextAt;
      s.statusSucceeded([], now, false, 1500);
      expect(s.nextAt - now, interval + 1500);
      expect(s.reason, 'INVENTORY_EMPTY');
    }
  });
  test('native failure cannot grow empty or maintenance backoff', () {
    final s = schedule();
    s.failed(1000, 1500);
    expect(s.nextAt, 3500);
    s.statusSucceeded([], 3500, false, 0);
    expect(s.nextAt, 7500);
    s.syncInventory(['a'], 4000, 0);
    expect(s.nextAt, 14000);
    s.failed(14000, 0);
    s.statusSucceeded(['a'], 15000, false, 0);
    expect(s.nextAt, 30000);
  });
  test(
    'state grace coalesces on DATA success, not request or partial inventory',
    () {
      final s = schedule()..statusSucceeded([], 1000, false, 0);
      s.syncInventory(['b', 'a'], 2000, 0);
      expect(s.nextAt, 12000);
      expect(s.dataSucceeded('a', 4000, false, 0), isFalse);
      expect(s.nextAt, 12000);
      s.syncInventory(['a', 'b'], 5000, 0);
      expect(s.nextAt, 12000);
      expect(s.dataSucceeded('b', 6000, false, 1500), isTrue);
      expect(s.nextAt, 22500);
      expect(s.dataSucceeded('b', 7000, false, 0), isFalse);
      expect(s.nextAt, 22000);
    },
  );
  test(
    'maintenance 15 30 60 bounded; fresh stable peers use 60 immediately',
    () {
      final s = schedule()..statusSucceeded([], 1000, false, 0);
      s.syncInventory(['a'], 2000, 0);
      for (final interval in [15000, 30000, 60000, 60000]) {
        final now = s.nextAt;
        s.statusSucceeded(['a'], now, false, 0);
        expect(s.nextAt - now, interval);
      }
      final stable = schedule()..syncInventory(['a'], 0, 0);
      expect(stable.dataSucceeded('a', 5000, true, 0), isTrue);
      expect(stable.nextAt, 65000);
      stable.stable(6000, true, 0);
      expect(stable.nextAt, 65000);
      stable.peerChanged(6000, 0);
      expect(stable.nextAt, 21000);
    },
  );
  test(
    'new state resets coverage and stale STATUS callback cannot cancel it',
    () {
      final s = schedule()..syncInventory(['a'], 0, 0);
      s.dataSucceeded('a', 4000, true, 0);
      s.syncInventory(['b'], 5000, 0);
      expect(s.nextAt, 15000);
      s.statusSucceeded(['a'], 6000, true, 0);
      expect(s.nextAt, 15000);
      expect(s.firstForwardComplete, isFalse);
      expect(s.dataSucceeded('a', 7000, true, 0), isFalse);
    },
  );
  test(
    'first discovery preserved on restart with retained SOS and no DATA',
    () {
      final s = schedule()..start(20000, 1500);
      s.syncInventory(['a'], 20000, 0);
      expect(s.nextAt, 22500);
      expect(s.reason, 'DISCOVERY');
      s.statusSucceeded(['a'], 22500, false, 0);
      expect(s.nextAt, 37500);
    },
  );
  test('inventory larger than wire capacity stays covered per state', () {
    final s = schedule();
    final states = List.generate(9, (i) => 'state$i');
    s.syncInventory(states, 0, 0);
    for (final state in states.take(8)) {
      expect(s.dataSucceeded(state, 4000, true, 0), isFalse);
    }
    expect(s.firstForwardComplete, isFalse);
    s.statusSucceeded(states, 5000, false, 0);
    expect(s.nextAt, 20000);
    expect(s.firstForwardComplete, isFalse);
  });
  test(
    'nearby state triggers coalesce without indefinitely postponing grace',
    () {
      final s = schedule()..statusSucceeded([], 1000, false, 0);
      s.syncInventory(['a'], 2000, 0);
      s.syncInventory(['a', 'b'], 3000, 0);
      expect(s.nextAt, 12000);
      s.syncInventory(['a', 'b', 'c'], 4000, 0);
      expect(s.nextAt, 12000);
    },
  );
  test(
    'lost fresh HAVE evidence resets maintenance without dropping inventory',
    () {
      final s = schedule()..syncInventory(['a'], 0, 0);
      s.dataSucceeded('a', 5000, true, 0);
      s.stable(6000, false, 1500);
      expect(s.nextAt, 22500);
      expect(s.inventory, ['a']);
      s.stable(7000, false, 0);
      expect(s.nextAt, 22500);
    },
  );
}
