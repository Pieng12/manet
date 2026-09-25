import 'package:uuid/uuid.dart';

abstract interface class ClockSource {
  int wallTimeMs();

  int monotonicTimeMs();

  String get monotonicDomainId;
}

class ExperimentClock implements ClockSource {
  ExperimentClock._()
    : _stopwatch = Stopwatch()..start(),
      _domainId = const Uuid().v4();

  static final ExperimentClock instance = ExperimentClock._();

  final Stopwatch _stopwatch;
  final String _domainId;

  @override
  int wallTimeMs() => DateTime.now().millisecondsSinceEpoch;

  @override
  int monotonicTimeMs() => _stopwatch.elapsedMilliseconds;

  @override
  String get monotonicDomainId => _domainId;
}

class FixedExperimentClock implements ClockSource {
  FixedExperimentClock({
    required this.wallMs,
    required this.monotonicMs,
    this.monotonicDomainId = 'test-boot',
  });

  int wallMs;
  int monotonicMs;

  @override
  final String monotonicDomainId;

  @override
  int wallTimeMs() => wallMs;

  @override
  int monotonicTimeMs() => monotonicMs;
}
