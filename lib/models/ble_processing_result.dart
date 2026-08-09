enum BleProcessingResult {
  accepted,
  duplicate,
  stale,
  suppressedByAck,
  invalid,
  failedRetryable;

  bool get shouldAcknowledgeInbox =>
      this == BleProcessingResult.accepted ||
      this == BleProcessingResult.duplicate ||
      this == BleProcessingResult.stale ||
      this == BleProcessingResult.suppressedByAck ||
      this == BleProcessingResult.invalid;

  bool get shouldRetryInbox => this == BleProcessingResult.failedRetryable;
}
