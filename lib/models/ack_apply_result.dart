enum AckApplyResult {
  inserted,
  replacedNewerTimestamp,
  replacedHigherStatus,
  duplicate,
  rejectedOlder,
  rejectedInvalid,
  rejectedFuture,
}

extension AckApplyResultX on AckApplyResult {
  bool get shouldRelay {
    return this == AckApplyResult.inserted ||
        this == AckApplyResult.replacedNewerTimestamp ||
        this == AckApplyResult.replacedHigherStatus;
  }

  bool get rejected {
    return this == AckApplyResult.rejectedOlder ||
        this == AckApplyResult.rejectedInvalid ||
        this == AckApplyResult.rejectedFuture;
  }
}
