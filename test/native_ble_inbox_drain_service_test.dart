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
      process:
          (
            payloadBase64, {
            rssi,
            receivedAtMs,
            receivedElapsedRealtimeMs,
            deviceAddress,
            observationId,
            observerKey,
            sourcePath,
          }) async => results.removeAt(0),
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
      process:
          (
            payloadBase64, {
            rssi,
            receivedAtMs,
            receivedElapsedRealtimeMs,
            deviceAddress,
            observationId,
            observerKey,
            sourcePath,
          }) async => BleProcessingResult.failedRetryable,
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
      process:
          (
            payloadBase64, {
            rssi,
            receivedAtMs,
            receivedElapsedRealtimeMs,
            deviceAddress,
            observationId,
            observerKey,
            sourcePath,
          }) async {
            throw StateError('sqlite locked');
          },
      acknowledge: (id) async => acknowledged.add(id),
      fail: (id) async => failed.add(id),
    );

    expect(completed, false);
    expect(acknowledged, isEmpty);
    expect(failed, ['throws']);
  });

  test('passes native receive timestamps to processor', () async {
    int? receivedAt;
    int? elapsedAt;
    String? seenObservationId;
    String? seenObserverKey;

    final completed = await service.drain(
      items: [
        {
          'id': 'timed',
          'payload_base64': 'AA==',
          'rssi': -81,
          'received_at': 123456,
          'received_elapsed_realtime_ms': 654321,
          'observation_id': 'obs-123',
          'observer_key': 'ble:AA:BB',
        },
      ],
      process:
          (
            payloadBase64, {
            rssi,
            receivedAtMs,
            receivedElapsedRealtimeMs,
            deviceAddress,
            observationId,
            observerKey,
            sourcePath,
          }) async {
            receivedAt = receivedAtMs;
            elapsedAt = receivedElapsedRealtimeMs;
            seenObservationId = observationId;
            seenObserverKey = observerKey;
            return BleProcessingResult.accepted;
          },
      acknowledge: (_) async {},
      fail: (_) async {},
    );

    expect(completed, true);
    expect(receivedAt, 123456);
    expect(elapsedAt, 654321);
    expect(seenObservationId, 'obs-123');
    expect(seenObserverKey, 'ble:AA:BB');
  });
}
