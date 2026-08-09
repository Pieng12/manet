import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  String read(String path) => File(path).readAsStringSync();

  test(
    'Native BLE inbox worker uses headless Dart without foreground service fallback',
    () {
      final worker = read(
        'android/app/src/main/kotlin/com/example/pkmproject/NativeBleInboxWorker.kt',
      );

      expect(worker, contains('FlutterEngine'));
      expect(worker, contains('nativeBleInboxWorkerMain'));
      expect(worker, contains('NativeBleInbox.pending'));
      expect(worker, contains('NativeBleInbox.acknowledge'));
      expect(worker, contains('NativeBleInbox.fail'));
      expect(worker, contains('startNativeBleAdvertising'));
      expect(worker, contains('NativeBleAdvertiser.startAdvertising'));
      expect(worker, contains('setHasPendingRelayWork'));
      expect(worker, contains('enqueueIfPendingAndPermitted'));
      expect(worker, isNot(contains('MeshBackgroundService')));
      expect(worker, isNot(contains('startForegroundService')));
      expect(worker, isNot(contains('startService')));
    },
  );

  test('permission-blocked native inbox worker does not loop with retry', () {
    final worker = read(
      'android/app/src/main/kotlin/com/example/pkmproject/NativeBleInboxWorker.kt',
    );

    expect(worker, contains('NativeBleInbox.markPermissionBlocked'));
    expect(worker, contains('return Result.success()'));
    expect(
      worker,
      isNot(
        contains(
          'Permissions missing; BLE inbox recovery deferred")\n            return Result.retry()',
        ),
      ),
    );
  });

  test('all BLE wake foreground-service failures schedule worker recovery', () {
    final receiver = read(
      'android/app/src/main/kotlin/com/example/pkmproject/BleWakeUpReceiver.kt',
    );

    expect(receiver, contains('ForegroundServiceStartNotAllowedException'));
    expect(receiver, contains('SecurityException'));
    expect(receiver, contains('IllegalStateException'));
    expect(
      receiver,
      contains(
        'catch (e: Exception) {\n            NativeBleInboxWorker.enqueue(context)',
      ),
    );
  });

  test('headless Dart entrypoint reaches bounded relay attempt path', () {
    final main = read('lib/main.dart');
    final advertiser = read('lib/services/ble_advertiser_service.dart');

    expect(main, contains('nativeBleInboxWorkerMain'));
    expect(main, contains('_attemptHeadlessRelayIfEligible'));
    expect(main, contains('ExperimentEventTypes.headlessRelayAttempted'));
    expect(advertiser, contains('Future<bool> advertiseOneHeadlessSlot()'));
    expect(advertiser, contains('continueScheduling: false'));
  });

  test(
    'Native BLE inbox stores protocol metadata at fixed 17-byte offsets',
    () {
      final inbox = read(
        'android/app/src/main/kotlin/com/example/pkmproject/NativeBleInbox.kt',
      );

      expect(
        inbox,
        contains(
          'senderCrc = u32(payload[2], payload[3], payload[4], payload[5])',
        ),
      );
      expect(
        inbox,
        contains('timestampCompact = u24(payload[6], payload[7], payload[8])'),
      );
      expect(inbox, contains('status = payload[15].toInt() and 0xFF'));
      expect(inbox, contains('val flags = payload[16].toInt() and 0xFF'));
      expect(inbox, contains('hop = flags and 0x3F'));
    },
  );

  test('CI runs Flutter and native Android hardening checks', () {
    final workflow = read('.github/workflows/flutter.yml');

    expect(
      workflow,
      contains('dart format --output=none --set-exit-if-changed .'),
    );
    expect(workflow, contains('flutter analyze'));
    expect(workflow, contains('flutter test'));
    expect(workflow, contains('flutter build apk --debug'));
    expect(workflow, contains('testDebugUnitTest'));
  });
}
