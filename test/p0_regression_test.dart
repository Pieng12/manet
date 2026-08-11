import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pkmproject/config/mesh_config.dart';
import 'package:pkmproject/models/sos_message.dart';
import 'package:pkmproject/services/experiment_logger.dart';
import 'package:pkmproject/sync_service.dart';

void main() {
  final now = DateTime.utc(2026, 8, 4, 12).millisecondsSinceEpoch;

  SOSMessage message(
    String id, {
    int isSynced = 0,
    bool fromServer = false,
    int? ackReceivedAt,
    String localState = 'pending',
    int? expiresAt,
    int offsetMs = 0,
  }) {
    final timestamp = now + offsetMs;
    return SOSMessage(
      id: id,
      senderId: 'device-$id',
      senderCrc: id.hashCode,
      content: 'SOS',
      latitude: -6.2,
      longitude: 106.8,
      status: SOSMessageStatus.active,
      createdAt: timestamp,
      updatedAt: timestamp,
      isSynced: isSynced,
      fromServer: fromServer,
      ackReceivedAt: ackReceivedAt,
      localState: localState,
      expiresAt:
          expiresAt ?? now + MeshConfig.defaultMessageLifetime.inMilliseconds,
    );
  }

  test('BleRelayService does not force SOS advertising outside queue', () {
    final source = File(
      'lib/services/ble_relay_service.dart',
    ).readAsStringSync();

    expect(source, isNot(contains('startAdvertising(sosMessage')));
    expect(source, contains('enqueueSos'));
  });

  test('only background entrypoint claims scheduler ownership', () {
    final mainSource = File('lib/main.dart').readAsStringSync();
    final homeSource = File('lib/screen/home_screen.dart').readAsStringSync();
    final permissionSource = File(
      'lib/screen/permission_screen.dart',
    ).readAsStringSync();

    expect(mainSource, contains('backgroundServiceMain'));
    expect(mainSource, contains('claimSchedulerOwnership'));
    expect(homeSource, isNot(contains('claimSchedulerOwnership')));
    expect(permissionSource, isNot(contains('claimSchedulerOwnership')));
  });

  test(
    'gateway upload candidates exclude terminal/server rows but not old SOS',
    () {
      final validOld = message('valid-old', offsetMs: -1000)..senderCrc = 777;
      final validNewer = message('valid-newer', offsetMs: 1000)
        ..senderCrc = 777;
      final oldSos = message('old', expiresAt: now - 1)..senderCrc = 888;
      final worseHop = message('worse-hop', offsetMs: 2000)
        ..senderCrc = 999
        ..hopCount = 3;
      final betterHop = message('better-hop', offsetMs: 2000)
        ..senderCrc = 999
        ..hopCount = 1;
      final candidates = SyncService.filterGatewayUploadCandidates([
        validOld,
        validNewer,
        worseHop,
        betterHop,
        message('synced', isSynced: 1),
        message('acked', ackReceivedAt: now),
        oldSos,
        message('server', fromServer: true),
      ], nowMs: now);

      expect(candidates.map((item) => item.id).toSet(), {
        validNewer.id,
        betterHop.id,
        oldSos.id,
      });
    },
  );

  test('server backoff is cleared after elapsed time', () {
    final nowDate = DateTime.utc(2026, 8, 4, 12);
    final active = nowDate.add(const Duration(minutes: 1));
    final elapsed = nowDate.subtract(const Duration(seconds: 1));

    expect(SyncService.isServerBackoffActive(active, nowDate), true);
    expect(SyncService.clearBackoffIfElapsed(active, nowDate), active);
    expect(SyncService.clearBackoffIfElapsed(elapsed, nowDate), isNull);
  });

  test('new experiment event constants are available', () {
    expect(ExperimentEventTypes.bleAdvertiseStarted, 'BLE_ADVERTISE_STARTED');
    expect(ExperimentEventTypes.bleAdvertiseFailed, 'BLE_ADVERTISE_FAILED');
    expect(ExperimentEventTypes.bleRelayStarted, 'BLE_RELAY_STARTED');
    expect(ExperimentEventTypes.messageExpired, 'MESSAGE_EXPIRED');
  });
}
