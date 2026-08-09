import 'package:flutter_test/flutter_test.dart';
import 'package:pkmproject/models/ble_processing_result.dart';
import 'package:pkmproject/services/native_ble_inbox_drain_service.dart';

void main() {
  const service = NativeBleInboxDrainService();

  test('acknowledges completed native inbox outcomes', () async {
    final acknowledged = <String>[];
    final failed = <String>[];
    final results = <BleProcessingResult>[
      BleProcessingResult.accepted,
      BleProcessingResult.duplicate,
      BleProcessingResult.stale,
      BleProcessingResult.suppressedByAck,
      BleProcessingResult.invalid,
    ];

    final completed = await service.drain(
      items: [
        for (var i = 0; i < results.length; i++)
          {'id': 'item-$i', 'payload_base64': 'AA==', 'rssi': -60},
      ],
      process: (payloadBase64, {rssi}) async => results.removeAt(0),
      acknowledge: (id) async => acknowledged.add(id),
      fail: (id) async => failed.add(id),
    );

    expect(completed, true);
    expect(acknowledged, ['item-0', 'item-1', 'item-2', 'item-3', 'item-4']);
    expect(failed, isEmpty);
  });

  test('keeps retryable native inbox failures unacknowledged', () async {
    final acknowledged = <String>[];
    final failed = <String>[];

    final completed = await service.drain(
      items: [
        {'id': 'retryable', 'payload_base64': 'AA==', 'rssi': -70},
      ],
      process: (payloadBase64, {rssi}) async =>
          BleProcessingResult.failedRetryable,
      acknowledge: (id) async => acknowledged.add(id),
      fail: (id) async => failed.add(id),
    );

    expect(completed, false);
    expect(acknowledged, isEmpty);
    expect(failed, ['retryable']);
  });

  test('treats thrown processing errors as retryable inbox failures', () async {
    final acknowledged = <String>[];
    final failed = <String>[];

    final completed = await service.drain(
      items: [
        {'id': 'throws', 'payload_base64': 'AA==', 'rssi': -80},
      ],
      process: (payloadBase64, {rssi}) async {
        throw StateError('sqlite locked');
      },
      acknowledge: (id) async => acknowledged.add(id),
      fail: (id) async => failed.add(id),
    );

    expect(completed, false);
    expect(acknowledged, isEmpty);
    expect(failed, ['throws']);
  });
}
