import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  String read(String path) => File(path).readAsStringSync();

  test('research monitor labels logical duplicate ratio and metric scopes', () {
    final source = read('lib/screen/research_monitor_screen.dart');

    expect(source, contains('Logical Duplicate Ratio'));
    expect(source, contains('_sessionMetrics'));
    expect(source, contains('_trialMetrics'));
    expect(source, contains('CURRENT SESSION'));
    expect(source, contains('CURRENT TRIAL'));
    expect(
      source,
      isNot(contains("_researchService.finishTrial(\n        _trial!.trialId")),
    );
  });

  test('research docs state clock-domain and duplicate semantics', () {
    final docs = read('docs/research_monitor.md');

    expect(docs, contains('LOCAL SAME DEVICE'));
    expect(docs, contains('Never mix clock domains'));
    expect(docs, contains('CROSS DEVICE'));
    expect(docs, contains('Logical Duplicate Ratio'));
    expect(docs, contains('native receiver/inbox dedup'));
    expect(docs, contains('protocol_timestamp_ms'));
  });

  test(
    'ACK termination event source checks terminated local SOS state first',
    () {
      final relay = read('lib/services/ble_relay_service.dart');

      expect(relay, contains('local_state = ?'));
      expect(relay, contains("'acked'"));
      expect(relay, contains('ExperimentEventTypes.sosRelayTerminatedByAck'));
      expect(relay, isNot(contains('eventAt = receivedAtMs')));
    },
  );
}
