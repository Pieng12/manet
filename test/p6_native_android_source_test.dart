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
      expect(worker, isNot(contains('MeshBackgroundService')));
      expect(worker, isNot(contains('startForegroundService')));
      expect(worker, isNot(contains('startService')));
    },
  );

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
