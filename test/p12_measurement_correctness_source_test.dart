import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  String read(String path) => File(path).readAsStringSync();

  test('BLE_PACKET_ACCEPTED is anchored to native RX timestamp fields', () {
    final relay = read('lib/services/ble_relay_service.dart');
    final acceptedIndex = relay.indexOf(
      'eventType: ExperimentEventTypes.blePacketAccepted',
    );
    expect(acceptedIndex, isNonNegative);
    final acceptedBlock = relay.substring(acceptedIndex, acceptedIndex + 700);

    expect(acceptedBlock, contains('eventTimestampMs: rxAtMs'));
    expect(
      acceptedBlock,
      contains('elapsedRealtimeMs: receivedElapsedRealtimeMs'),
    );
    expect(acceptedBlock, contains('protocolTimestampMs: packet.timestampMs'));
    expect(acceptedBlock, contains("packetType: 'sos'"));
    expect(acceptedBlock, contains('hopIn: packet.hopCount'));
    expect(acceptedBlock, contains('hopOut: message.hopCount'));
  });

  test('ACK termination is logged before ACK advertising startup', () {
    final relay = read('lib/services/ble_relay_service.dart');
    final processAckStart = relay.indexOf(
      'Future<BleProcessingResult> _processAck',
    );
    final processSosStart = relay.indexOf(
      'Future<BleProcessingResult> _processSos',
    );
    expect(processAckStart, isNonNegative);
    expect(processSosStart, isNonNegative);
    final processAck = relay.substring(processAckStart, processSosStart);

    final terminationIndex = processAck.indexOf(
      '_logSosRelayTerminatedByAck(packet);',
    );
    final advertiseIndex = processAck.indexOf(
      '_advertiser.advertiseLatestOrStop(preemptCurrent: true);',
    );
    expect(terminationIndex, isNonNegative);
    expect(advertiseIndex, isNonNegative);
    expect(terminationIndex, lessThan(advertiseIndex));
  });

  test('ACK termination is sender specific and duplicate suppressed', () {
    final relay = read('lib/services/ble_relay_service.dart');
    final advertiser = read('lib/services/ble_advertiser_service.dart');

    expect(relay, contains('FROM experiment_events'));
    expect(relay, contains('ExperimentEventTypes.sosRelayTerminatedByAck'));
    expect(relay, contains('message_id = ?'));
    expect(relay, contains('sender_crc = ?'));
    expect(relay, contains('protocol_timestamp_ms = ?'));
    expect(relay, contains('packet_type = ?'));
    expect(relay, contains('status = ?'));
    expect(relay, contains('stopAdvertisingIfCurrentMessage(messageId)'));
    expect(
      relay,
      contains('_advertiser.currentAdvertisedMessageId == messageId'),
    );
    expect(
      advertiser,
      contains('Future<void> stopAdvertisingIfCurrentMessage'),
    );
    expect(
      advertiser,
      contains('if (_currentAdvertisedMessageId == messageId)'),
    );
  });

  test('research monitor labels local TX scope explicitly', () {
    final screen = read('lib/screen/research_monitor_screen.dart');
    final docs = read('docs/research_monitor.md');

    expect(screen, contains('Local TX / Successful Trial'));
    expect(screen, contains('CURRENT SESSION / LOCAL DEVICE'));
    expect(docs, contains('local-device transmission metric'));
    expect(docs, contains('Network-wide overhead requires merged peer logs'));
  });
}
