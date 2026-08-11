import 'package:pkmproject/models/ble_processing_result.dart';

typedef BleInboxProcessor =
    Future<BleProcessingResult> Function(
      String payloadBase64, {
      int? rssi,
      int? receivedAtMs,
      int? receivedElapsedRealtimeMs,
    });
typedef BleInboxItemHandler = Future<void> Function(String id);

class NativeBleInboxDrainService {
  const NativeBleInboxDrainService();

  Future<bool> drain({
    required List<Map<String, dynamic>> items,
    required BleInboxProcessor process,
    required BleInboxItemHandler acknowledge,
    required BleInboxItemHandler fail,
  }) async {
    var allCompleted = true;
    for (final item in items) {
      final id = item['id'] as String?;
      final payloadBase64 = item['payload_base64'] as String?;
      final rssi = _asInt(item['rssi']);
      final receivedAtMs = _asInt(item['received_at']);
      final receivedElapsedRealtimeMs = _asInt(
        item['received_elapsed_realtime_ms'],
      );
      if (id == null || payloadBase64 == null || payloadBase64.isEmpty) {
        continue;
      }

      BleProcessingResult result;
      try {
        result = await process(
          payloadBase64,
          rssi: rssi,
          receivedAtMs: receivedAtMs,
          receivedElapsedRealtimeMs: receivedElapsedRealtimeMs,
        );
      } catch (_) {
        result = BleProcessingResult.failedRetryable;
      }
      if (result.shouldAcknowledgeInbox) {
        await acknowledge(id);
      } else {
        allCompleted = false;
        await fail(id);
      }
    }
    return allCompleted;
  }

  static int? _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }
}
