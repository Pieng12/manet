import 'package:flutter_test/flutter_test.dart';
import 'package:pkmproject/models/ack_apply_result.dart';
import 'package:pkmproject/models/ble_processing_result.dart';
import 'package:pkmproject/services/ble_relay_service.dart';
import 'package:pkmproject/services/experiment_logger.dart';

void main() {
  test('duplicate ACK maps to generic duplicate analytics', () {
    expect(
      BleRelayService.genericAckPacketEventTypeForResult(
        AckApplyResult.duplicate,
      ),
      ExperimentEventTypes.blePacketDuplicate,
    );
    expect(
      BleRelayService.processingResultForAckApplyResult(
        AckApplyResult.duplicate,
      ),
      BleProcessingResult.duplicate,
    );
  });

  test('stale ACK maps to stale analytics and not duplicate', () {
    expect(
      BleRelayService.genericAckPacketEventTypeForResult(
        AckApplyResult.rejectedOlder,
      ),
      ExperimentEventTypes.blePacketStale,
    );
    expect(
      BleRelayService.genericAckPacketEventTypeForResult(
        AckApplyResult.rejectedOlder,
      ),
      isNot(ExperimentEventTypes.blePacketDuplicate),
    );
    expect(
      BleRelayService.processingResultForAckApplyResult(
        AckApplyResult.rejectedOlder,
      ),
      BleProcessingResult.stale,
    );
  });

  test('invalid ACK maps to invalid result and drop analytics', () {
    expect(
      BleRelayService.genericAckPacketEventTypeForResult(
        AckApplyResult.rejectedInvalid,
      ),
      ExperimentEventTypes.bleRelayDropped,
    );
    expect(
      BleRelayService.genericAckPacketEventTypeForResult(
        AckApplyResult.rejectedFuture,
      ),
      ExperimentEventTypes.bleRelayDropped,
    );
    expect(
      BleRelayService.processingResultForAckApplyResult(
        AckApplyResult.rejectedFuture,
      ),
      BleProcessingResult.invalid,
    );
  });
}
