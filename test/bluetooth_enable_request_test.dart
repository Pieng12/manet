import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pkmproject/services/native_bridge_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('id.ac.usu.resqmesh/mesh');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  for (final state in [
    'requested',
    'already_enabled',
    'permission_required',
    'unavailable',
    'failed',
  ]) {
    test(
      'enable request preserves native $state without starting scanner',
      () async {
        final calls = <String>[];
        messenger.setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          return {'state': state};
        });
        expect(
          (await NativeBridgeService.requestBluetoothEnable())['state'],
          state,
        );
        expect(calls, ['requestBluetoothEnable']);
      },
    );
  }

  test(
    'native uses Android consent and is not exposed in background command owner',
    () {
      final source = File(
        'android/app/src/main/kotlin/com/example/pkmproject/NativeBluetoothEnableRequest.kt',
      ).readAsStringSync();
      final background = File(
        'android/app/src/main/kotlin/com/example/pkmproject/MeshBackgroundService.kt',
      ).readAsStringSync();
      expect(source, contains('BluetoothAdapter.ACTION_REQUEST_ENABLE'));
      expect(source, isNot(contains('.enable()')));
      expect(source, contains('NativeBlePermissions.hasConnectPermission'));
      expect(background, isNot(contains('"requestBluetoothEnable"')));
    },
  );
}
