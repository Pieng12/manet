import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  String read(String path) => File(path).readAsStringSync();

  test('Bluetooth OFF handlers mark radio inactive without clearing queues', () {
    final manager = read(
      'android/app/src/main/kotlin/com/example/pkmproject/NativeBleManager.kt',
    );
    final service = read(
      'android/app/src/main/kotlin/com/example/pkmproject/MeshBackgroundService.kt',
    );
    final activity = read(
      'android/app/src/main/kotlin/com/example/pkmproject/MainActivity.kt',
    );

    expect(manager, contains('Bluetooth disabled; scan marked inactive'));
    expect(
      manager,
      contains('stopTelemetryForUnavailable("BLUETOOTH_DISABLED")'),
    );
    expect(
      manager,
      contains('stopTelemetryForUnavailable("SCANNER_UNAVAILABLE")'),
    );
    expect(manager, contains('stopTelemetryForStopAttempt('));
    expect(manager, isNot(contains('bluetoothLeScanner ?: return false')));

    for (final source in [service, activity]) {
      expect(source, contains('BluetoothAdapter.STATE_OFF'));
      expect(source, contains('NativeBleManager.stopBleScan'));
      expect(source, isNot(contains('deleteMessage')));
      expect(source, isNot(contains('clearRelay')));
      expect(source, isNot(contains('DELETE FROM relay_queue')));
      expect(source, isNot(contains('DELETE FROM sos_messages')));
    }
  });

  test('Bluetooth ON handlers restart scan and trigger scheduler recovery', () {
    final service = read(
      'android/app/src/main/kotlin/com/example/pkmproject/MeshBackgroundService.kt',
    );
    final activity = read(
      'android/app/src/main/kotlin/com/example/pkmproject/MainActivity.kt',
    );

    expect(activity, contains('BluetoothAdapter.STATE_ON'));
    expect(activity, contains('NativeBleManager.startBleScan(appContext)'));
    expect(
      activity,
      contains('NativeBleInboxWorker.enqueueIfPendingAndPermitted(appContext)'),
    );
    expect(activity, contains('requestSchedulerTick()'));

    expect(service, contains('BluetoothAdapter.STATE_ON'));
    expect(
      service,
      contains('NativeBleManager.startBleScan(this@MeshBackgroundService)'),
    );
    expect(
      service,
      contains(
        'NativeBleInboxWorker.enqueueIfPendingAndPermitted(this@MeshBackgroundService)',
      ),
    );
    expect(service, contains('sendWakeUpToFlutter("environmentResumed"'));
  });

  test('BLE capability bridges report effective advertiser state', () {
    final advertiser = read(
      'android/app/src/main/kotlin/com/example/pkmproject/NativeBleAdvertiser.kt',
    );
    final telemetry = read(
      'android/app/src/main/kotlin/com/example/pkmproject/NativeBleRuntimeTelemetry.kt',
    );
    final service = read(
      'android/app/src/main/kotlin/com/example/pkmproject/MeshBackgroundService.kt',
    );
    final activity = read(
      'android/app/src/main/kotlin/com/example/pkmproject/MainActivity.kt',
    );

    expect(
      advertiser,
      contains('NativeBleRuntimeTelemetry.advertisingStatusMap'),
    );
    expect(telemetry, contains('val effectiveActive ='));
    expect(
      telemetry,
      contains('bluetoothEnabled && advertiserAvailable && rawActive'),
    );
    expect(activity, contains('NativeBleAdvertiser.statusMap(this)'));
    expect(service, contains('NativeBleAdvertiser.statusMap(this)'));
    expect(
      activity,
      contains('"nativeAdvertisingActive" to advertiseStatus["active"]'),
    );
    expect(
      service,
      contains('"nativeAdvertisingActive" to advertiseStatus["active"]'),
    );
  });
}
