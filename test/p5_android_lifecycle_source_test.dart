import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  String read(String path) => File(path).readAsStringSync();

  test('Android identity and BLE foreground service contract are final', () {
    final manifest = read('android/app/src/main/AndroidManifest.xml');
    final gradle = read('android/app/build.gradle.kts');
    final mainActivity = read(
      'android/app/src/main/kotlin/com/example/pkmproject/MainActivity.kt',
    );

    expect(gradle, contains('namespace = "id.ac.usu.resqmesh"'));
    expect(gradle, contains('applicationId = "id.ac.usu.resqmesh"'));
    expect(gradle, contains('minSdk = 26'));
    expect(gradle, isNot(contains('signingConfigs.getByName("debug")')));
    expect(manifest, contains('package="id.ac.usu.resqmesh"'));
    expect(
      manifest,
      contains('android:foregroundServiceType="connectedDevice"'),
    );
    expect(manifest, isNot(contains('FOREGROUND_SERVICE_DATA_SYNC')));
    expect(manifest, isNot(contains('dataSync')));
    expect(mainActivity, contains('id.ac.usu.resqmesh/mesh'));
  });

  test('BLE wake receiver is internal and Android 12+ safe', () {
    final manifest = read('android/app/src/main/AndroidManifest.xml');
    final receiver = read(
      'android/app/src/main/kotlin/com/example/pkmproject/BleWakeUpReceiver.kt',
    );

    expect(manifest, contains('android:name=".BleWakeUpReceiver"'));
    expect(manifest, contains('android:exported="false"'));
    expect(manifest, isNot(contains('id.ac.usu.resqmesh.BLE_WAKE_UP"/')));
    expect(receiver, contains('NativeBleInbox.store'));
    expect(receiver, contains('Build.VERSION_CODES.S'));
    expect(receiver, contains('!MeshBackgroundService.serviceStarted'));
    expect(receiver, contains('NativeBleInboxWorker.enqueue'));
    expect(receiver, contains('ForegroundServiceStartNotAllowedException'));
    expect(receiver, isNot(contains(r'deviceAddress}_$hex')));
  });

  test('native scan filter requires manufacturer id and RM header mask', () {
    final manager = read(
      'android/app/src/main/kotlin/com/example/pkmproject/NativeBleManager.kt',
    );
    final config = read(
      'android/app/src/main/kotlin/com/example/pkmproject/NativeBleConfig.kt',
    );

    expect(manager, contains('setManufacturerData('));
    expect(manager, contains('byteArrayOf(0x52, 0x4D)'));
    expect(manager, contains('byteArrayOf(0xFF.toByte(), 0xFF.toByte())'));
    expect(manager, contains('setPackage(context.packageName)'));
    expect(config, contains('const val MANUFACTURER_ID = 0xFFFF'));
  });

  test('native inbox and diagnostics method channel are wired', () {
    final service = read(
      'android/app/src/main/kotlin/com/example/pkmproject/MeshBackgroundService.kt',
    );
    final bridge = read('lib/services/native_bridge_service.dart');
    final main = read('lib/main.dart');

    for (final method in [
      'getPendingBleInbox',
      'acknowledgeBleInboxItem',
      'failBleInboxItem',
      'hasPendingRelayWork',
      'setRelayModeEnabled',
      'getBleCapabilities',
    ]) {
      expect(service, contains(method));
      expect(bridge, contains(method));
    }
    expect(main, contains('_drainNativeBleInbox'));
    expect(main, contains('inbox_id'));
  });

  test('WorkManager gateway sync uses unique keep policy with backoff', () {
    final workmanager = read('lib/services/workmanager_service.dart');
    final relay = read('lib/services/ble_relay_service.dart');
    final main = read('lib/main.dart');

    expect(
      workmanager,
      contains("gatewaySyncWorkName = 'resqmeshGatewaySync'"),
    );
    expect(workmanager, contains('ExistingWorkPolicy.keep'));
    expect(workmanager, contains('NetworkType.connected'));
    expect(workmanager, contains('BackoffPolicy.exponential'));
    expect(relay, contains('WorkManagerService.registerSyncTask'));
    expect(main, contains('WorkManagerService.registerSyncTask();'));
  });

  test('scheduler wake and native advertiser reconciliation are present', () {
    final advertiser = read('lib/services/ble_advertiser_service.dart');
    final queue = read('lib/services/relay_queue_service.dart');
    final nativeAdvertiser = read(
      'android/app/src/main/kotlin/com/example/pkmproject/NativeBleAdvertiser.kt',
    );

    expect(queue, contains('Future<int?> earliestNextEligibleAt()'));
    expect(advertiser, contains('Timer? _queueWakeTimer'));
    expect(advertiser, contains('RelaySchedulerState.waitingNextSlot'));
    expect(advertiser, contains('reconcileNativeAdvertisingState'));
    expect(nativeAdvertiser, contains('advertiseGeneration'));
    expect(nativeAdvertiser, contains('Ignoring stale advertiser'));
  });

  test('versioned permission contract is documented in code and manifest', () {
    final manifest = read('android/app/src/main/AndroidManifest.xml');
    final permissions = read('lib/services/android_permission_service.dart');

    expect(manifest, contains('ACCESS_BACKGROUND_LOCATION'));
    expect(manifest, contains('android:maxSdkVersion="30"'));
    expect(permissions, contains('sdkInt >= 29 && sdkInt <= 30'));
    expect(permissions, contains('Permission.locationAlways'));
    expect(permissions, contains('sdkInt >= 33'));
    expect(permissions, contains('Permission.notification'));
  });
}
