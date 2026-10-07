import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:pkmproject/config/mesh_config.dart';
import 'package:pkmproject/models/message_identity.dart';
import 'package:pkmproject/services/ble_protocol.dart';
import 'package:pkmproject/services/neighbor_transport.dart';
import 'package:pkmproject/services/neighbor_status_controller.dart';

Uint8List hex(String s) => Uint8List.fromList([
  for (var i = 0; i < s.length; i += 2)
    int.parse(s.substring(i, i + 2), radix: 16),
]);
const dataGolden =
    '524e0100000000010000000200000003000000040001524d1234567800002a0000000000000101';
const emptyGolden = '524e0101000000010000000200000003000000040001';
const statusGolden =
    '524e01010000000100000002000000030000000401011234567800002a01';

void main() {
  final reference = DateTime.utc(2026, 10, 7);
  final inner = hex('524d1234567800002a0000000000000101');
  final state = BlePacket.unpack(
    inner,
    referenceTime: reference,
  )!.stateIdentity;
  test('HAVE changes cannot reset for another unchanged MISSING peer', () {
    final c = NeighborStatusController(scope: 4);
    NeighborFrame have(int sequence, {bool data = false}) => NeighborFrame(
      type: data ? NeighborFrameType.data : NeighborFrameType.status,
      transmitter: 3,
      boot: 1,
      sequence: sequence,
      scope: 4,
      inner: data ? inner : null,
      inventory: data ? [] : [state],
    );
    c.observe(have(1), 100, 100);
    c.observe(
      const NeighborFrame(
        type: NeighborFrameType.status,
        transmitter: 4,
        boot: 1,
        sequence: 1,
        scope: 4,
      ),
      100,
      100,
    );
    expect(c.repairAllowed(state, 100, 16000, 8000), true);
    c.observe(have(2, data: true), 10000, 10000);
    expect(
      c.decision(state, 10000, firstForwardPending: false),
      'FRESH_MISSING',
    );
    expect(c.repairAllowed(state, 10000, 16000, 8000), false);
  });
  NeighborFrame status(
    int tx, {
    int seq = 1,
    int scope = 4,
    int boot = 2,
    bool complete = true,
    List<StateIdentity> inventory = const [],
  }) => NeighborFrame(
    type: NeighborFrameType.status,
    transmitter: tx,
    boot: boot,
    sequence: seq,
    scope: scope,
    complete: complete,
    inventory: inventory,
  );

  test(
    'cross-language DATA, empty STATUS and populated STATUS golden vectors',
    () {
      for (final vector in [dataGolden, emptyGolden, statusGolden]) {
        final f = NeighborFrame.decode(hex(vector), referenceTime: reference)!;
        expect(f.encode(), hex(vector));
      }
      expect(NeighborFrame.decode(hex(emptyGolden))!.inventory, isEmpty);
      expect(NeighborFrame.decode(hex(dataGolden))!.inner, inner);
    },
  );
  test(
    'bad length, version, reserved flags, missing IDs and malformed inner rejected',
    () {
      for (final mutation in [0, 2, 3, 20, 21, 37]) {
        final bad = hex(dataGolden);
        bad[mutation] = 255;
        expect(NeighborFrame.decode(bad), isNull);
      }
      expect(NeighborFrame.decode(hex(dataGolden).sublist(0, 38)), isNull);
      final noId = hex(dataGolden)..fillRange(4, 8, 0);
      expect(NeighborFrame.decode(noId), isNull);
    },
  );
  test(
    'relay transmitter changes but original source and message key stay fixed',
    () {
      final a = NeighborFrame.decode(hex(dataGolden))!;
      final b = NeighborFrame(
        type: a.type,
        transmitter: 9,
        boot: 8,
        sequence: 1,
        scope: a.scope,
        inner: a.inner,
      );
      expect(
        BlePacket.unpack(b.inner!)!.messageKey,
        BlePacket.unpack(a.inner!)!.messageKey,
      );
      expect(a.burstIdentity, isNot(b.burstIdentity));
      expect(a.observationIdentity('rx'), 'rx|4:1:2:3');
    },
  );
  test('C HAVE cannot cancel repair for D MISSING', () {
    final c = NeighborStatusController(scope: 4);
    c.observe(status(3, inventory: [state]), 100, 100);
    c.observe(status(4), 100, 100);
    expect(c.knowledge(3, state, 100), NeighborKnowledge.have);
    expect(c.knowledge(4, state, 100), NeighborKnowledge.missing);
    expect(c.decision(state, 100, firstForwardPending: false), 'FRESH_MISSING');
  });
  test(
    'initial forwarding waits for successful start, then all HAVE suppresses',
    () {
      final c = NeighborStatusController(scope: 4);
      c.observe(status(3, inventory: [state]), 100, 100);
      expect(
        c.decision(state, 100, firstForwardPending: true),
        'INITIAL_FORWARD_PENDING',
      );
      // A failed start performs no started() mutation.
      expect(
        c.decision(state, 200, firstForwardPending: true),
        'INITIAL_FORWARD_PENDING',
      );
      c.started(state);
      expect(
        c.decision(state, 200, firstForwardPending: false),
        'ALL_OBSERVED_HAVE',
      );
    },
  );
  test(
    'partial, stale, wrong-scope and empty observed set never prove all HAVE',
    () {
      final c = NeighborStatusController(scope: 4);
      expect(
        c.decision(state, 0, firstForwardPending: false),
        'UNKNOWN_OR_NO_NEIGHBORS',
      );
      expect(
        c.observe(status(3, scope: 5, inventory: [state]), 100, 100),
        false,
      );
      c.observe(status(3, complete: false, inventory: [state]), 100, 100);
      expect(c.knowledge(3, state, 100), NeighborKnowledge.unknown);
      c.observe(status(3, seq: 2, inventory: [state]), 200, 200);
      expect(c.knowledge(3, state, 45201), NeighborKnowledge.unknown);
      expect(c.snapshot(state, 45201).length, 1); // Quiet neighbor is retained.
      expect(c.observe(status(4), 0, 45001), false);
    },
  );
  test(
    'empty late-join inventory triggers one bounded reset, not a STATUS storm',
    () {
      final c = NeighborStatusController(scope: 4);
      c.observe(status(3), 100, 100);
      expect(c.repairAllowed(state, 100, 8000, 8000), false);
      expect(c.repairAllowed(state, 100, 16000, 8000), true);
      expect(c.observe(status(3), 200, 200), false);
      c.observe(status(3, seq: 2), 10000, 10000);
      expect(c.repairAllowed(state, 10000, 16000, 8000), false);
      c.observe(status(4), 11000, 11000);
      expect(c.repairAllowed(state, 11000, 16000, 8000), true);
    },
  );
  test('newer state is not repaired backwards; reboot forgets freshness', () {
    final c = NeighborStatusController(scope: 4);
    final newer = StateIdentity(
      messageKey: MessageKey(
        senderCrc: state.messageKey.senderCrc,
        protocolTimestampMs: state.messageKey.protocolTimestampMs + 1000,
      ),
      statusIndex: 1,
      isAck: false,
      fromServer: false,
    );
    c.observe(status(3, inventory: [newer]), 100, 100);
    expect(c.knowledge(3, state, 100), NeighborKnowledge.have);
    expect(
      NeighborStatusController(scope: 4).knowledge(3, state, 100),
      NeighborKnowledge.unknown,
    );
  });
  test('equal-timestamp ACK tombstone must not request older SOS repair', () {
    final c = NeighborStatusController(scope: 4);
    final closed = StateIdentity(
      messageKey: state.messageKey,
      statusIndex: 2,
      isAck: false,
      fromServer: false,
    );
    final ack = StateIdentity(
      messageKey: state.messageKey,
      statusIndex: 2,
      isAck: true,
      fromServer: true,
    );
    c.observe(status(3, inventory: [ack]), 100, 100);
    expect(c.knowledge(3, closed, 100), NeighborKnowledge.have);
    expect(c.repairAllowed(closed, 100, 16000, 8000), false);
    final newer = StateIdentity(
      messageKey: MessageKey(
        senderCrc: state.messageKey.senderCrc,
        protocolTimestampMs: state.messageKey.protocolTimestampMs + 1000,
      ),
      statusIndex: 1,
      isAck: false,
      fromServer: false,
    );
    expect(c.knowledge(3, newer, 100), NeighborKnowledge.missing);
  });
  test(
    'separate bursts, forwarders and incarnations have distinct identities',
    () {
      final a = status(3, seq: 0xffffffff);
      final b = status(3, boot: 3, seq: 1);
      final c = NeighborStatusController(scope: 4);
      expect(c.observe(a, 100, 100), true);
      expect(c.observe(a, 200, 200), false);
      expect(c.observe(b, 200, 200), true);
      expect(a.burstIdentity, isNot(b.burstIdentity));
    },
  );
  test('baselines retain their own suppression flags', () {
    expect(ForwardingMode.basicFlooding.usesTrickle, false);
    expect(ForwardingMode.trickleNoSuppression.suppressionEnabled, false);
    expect(ForwardingMode.trickle.suppressionEnabled, true);
    expect(ForwardingMode.trickleNeighborStatus.suppressionEnabled, false);
  });
  test('discovery and expiry emitted once; old boot cannot restore HAVE', () {
    final c = NeighborStatusController(scope: 4);
    c.observe(status(3, boot: 3, inventory: [state]), 100, 100);
    expect(c.takeChanges(100).single['event'], 'NEIGHBOR_DISCOVERED');
    expect(c.takeChanges(45201).single['event'], 'NEIGHBOR_STATUS_EXPIRED');
    expect(c.takeChanges(50000), isEmpty);
    expect(
      c.observe(status(3, boot: 2, seq: 99, inventory: [state]), 50000, 50000),
      false,
    );
    expect(c.knowledge(3, state, 50000), NeighborKnowledge.unknown);
  });
  test(
    'STATUS has empty-queue discovery slots but cannot occupy imminent DATA',
    () {
      final c = NeighborStatusController(scope: 4);
      expect(c.statusHasSlot(1000, null), true);
      expect(c.statusHasSlot(1000, 1000), false);
      expect(c.statusHasSlot(1000, 1500), false);
      expect(c.statusHasSlot(1000, 9000), true);
    },
  );
}
