import 'package:flutter_test/flutter_test.dart';
import 'package:pkmproject/models/experiment_session.dart';
import 'package:pkmproject/models/sos_message.dart';
import 'package:pkmproject/services/ble_protocol.dart';
import 'package:pkmproject/services/topology_policy.dart';

void main() {
  const policy = TopologyPolicy();
  const packet = BlePacket(
    kind: BlePacketKind.sos,
    senderCrc: 42,
    timestampMs: 1000,
    latitude: 3.5,
    longitude: 98.6,
    status: SOSMessageStatus.active,
    hopCount: 2,
  );

  ExperimentSession session({
    String role = 'RELAY',
    bool active = true,
    int? expectedHop = 2,
    String? allowed,
  }) => ExperimentSession(
    sessionId: 'session',
    deviceId: 'node',
    deviceModel: 'test',
    androidVersion: 'test',
    forwardingMode: 'trickle',
    maxHop: 63,
    messageLifetimeMs: 0,
    relayCooldownMs: 0,
    startedAt: 1,
    sessionKind: 'RESEARCH',
    nodeRole: role,
    protocolActive: active,
    expectedHopIn: expectedHop,
    allowedAdvertisersJson: allowed,
  );

  SOSMessage existing({
    int senderCrc = 42,
    int timestampMs = 1000,
    SOSMessageStatus status = SOSMessageStatus.active,
    int hopCount = 2,
  }) => SOSMessage(
    id: 'existing-$senderCrc-$timestampMs',
    senderId: 'ble-device-$senderCrc',
    senderCrc: senderCrc,
    content: 'SOS',
    latitude: 3.5,
    longitude: 98.6,
    status: status,
    createdAt: timestampMs,
    updatedAt: timestampMs,
    protocolTimestampMs: timestampMs,
    hopCount: hopCount,
  );

  test('destination accepts valid SOS without forwarding it', () {
    final result = policy.evaluate(
      packet: packet,
      session: session(role: 'DESTINATION'),
      observerKey: 'ble:source',
    );

    expect(result.acceptState, isTrue);
    expect(result.relay, isFalse);
    expect(result.reason, 'DESTINATION_ACCEPT');
  });

  test('unexpected hop is ignored before state and relay handling', () {
    final result = policy.evaluate(
      packet: packet,
      session: session(expectedHop: 1),
      observerKey: 'ble:source',
    );

    expect(result.acceptState, isFalse);
    expect(result.relay, isFalse);
    expect(result.reason, 'UNEXPECTED_HOP');
  });

  test('parallel relay with the same state is consistency-only', () {
    final result = policy.evaluate(
      packet: packet,
      session: session(expectedHop: 1),
      existingMessage: existing(),
      observerKey: 'ble:peer-relay',
    );

    expect(result.acceptForState, isFalse);
    expect(result.relay, isFalse);
    expect(result.countAsLogicalDuplicate, isTrue);
    expect(result.countAsTrickleConsistency, isTrue);
    expect(result.countAsTrickleInconsistency, isFalse);
    expect(result.isTopologyIgnored, isFalse);
    expect(result.reason, 'PARALLEL_RELAY_CONSISTENT');
  });

  test('parallel relay with different status is inconsistent', () {
    final result = policy.evaluate(
      packet: packet,
      session: session(expectedHop: 1),
      existingMessage: existing(status: SOSMessageStatus.resolved),
      observerKey: 'ble:peer-relay',
    );

    expect(result.countAsLogicalDuplicate, isFalse);
    expect(result.countAsTrickleConsistency, isFalse);
    expect(result.countAsTrickleInconsistency, isTrue);
    expect(result.reason, 'PARALLEL_RELAY_INCONSISTENT');
  });

  test('parallel hop with a different message key is ignored', () {
    final result = policy.evaluate(
      packet: packet,
      session: session(expectedHop: 1),
      existingMessage: existing(timestampMs: 2000),
      observerKey: 'ble:peer-relay',
    );

    expect(result.isTopologyIgnored, isTrue);
    expect(result.countAsTrickleConsistency, isFalse);
    expect(result.reason, 'UNEXPECTED_HOP');
  });

  test('hop 63 remains valid when topology expects hop 63', () {
    final result = policy.evaluate(
      packet: const BlePacket(
        kind: BlePacketKind.sos,
        senderCrc: 42,
        timestampMs: 1000,
        latitude: 3.5,
        longitude: 98.6,
        status: SOSMessageStatus.active,
        hopCount: 63,
      ),
      session: session(expectedHop: 63),
      observerKey: 'ble:source',
    );

    expect(result.acceptForState, isTrue);
    expect(result.relay, isTrue);
  });

  test('source ignores received packets even when hop matches', () {
    final result = policy.evaluate(
      packet: packet,
      session: session(role: 'SOURCE'),
      observerKey: 'ble:relay',
    );

    expect(result.isTopologyIgnored, isTrue);
    expect(result.reason, 'SOURCE_RX_IGNORED');
  });

  test('inactive and disallowed nodes are ignored deterministically', () {
    expect(
      policy
          .evaluate(
            packet: packet,
            session: session(active: false),
            observerKey: 'ble:source',
          )
          .reason,
      'NODE_INACTIVE',
    );
    expect(
      policy
          .evaluate(
            packet: packet,
            session: session(allowed: '["ble:other"]'),
            observerKey: 'ble:source',
          )
          .reason,
      'ADVERTISER_NOT_ALLOWED',
    );
  });

  test('packet from before the current trial is ignored', () {
    final result = policy.evaluate(
      packet: packet,
      session: session(),
      observerKey: 'ble:source',
      trialStartedAt: 2500,
    );

    expect(result.acceptState, isFalse);
    expect(result.reason, 'PREVIOUS_TRIAL_PACKET');
  });
}
