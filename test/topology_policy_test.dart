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
