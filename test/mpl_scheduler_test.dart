import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:pkmproject/models/message_identity.dart';
import 'package:pkmproject/models/sos_message.dart';
import 'package:pkmproject/services/ble_protocol.dart';
import 'package:pkmproject/services/mpl_scheduler.dart';
import 'package:pkmproject/services/neighbor_transport.dart';
import 'package:pkmproject/services/neighbor_status_controller.dart';

class ZeroRandom implements Random {
  @override
  int nextInt(int max) => 0;
  @override
  double nextDouble() => 0;
  @override
  bool nextBool() => false;
}

class UpperRandom extends ZeroRandom {
  @override
  int nextInt(int max) => max - 1;
}

final state = StateIdentity(
  messageKey: MessageKey(senderCrc: 123, protocolTimestampMs: 1780272042000),
  statusIndex: 1,
  isAck: false,
  fromServer: false,
);
NeighborFrame status({
  int peer = 3,
  int boot = 1,
  int seq = 1,
  bool complete = true,
  List<StateIdentity> states = const [],
}) => NeighborFrame(
  type: NeighborFrameType.status,
  transmitter: peer,
  boot: boot,
  sequence: seq,
  scope: 4,
  complete: complete,
  inventory: states,
);
MplScheduler scheduler([
  List<Map<String, Object>>? events,
  Map<String, dynamic> params = const {},
]) => MplScheduler(
  scope: 4,
  random: ZeroRandom(),
  parameters: MplParameters(params),
  diagnostic: events?.add,
)..discover(0);
void main() {
  test('stopped timers keep wakeups in the future in a long-lived runtime', () {
    final m = scheduler();
    m.sync([state], 0);
    m.tick(248000);
    expect(m.data[state.value]!.active, false);
    expect(m.control.active, false);
    const twoDays = 2 * 86400000;
    m.tick(twoDays);
    expect(m.data[state.value]!.nextAt, greaterThan(twoDays));
    expect(m.nextControlAt, greaterThan(twoDays));
    expect(m.buffer.containsKey(state.value), true);
  });
  test(
    'expired deficit and new incarnation cannot keep protecting old demand',
    () {
      final m = scheduler(null, {'mpl_freshness_ms': 4000});
      m.receive(status(states: [state]), 100, 100);
      expect(m.deficit, true);
      m.tick(4101);
      expect(m.deficit, false);
      m.receive(status(boot: 2), 4200, 4200);
      expect(m.deficit, false);
      expect(m.neighbors.knowledge(3, state, 4200), NeighborKnowledge.missing);
    },
  );
  test(
    'upper RNG t stays below interval end and late callback cannot start next interval',
    () {
      final events = <Map<String, Object>>[];
      final timer = MplTimer(
        'data',
        'state',
        MplParameters(),
        UpperRandom(),
        events.add,
      );
      timer.reset(1000, 'TEST');
      expect(timer.transmit, 8999);
      expect(timer.opportunity(8998), false);
      expect(timer.opportunity(8999), true);
      final token = timer.generation;
      timer.advance(9000);
      expect(timer.interval, 16000);
      expect(timer.e, 1);
      expect(timer.nativeResult(token, 9001, true), false);
      expect(events.any((e) => e['event'] == 'MPL_TX_MISSED'), true);
    },
  );
  test('first DATA acceptance is not a consistent duplicate', () {
    final m = scheduler();
    m.sync([state], 100);
    final frame = NeighborFrame(
      type: NeighborFrameType.data,
      transmitter: 3,
      boot: 1,
      sequence: 1,
      scope: 4,
      inner: BlePacket.packSos(
        SOSMessage(
          id: 'm',
          senderId: 's',
          senderCrc: 123,
          content: 'SOS',
          latitude: 0,
          longitude: 0,
          createdAt: 1780272042000,
          updatedAt: 1780272042000,
          hopCount: 1,
        ),
      ),
    );
    expect(m.receive(frame, 100, 100, newState: true), true);
    expect(m.data[state.value]!.c, 0);
  });
  test('ambiguous same-sender inventory cannot provide fresh evidence', () {
    final m = scheduler();
    m.sync([state], 0);
    expect(m.receive(status(states: [state, state]), 100, 100), false);
    expect(m.control.c, 0);
    expect(m.neighbors.knowledge(3, state, 100), NeighborKnowledge.unknown);
  });
  for (final scenario in ['S1_SCANNER_ON', 'S2_NODE_ON']) {
    test(
      '$scenario settled D-E branch discovers and repairs after lost burst',
      () {
        final a = scheduler(), d = scheduler(), e = scheduler();
        a.sync([state], 0);
        a.tick(248000); // timer settled, durable buffer retained
        d.discover(250000);
        expect(d.controlDue(252000), true);
        d.controlResult(
          d.control.generation,
          d.inventoryGeneration,
          252000,
          false,
        );
        expect(d.bootstrap, 2);
        expect(d.controlDue(253000), true);
        d.controlResult(
          d.control.generation,
          d.inventoryGeneration,
          253000,
          true,
        );
        a.receive(status(peer: 30), 253000, 253000);
        a.receive(status(peer: 20, states: [state]), 253100, 253100);
        a.data[state.value]!.consistent(253200, 253200);
        expect(
          a.dataDue(state.value, 257000),
          true,
        ); // missing D survives C consistency
        final token = a.data[state.value]!.generation;
        a.dataResult(
          state.value,
          token,
          257000,
          false,
        ); // DATA lost/start failed
        expect(a.dataDue(state.value, 258000), true);
        a.dataResult(state.value, token, 258000, true);
        d.sync([state], 258001);
        e.discover(260000);
        e.receive(status(peer: 30, states: [state]), 260001, 260001);
        expect(e.deficit, true);
        expect(e.buffer, isEmpty); // no invented payload
        expect(e.controlDue(262000), true);
        d.receive(status(peer: 40), 262000, 262000);
        expect(d.dataDue(state.value, 262001), true);
        d.dataResult(
          state.value,
          d.data[state.value]!.generation,
          262001,
          true,
        );
        e.sync([state], 262002);
        expect(e.deficit, false);
        expect(e.data[state.value]!.active, true); // E is also relay
      },
    );
  }
  test('listen only c/k doubling and suppressed intervals still expire', () {
    final events = <Map<String, Object>>[];
    final m = scheduler(events, {
      'mpl_control_expirations': 2,
      'mpl_bootstrap_opportunities': 0,
    });
    expect(m.controlDue(1999), false);
    m.receive(status(), 1000, 1000);
    expect(m.control.c, 1);
    expect(m.controlDue(2000), false);
    m.tick(4000);
    expect(m.control.interval, 8000);
    expect(m.control.c, 0);
    expect(m.control.e, 1);
    m.receive(status(seq: 2), 5000, 5000);
    expect(m.controlDue(8000), false);
    m.tick(12000);
    expect(m.control.active, false);
    expect(m.control.e, 2);
    expect(events.where((e) => e['event'] == 'MPL_TX_SUPPRESSED').length, 2);
  });
  test('same burst never increments c or refreshes physical freshness', () {
    final m = scheduler();
    m.sync([state], 0);
    final frame = NeighborFrame(
      type: NeighborFrameType.data,
      transmitter: 3,
      boot: 1,
      sequence: 1,
      scope: 4,
      inner: BlePacket.packSos(
        SOSMessage(
          id: 'm',
          senderId: 's',
          senderCrc: 123,
          content: 'SOS',
          latitude: 0,
          longitude: 0,
          createdAt: 1780272042000,
          updatedAt: 1780272042000,
          hopCount: 1,
        ),
      ),
    );
    // STATUS consistency is deduplicated by the same transport contract.
    expect(m.receive(status(states: [state]), 100, 100), true);
    expect(m.receive(status(states: [state]), 100, 10000), false);
    expect(m.control.c, 1);
    expect(m.receive(frame, 200, 200), false); // sequence replay of same peer
    final dataFrame = NeighborFrame(
      type: frame.type,
      transmitter: 4,
      boot: 1,
      sequence: 1,
      scope: 4,
      inner: frame.inner,
    );
    expect(m.receive(dataFrame, 200, 200), true);
    expect(m.receive(dataFrame, 200, 1000), false);
    expect(m.data[state.value]!.c, 1);
    expect(m.neighbors.knowledge(3, state, 150101), NeighborKnowledge.unknown);
    expect(frame.encode().length, 39);
  });
  test(
    'partial snapshot cannot establish negative evidence or consistency',
    () {
      final m = scheduler();
      m.sync([state], 0);
      m.receive(status(complete: false), 100, 100);
      expect(m.control.c, 0);
      expect(m.repairProtected(state.value, 100), false);
    },
  );
  test('missing local state advertises deficit but never invents DATA', () {
    final m = scheduler();
    m.receive(status(states: [state]), 100, 100);
    expect(m.deficit, true);
    expect(m.buffer, isEmpty);
    expect(m.data, isEmpty);
    expect(m.controlDue(2000), true);
  });
  test(
    'bounded repair survives consistent branch and cooldown wakes without RX',
    () {
      final events = <Map<String, Object>>[];
      final m = scheduler(events);
      m.sync([state], 0);
      m.receive(status(peer: 30), 100, 100);
      m.receive(status(peer: 20, states: [state]), 200, 200);
      m.data[state.value]!.consistent(300, 300);
      expect(m.data[state.value]!.c, 1);
      expect(m.dataDue(state.value, 4000), true);
      m.dataResult(state.value, m.data[state.value]!.generation, 4000, true);
      final completed = events.singleWhere(
        (e) => e['event'] == 'MPL_REPAIR_COMPLETED',
      );
      expect(completed['peer_id'], 30);
      expect(completed['episode_until'], 60100);
      expect(m.repairProtected(state.value, 4000), true);
      m.tick(8100);
      expect(events.where((e) => e['event'] == 'MPL_REPAIR_RESET').length, 2);
      final t = m.data[state.value]!;
      expect(m.dataDue(state.value, t.transmit), true);
      m.dataResult(state.value, t.generation, t.transmit, true);
      expect(m.repairProtected(state.value, t.transmit), false);
      for (var i = 2; i < 20; i++) {
        m.receive(status(peer: 30, seq: i), 9000 + i, 9000 + i);
      }
      expect(m.repairProtected(state.value, 10000), false);
    },
  );
  test(
    'empty bootstrap is protected from consistent empty peers; scanner restart reactivates',
    () {
      final m = scheduler(null, {'mpl_control_expirations': 1});
      m.receive(status(), 100, 100);
      expect(m.control.c, 1);
      expect(m.controlDue(2000), true);
      m.controlResult(m.control.generation, m.inventoryGeneration, 2000, true);
      expect(m.bootstrap, 1);
      m.tick(4000);
      expect(m.control.active, false);
      m.discover(30000);
      expect(m.control.active, true);
      expect(m.bootstrap, 2);
    },
  );
  test(
    'timer expiration retains buffer and mismatch restarts only relevant DATA',
    () {
      final m = scheduler(null, {'mpl_data_expirations': 1});
      m.sync([state], 0);
      m.tick(8000);
      expect(m.data[state.value]!.active, false);
      expect(m.buffer.length, 1);
      m.receive(status(), 8100, 8100);
      expect(m.data[state.value]!.active, true);
      m.sync([], 8200);
      expect(m.data, isEmpty);
      expect(m.buffer, isEmpty);
    },
  );
  test(
    'Imin mismatch does not reroll t; independent states and peers avoid global cooldown',
    () {
      final other = StateIdentity(
        messageKey: MessageKey(
          senderCrc: 456,
          protocolTimestampMs: 1780272042000,
        ),
        statusIndex: 1,
        isAck: false,
        fromServer: false,
      );
      final m = scheduler();
      m.sync([state, other], 0);
      final at = m.data[state.value]!.transmit;
      for (var i = 1; i < 30; i++) {
        m.receive(status(seq: i), i * 10, i * 10);
      }
      expect(m.data[state.value]!.transmit, at);
      expect(m.repairProtected(other.value, 300), true);
      expect(m.repairProtected(state.value, 300), true);
    },
  );
  test('native failure and stale generation retain success budgets', () {
    final m = scheduler();
    m.sync([state], 0);
    m.receive(status(), 100, 100);
    expect(m.dataDue(state.value, 4000), true);
    final t = m.data[state.value]!;
    m.dataResult(state.value, t.generation, 4000, false);
    expect(t.pending, true);
    expect(t.retryAt, 5000);
    expect(m.repairProtected(state.value, 5000), true);
    m.dataResult(state.value, t.generation - 1, 5000, true);
    expect(t.pending, true);
    expect(m.dataDue(state.value, 5000), true);
    m.dataResult(state.value, t.generation, 5000, true);
    expect(t.pending, false);
  });
  test(
    'CONTROL cannot occupy protected DATA slot; expired opportunity is logged',
    () {
      final events = <Map<String, Object>>[];
      final m = scheduler(events);
      expect(m.controlDue(2000, slot: false), false);
      expect(m.control.pending, true);
      expect(m.controlDue(2100), true);
      m.tick(4000);
      expect(events.any((e) => e['event'] == 'MPL_TX_MISSED'), true);
    },
  );
  test('new inventory ignores callback for older generation', () {
    final m = scheduler();
    expect(m.controlDue(2000), true);
    final token = m.control.generation, inventory = m.inventoryGeneration;
    m.sync([state], 2100);
    m.controlResult(token, inventory, 2200, true);
    expect(m.bootstrap, 2);
  });
  test('supersession does not repair older state backwards', () {
    final newer = StateIdentity(
      messageKey: MessageKey(
        senderCrc: 123,
        protocolTimestampMs: 1780272043000,
      ),
      statusIndex: 1,
      isAck: false,
      fromServer: false,
    );
    final m = scheduler();
    m.sync([state], 0);
    m.receive(status(states: [newer]), 100, 100);
    expect(m.repairProtected(state.value, 100), false);
    expect(m.deficit, true);
    m.sync([newer], 200);
    expect(m.data.containsKey(state.value), false);
  });
  test(
    'wrong scope old incarnation replay and old physical sample are rejected',
    () {
      final m = scheduler();
      expect(m.receive(status(boot: 3), 100, 100), true);
      expect(m.receive(status(boot: 2, seq: 10), 200, 200), false);
      expect(m.receive(status(boot: 3, seq: 2), 99, 200), false);
      expect(m.receive(status(boot: 3, seq: 2), 200, 151000), false);
    },
  );
}
