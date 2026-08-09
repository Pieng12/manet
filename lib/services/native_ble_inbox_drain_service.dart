import 'package:pkmproject/models/ble_processing_result.dart';

typedef BleInboxProcessor =
    Future<BleProcessingResult> Function(String payloadBase64, {int? rssi});
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
      final rssi = item['rssi'] as int?;
      if (id == null || payloadBase64 == null || payloadBase64.isEmpty) {
        continue;
      }

      BleProcessingResult result;
      try {
        result = await process(payloadBase64, rssi: rssi);
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
}
