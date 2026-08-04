import 'package:flutter_test/flutter_test.dart';
import 'package:pkmproject/config/mesh_config.dart';
import 'package:pkmproject/models/forwarding_decision.dart';
import 'package:pkmproject/models/sos_message.dart';
import 'package:pkmproject/services/ble_protocol.dart';
import 'package:pkmproject/services/forwarding_policy.dart';

void main() {
  const senderCrc = 12345;
  final now = DateTime.utc(2026, 8, 4, 12).millisecondsSinceEpoch;

  BlePacket sosPacket({
    int? timestampMs,
    int hopCount = 0,
    SOSMessageStatus status = SOSMessageStatus.active,
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

  SOSMessage existingMessage({
    int? updatedAt,
    int relayCount = 0,
    int lastRelayedAt = 0,
    int? ackReceivedAt,
    String localState = 'pending',
  }) {
    return SOSMessage(
      id: 'existing-1',
      senderId: 'ble-device-$senderCrc',
      senderCrc: senderCrc,
      content: 'SOS',
      latitude: -6.2,
      longitude: 106.8,
      status: SOSMessageStatus.active,
      createdAt: updatedAt ?? now,
      updatedAt: updatedAt ?? now,
      relayCount: relayCount,
      lastRelayedAt: lastRelayedAt,
      ackReceivedAt: ackReceivedAt,
      localState: localState,
    );
  }

  test('new controlled flooding packet is accepted for relay', () {
    const policy = ForwardingPolicy();

    final decision = policy.decideSos(packet: sosPacket(), nowMs: now);

    expect(decision.shouldStore, true);
    expect(decision.shouldRelay, true);
    expect(decision.nextHopCount, 1);
    expect(decision.reason, ForwardingDecisionReason.relayAccepted);
  });

  test('duplicate or older packet is dropped', () {
    const policy = ForwardingPolicy();

    final decision = policy.decideSos(
      packet: sosPacket(timestampMs: now),
      nowMs: now,
      existingMessage: existingMessage(updatedAt: now),
    );

    expect(decision.shouldStore, false);
    expect(decision.shouldRelay, false);
    expect(decision.reason, ForwardingDecisionReason.dropDuplicate);
  });

  test('expired packet is stored but not relayed', () {
    const policy = ForwardingPolicy();
    final oldTimestamp = now - MeshConfig.defaultMessageLifetime.inMilliseconds;

    final decision = policy.decideSos(
      packet: sosPacket(timestampMs: oldTimestamp),
      nowMs: now,
    );

    expect(decision.shouldStore, true);
    expect(decision.shouldRelay, false);
    expect(decision.reason, ForwardingDecisionReason.dropExpired);
  });

  test('max hop packet is stored but not relayed', () {
    const policy = ForwardingPolicy();

    final decision = policy.decideSos(
      packet: sosPacket(hopCount: MeshConfig.defaultMaxHop),
      nowMs: now,
    );

    expect(decision.shouldStore, true);
    expect(decision.shouldRelay, false);
    expect(decision.nextHopCount, MeshConfig.defaultMaxHop);
    expect(decision.reason, ForwardingDecisionReason.dropMaxHop);
  });

  test('controlled flooding defers packet during relay cooldown', () {
    const policy = ForwardingPolicy();
    final lastRelayedAt = now - const Duration(seconds: 2).inMilliseconds;

    final decision = policy.decideSos(
      packet: sosPacket(timestampMs: now + 1000),
      nowMs: now,
      existingMessage: existingMessage(
        updatedAt: now - 1000,
        lastRelayedAt: lastRelayedAt,
      ),
    );

    expect(decision.shouldStore, true);
    expect(decision.shouldRelay, false);
    expect(decision.reason, ForwardingDecisionReason.dropCooldown);
    expect(
      decision.nextEligibleAt,
      lastRelayedAt + MeshConfig.relayCooldown.inMilliseconds,
    );
  });

  test('acked local message suppresses relay', () {
    const policy = ForwardingPolicy();

    final decision = policy.decideSos(
      packet: sosPacket(timestampMs: now + 1000),
      nowMs: now,
      existingMessage: existingMessage(
        updatedAt: now - 1000,
        ackReceivedAt: now - 500,
        localState: 'acked',
      ),
    );

    expect(decision.shouldStore, false);
    expect(decision.shouldRelay, false);
    expect(decision.reason, ForwardingDecisionReason.dropAcked);
  });

  test('own packet is dropped', () {
    const policy = ForwardingPolicy();

    final decision = policy.decideSos(
      packet: sosPacket(),
      nowMs: now,
      ownSenderCrc: senderCrc,
    );

    expect(decision.shouldStore, false);
    expect(decision.shouldRelay, false);
    expect(decision.reason, ForwardingDecisionReason.dropOwnPacket);
  });

  test('controlled flooding enforces max relay count', () {
    const policy = ForwardingPolicy();

    final decision = policy.decideSos(
      packet: sosPacket(timestampMs: now + 1000),
      nowMs: now,
      existingMessage: existingMessage(
        updatedAt: now - 1000,
        relayCount: MeshConfig.maxRelayCount,
      ),
    );

    expect(decision.shouldStore, true);
    expect(decision.shouldRelay, false);
    expect(decision.reason, ForwardingDecisionReason.dropMaxRelay);
  });

  test('basic flooding ignores controlled cooldown and max relay count', () {
    const policy = ForwardingPolicy(mode: ForwardingMode.basicFlooding);

    final decision = policy.decideSos(
      packet: sosPacket(timestampMs: now + 1000),
      nowMs: now,
      existingMessage: existingMessage(
        updatedAt: now - 1000,
        relayCount: MeshConfig.maxRelayCount,
        lastRelayedAt: now - const Duration(seconds: 2).inMilliseconds,
      ),
    );

    expect(decision.shouldStore, true);
    expect(decision.shouldRelay, true);
    expect(decision.reason, ForwardingDecisionReason.relayAccepted);
  });

  test('packet identity ignores hop and BLE address changes', () {
    final hopZero = sosPacket(hopCount: 0);
    final hopThree = sosPacket(hopCount: 3);

    expect(hopZero.identity, hopThree.identity);
    expect(hopZero.identity, 'SOS:$senderCrc:$now:1');
  });
}
