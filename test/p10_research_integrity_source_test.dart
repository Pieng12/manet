import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  String read(String path) => File(path).readAsStringSync();

  test(
    'research monitor does not expose editable forwarding mode selector',
    () {
      final source = read('lib/screen/research_monitor_screen.dart');

      expect(source, isNot(contains("values: const ['controlled_epidemic'")));
      expect(source, contains('MeshConfig.forwardingMode.logValue'));
    },
  );

  test('native inbox persists received elapsed realtime timestamp', () {
    final inbox = read(
      'android/app/src/main/kotlin/com/example/pkmproject/NativeBleInbox.kt',
    );
    final receiver = read(
      'android/app/src/main/kotlin/com/example/pkmproject/BleWakeUpReceiver.kt',
    );
    final service = read(
      'android/app/src/main/kotlin/com/example/pkmproject/MeshBackgroundService.kt',
    );

    expect(inbox, contains('received_elapsed_realtime_ms'));
    expect(receiver, contains('SystemClock.elapsedRealtime()'));
    expect(service, contains('received_elapsed_realtime_ms'));
  });

  test(
    'ACK termination uses production event, not placeholder metric event',
    () {
      final logger = read('lib/services/experiment_logger.dart');
      final relay = read('lib/services/ble_relay_service.dart');
      final metrics = read('lib/services/research_metrics_service.dart');

      expect(logger, contains('SOS_RELAY_TERMINATED_BY_ACK'));
      expect(relay, contains('sosRelayTerminatedByAck'));
      expect(metrics, isNot(contains("'LOCAL_RELAY_STOPPED'")));
    },
  );
}
