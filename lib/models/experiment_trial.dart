class ExperimentTrial {
  final String trialId;
  final String sessionId;
  final int trialNumber;
  final String trialCode;
  final int startedAt;
  final int? endedAt;
  final String status;
  final String? result;
  final String? failureReason;
  final String? notes;

  const ExperimentTrial({
    required this.trialId,
    required this.sessionId,
    required this.trialNumber,
    required this.trialCode,
    required this.startedAt,
    this.endedAt,
    required this.status,
    this.result,
    this.failureReason,
    this.notes,
  });

  Map<String, dynamic> toDbMap() {
    return {
      'trial_id': trialId,
      'session_id': sessionId,
      'trial_number': trialNumber,
      'trial_code': trialCode,
      'started_at': startedAt,
      'ended_at': endedAt,
      'status': status,
      'result': result,
      'failure_reason': failureReason,
      'notes': notes,
    };
  }

  factory ExperimentTrial.fromDbMap(Map<String, dynamic> map) {
    return ExperimentTrial(
      trialId: map['trial_id'] as String,
      sessionId: map['session_id'] as String,
      trialNumber: map['trial_number'] as int,
      trialCode: map['trial_code'] as String,
      startedAt: map['started_at'] as int,
      endedAt: map['ended_at'] as int?,
      status: map['status'] as String,
      result: map['result'] as String?,
      failureReason: map['failure_reason'] as String?,
      notes: map['notes'] as String?,
    );
  }

  bool get isRunning => status == 'RUNNING';
  bool get isInvalid => status == 'INVALID';
  bool get isCompleted => status == 'COMPLETED';
  bool get isSuccess => result == 'SUCCESS';
}
