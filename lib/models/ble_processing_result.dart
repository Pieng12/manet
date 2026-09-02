enum BleProcessingResult {
  accepted,
  duplicate,
  transportDuplicate,
  transportInProgress,
  stale,
  suppressedByAck,
  invalid,
  failedRetryable;

  bool get shouldAcknowledgeInbox =>
      this == BleProcessingResult.accepted ||
      this == BleProcessingResult.duplicate ||
      this == BleProcessingResult.transportDuplicate ||
      this == BleProcessingResult.stale ||
      this == BleProcessingResult.suppressedByAck ||
      this == BleProcessingResult.invalid;

  bool get shouldRetryInbox =>
      this == BleProcessingResult.transportInProgress ||
      this == BleProcessingResult.failedRetryable;
}
