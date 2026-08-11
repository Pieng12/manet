import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:pkmproject/config/mesh_config.dart';
import 'package:pkmproject/models/forwarding_decision.dart';
import 'package:pkmproject/models/sos_message.dart';
import 'package:pkmproject/services/ble_protocol.dart';
import 'package:pkmproject/services/ble_relay_service.dart';
import 'package:pkmproject/services/forwarding_policy.dart';
import 'package:pkmproject/services/relay_queue_service.dart';

void main() {
  const senderCrc = 123456;
  final now = DateTime.utc(2026, 8, 12, 12).millisecondsSinceEpoch;

  SOSMessage existing({
    int? updatedAt,
    SOSMessageStatus status = SOSMessageStatus.active,
    int hopCount = 1,
    int relayCount = 0,
    int lastRelayedAt = 0,
  }) {
    return SOSMessage(
      id: 'existing',
      senderId: 'ble-device-$senderCrc',
      senderCrc: senderCrc,
      content: 'SOS',
      latitude: -6.2,
      longitude: 106.8,
      status: status,
      createdAt: updatedAt ?? now,
      updatedAt: updatedAt ?? now,
      hopCount: hopCount,
      relayCount: relayCount,
      lastRelayedAt: lastRelayedAt,
    );
  }

  BlePacket packet({
    int? timestampMs,
    SOSMessageStatus status = SOSMessageStatus.active,
    int hopCount = 0,
  }) {
    return BlePacket(
      kind: BlePacketKind.sos,
      senderCrc: senderCrc,
      timestampMs: timestampMs ?? now,
      latitude: -6.2,
      longitude: 106.8,
      status: status,
      hopCount: hopCount,
    );
  }

  RelayQueueService queue() => RelayQueueService(random: Random(1));

  test('better-hop state improvement is immediately eligible', () {
    final current = existing(
      hopCount: 3,
      relayCount: 4,
      lastRelayedAt: now - 1000,
    );
    final incomingPacket = packet(hopCount: 0);
    final decision = const ForwardingPolicy().decideSos(
      packet: incomingPacket,
      nowMs: now,
      existingMessage: current,
    );
    final incoming = BleRelayService.messageFromSosPacket(incomingPacket, now);

    expect(decision.reason, ForwardingDecisionReason.dropCooldown);
    expect(BleRelayService.isSosStateImprovement(incoming, current), true);
    expect(
      BleRelayService.determineSosNextEligibleAt(
        nowMs: now,
        decision: decision,
        incoming: incoming,
        existing: current,
        relayQueue: queue(),
      ),
      now,
    );
    expect(
      BleRelayService.shouldDeferSosForCooldown(
        decision: decision,
        incoming: incoming,
        existing: current,
      ),
      false,
    );
    expect(
      BleRelayService.shouldRelaySosNow(
        decision: decision,
        incoming: incoming,
        existing: current,
      ),
      true,
    );
  });

  test('worse hop and equal hop are not state improvements', () {
    final current = existing(hopCount: 1);
    final worse = existing(hopCount: 3);
    final equal = existing(hopCount: 1);
    const cooldownDecision = ForwardingDecision(
      shouldStore: true,
      shouldRelay: false,
      reason: ForwardingDecisionReason.dropCooldown,
      nextEligibleAt: 999999,
    );

    expect(BleRelayService.isSosStateImprovement(worse, current), false);
    expect(BleRelayService.isSosStateImprovement(equal, current), false);
    expect(
      BleRelayService.determineSosNextEligibleAt(
        nowMs: now,
        decision: cooldownDecision,
        incoming: worse,
        existing: current,
        relayQueue: queue(),
      ),
      cooldownDecision.nextEligibleAt,
    );
  });

  test('newer timestamp wins even with worse hop', () {
    final current = existing(updatedAt: now, hopCount: 1);
    final incoming = existing(updatedAt: now + 1000, hopCount: 5);

    expect(BleRelayService.isSosStateImprovement(incoming, current), true);
  });

  test('terminal status wins even with worse hop', () {
    final current = existing(status: SOSMessageStatus.active, hopCount: 1);
    final incoming = existing(status: SOSMessageStatus.resolved, hopCount: 5);
    const decision = ForwardingDecision(
      shouldStore: true,
      shouldRelay: true,
      reason: ForwardingDecisionReason.relayAccepted,
    );

    expect(BleRelayService.isSosStateImprovement(incoming, current), true);
    expect(
      BleRelayService.determineSosNextEligibleAt(
        nowMs: now,
        decision: decision,
        incoming: incoming,
        existing: current,
        relayQueue: queue(),
      ),
      now,
    );
  });

  test('stale ACTIVE better hop cannot replace terminal state', () {
    final current = existing(status: SOSMessageStatus.resolved, hopCount: 5);
    final incoming = existing(status: SOSMessageStatus.active, hopCount: 1);

    expect(BleRelayService.isSosStateImprovement(incoming, current), false);
  });

  test('hop saturation remains 63', () {
    final incoming = BleRelayService.messageFromSosPacket(
      packet(hopCount: MeshConfig.maxProtocolHop),
      now,
    );

    expect(incoming.hopCount, MeshConfig.maxProtocolHop);
  });
}
