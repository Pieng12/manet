import 'package:pkmproject/models/sos_message.dart';
import 'package:pkmproject/utils/protocol_timestamp.dart';
import 'package:pkmproject/utils/sos_status_priority.dart';

int compareSosState(SOSMessage a, SOSMessage b) {
  final timestampCompare = canonicalProtocolTimestamp(
    a.updatedAt,
  ).compareTo(canonicalProtocolTimestamp(b.updatedAt));
  if (timestampCompare != 0) return timestampCompare;

  final statusCompare = sosStatusPriority(
    a.status,
  ).compareTo(sosStatusPriority(b.status));
  if (statusCompare != 0) return statusCompare;

  if (a.hopCount < b.hopCount) return 1;
  if (a.hopCount > b.hopCount) return -1;
  return 0;
}

SOSMessage preferredSosState(SOSMessage a, SOSMessage b) {
  return compareSosState(a, b) >= 0 ? a : b;
}
