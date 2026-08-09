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
    int hopCount = 1,
    SOSMessageStatus status = SOSMessageStatus.active,
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
      status: status,
      createdAt: updatedAt ?? now,
      updatedAt: updatedAt ?? now,
      hopCount: hopCount,
      relayCount: relayCount,
      lastRelayedAt: lastRelayedAt,
      ackReceivedAt: ackReceivedAt,
      localState: localState,
    );
  }

  test('new controlled epidemic packet is accepted for relay', () {
    const policy = ForwardingPolicy();

    final decision = policy.decideSos(packet: sosPacket(), nowMs: now);

    expect(decision.shouldStore, true);
    expect(decision.shouldRelay, true);
    expect(decision.nextHopCount, 1);
    expect(decision.reason, ForwardingDecisionReason.relayAccepted);
  });

  test('exact duplicate packet is dropped as duplicate', () {
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

  test('older packet is dropped as stale', () {
    const policy = ForwardingPolicy();

    final decision = policy.decideSos(
      packet: sosPacket(timestampMs: now - 1000),
      nowMs: now,
      existingMessage: existingMessage(updatedAt: now),
    );

    expect(decision.shouldStore, false);
    expect(decision.shouldRelay, false);
    expect(decision.reason, ForwardingDecisionReason.dropStale);
  });

  test('same timestamp and status with lower hop updates best hop', () {
    const policy = ForwardingPolicy();

    final decision = policy.decideSos(
      packet: sosPacket(timestampMs: now, hopCount: 1),
      nowMs: now,
      existingMessage: existingMessage(updatedAt: now, hopCount: 4),
    );

    expect(decision.shouldStore, true);
    expect(decision.reason, ForwardingDecisionReason.relayAccepted);
    expect(decision.nextHopCount, 2);
  });

  test('status change on same second is not treated as duplicate', () {
    const policy = ForwardingPolicy();

    final decision = policy.decideSos(
      packet: sosPacket(timestampMs: now, status: SOSMessageStatus.cancelled),
      nowMs: now,
      existingMessage: existingMessage(
        updatedAt: now,
        status: SOSMessageStatus.active,
      ),
    );

    expect(decision.shouldStore, true);
    expect(decision.reason, ForwardingDecisionReason.relayAccepted);
  });

  test('ACTIVE does not overwrite CANCELLED at the same timestamp', () {
    const policy = ForwardingPolicy();

    final decision = policy.decideSos(
      packet: sosPacket(timestampMs: now, status: SOSMessageStatus.active),
      nowMs: now,
      existingMessage: existingMessage(
        updatedAt: now,
        status: SOSMessageStatus.cancelled,
      ),
    );

    expect(decision.shouldStore, false);
    expect(decision.reason, ForwardingDecisionReason.dropStale);
  });

  test('CANCELLED is not delayed by ACTIVE backoff', () {
    const policy = ForwardingPolicy();

    final decision = policy.decideSos(
      packet: sosPacket(timestampMs: now, status: SOSMessageStatus.cancelled),
      nowMs: now,
      existingMessage: existingMessage(
        updatedAt: now,
        status: SOSMessageStatus.active,
        lastRelayedAt: now - const Duration(seconds: 1).inMilliseconds,
      ),
    );

    expect(decision.shouldStore, true);
    expect(decision.shouldRelay, true);
    expect(decision.nextEligibleAt, isNull);
    expect(decision.reason, ForwardingDecisionReason.relayAccepted);
  });

  test('same identity still ignores BLE address and drops non-better hop', () {
    const policy = ForwardingPolicy();

    final decision = policy.decideSos(
      packet: sosPacket(timestampMs: now, hopCount: 4),
      nowMs: now,
      existingMessage: existingMessage(updatedAt: now, hopCount: 2),
    );

    expect(decision.shouldStore, false);
    expect(decision.reason, ForwardingDecisionReason.dropDuplicate);
  });

  test('invalid latitude longitude hop and future timestamp are rejected', () {
    const policy = ForwardingPolicy();

    final invalidLatitude = policy.decideSos(
      packet: BlePacket(
        kind: BlePacketKind.sos,
        senderCrc: senderCrc,
        timestampMs: now,
        latitude: 91,
        longitude: 106.8,
        status: SOSMessageStatus.active,
      ),
      nowMs: now,
    );
    final invalidLongitude = policy.decideSos(
      packet: BlePacket(
        kind: BlePacketKind.sos,
        senderCrc: senderCrc,
        timestampMs: now,
        latitude: -6.2,
        longitude: 181,
        status: SOSMessageStatus.active,
      ),
      nowMs: now,
    );
    final futureTimestamp = policy.decideSos(
      packet: sosPacket(
        timestampMs: now + MeshConfig.maxClockSkew.inMilliseconds + 1,
      ),
      nowMs: now,
    );

    expect(invalidLatitude.reason, ForwardingDecisionReason.dropInvalid);
    expect(invalidLongitude.reason, ForwardingDecisionReason.dropInvalid);
    expect(futureTimestamp.reason, ForwardingDecisionReason.dropInvalid);
  });

  test('old packet is stored and relayed while not ACKed', () {
    const policy = ForwardingPolicy();
    final oldTimestamp = now - MeshConfig.defaultMessageLifetime.inMilliseconds;

    final decision = policy.decideSos(
      packet: sosPacket(timestampMs: oldTimestamp),
      nowMs: now,
    );

    expect(decision.shouldStore, true);
    expect(decision.shouldRelay, true);
    expect(decision.reason, ForwardingDecisionReason.relayAccepted);
  });

  test('hop 63 packet is stored and relayed with saturated hop', () {
    const policy = ForwardingPolicy();

    final decision = policy.decideSos(
      packet: sosPacket(hopCount: MeshConfig.maxProtocolHop),
      nowMs: now,
    );

    expect(decision.shouldStore, true);
    expect(decision.shouldRelay, true);
    expect(decision.nextHopCount, MeshConfig.maxProtocolHop);
    expect(decision.reason, ForwardingDecisionReason.relayAccepted);
  });

  test('controlled epidemic defers packet during relay cooldown', () {
    const policy = ForwardingPolicy();
    final lastRelayedAt = now - const Duration(seconds: 2).inMilliseconds;

    final decision = policy.decideSos(
      packet: sosPacket(timestampMs: now, hopCount: 0),
      nowMs: now,
      existingMessage: existingMessage(
        updatedAt: now,
        hopCount: 3,
        lastRelayedAt: lastRelayedAt,
      ),
    );

    expect(decision.shouldStore, true);
    expect(decision.shouldRelay, false);
    expect(decision.reason, ForwardingDecisionReason.dropCooldown);
    expect(
      decision.nextEligibleAt,
      lastRelayedAt + MeshConfig.adaptiveBackoffBase.inMilliseconds,
    );
  });

  test('acked local message suppresses older SOS', () {
    const policy = ForwardingPolicy();

    final decision = policy.decideSos(
      packet: sosPacket(timestampMs: now),
      nowMs: now,
      existingMessage: existingMessage(
        updatedAt: now,
        ackReceivedAt: now,
        localState: 'acked',
      ),
    );

    expect(decision.shouldStore, false);
    expect(decision.shouldRelay, false);
    expect(decision.reason, ForwardingDecisionReason.dropAcked);
  });

  test('old SOS ACKed then newer SOS is accepted', () {
    const policy = ForwardingPolicy();

    final decision = policy.decideSos(
      packet: sosPacket(timestampMs: now + 1000),
      nowMs: now + 1000,
      existingMessage: existingMessage(
        updatedAt: now,
        ackReceivedAt: now,
        localState: 'acked',
      ),
    );

    expect(decision.shouldStore, true);
    expect(decision.shouldRelay, true);
    expect(decision.reason, ForwardingDecisionReason.relayAccepted);
  });

  test('newer ACTIVE bypasses old backoff', () {
    const policy = ForwardingPolicy();

    final decision = policy.decideSos(
      packet: sosPacket(timestampMs: now + 2000),
      nowMs: now + 2000,
      existingMessage: existingMessage(
        updatedAt: now,
        lastRelayedAt: now + 1000,
        relayCount: 5,
      ),
    );

    expect(decision.shouldStore, true);
    expect(decision.shouldRelay, true);
    expect(decision.nextEligibleAt, isNull);
    expect(decision.reason, ForwardingDecisionReason.relayAccepted);
  });

  test('RESOLVED wins over CANCELLED at the same timestamp', () {
    const policy = ForwardingPolicy();

    final decision = policy.decideSos(
      packet: sosPacket(timestampMs: now, status: SOSMessageStatus.resolved),
      nowMs: now,
      existingMessage: existingMessage(
        updatedAt: now,
        status: SOSMessageStatus.cancelled,
      ),
    );

    expect(decision.shouldStore, true);
    expect(decision.reason, ForwardingDecisionReason.relayAccepted);
  });

  test(
    'same timestamp lower status is stale and equal terminal state is duplicate',
    () {
      const policy = ForwardingPolicy();

      final staleActive = policy.decideSos(
        packet: sosPacket(timestampMs: now, status: SOSMessageStatus.active),
        nowMs: now,
        existingMessage: existingMessage(
          updatedAt: now,
          status: SOSMessageStatus.cancelled,
        ),
      );
      final duplicateCancelled = policy.decideSos(
        packet: sosPacket(timestampMs: now, status: SOSMessageStatus.cancelled),
        nowMs: now,
        existingMessage: existingMessage(
          updatedAt: now,
          status: SOSMessageStatus.cancelled,
        ),
      );

      expect(staleActive.reason, ForwardingDecisionReason.dropStale);
      expect(duplicateCancelled.reason, ForwardingDecisionReason.dropDuplicate);
    },
  );

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

  test('relay count is metric only and does not stop forwarding', () {
    const policy = ForwardingPolicy();

    final decision = policy.decideSos(
      packet: sosPacket(timestampMs: now + 1000),
      nowMs: now,
      existingMessage: existingMessage(
        updatedAt: now - 1000,
        relayCount: MeshConfig.relayCountMetricSample,
      ),
    );

    expect(decision.shouldStore, true);
    expect(decision.shouldRelay, true);
    expect(decision.reason, ForwardingDecisionReason.relayAccepted);
  });

  test('basic flooding ignores controlled backoff and relay count metric', () {
    const policy = ForwardingPolicy(mode: ForwardingMode.basicFlooding);

    final decision = policy.decideSos(
      packet: sosPacket(timestampMs: now + 1000),
      nowMs: now,
      existingMessage: existingMessage(
        updatedAt: now - 1000,
        relayCount: MeshConfig.relayCountMetricSample,
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
