int canonicalProtocolTimestamp(int timestampMs) {
  return (timestampMs ~/ 1000) * 1000;
}

int nextMonotonicProtocolTimestamp({
  required int candidateMs,
  required int previousMs,
}) {
  final candidateSecond = candidateMs ~/ 1000;
  final previousSecond = previousMs ~/ 1000;
  final nextSecond = candidateSecond <= previousSecond
      ? previousSecond + 1
      : candidateSecond;
  return nextSecond * 1000;
}
