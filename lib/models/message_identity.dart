import 'package:pkmproject/utils/protocol_timestamp.dart';

class MessageKey {
  const MessageKey({
    required this.senderCrc,
    required this.protocolTimestampMs,
  });

  final int senderCrc;
  final int protocolTimestampMs;

  String get value =>
      '$senderCrc:${canonicalProtocolTimestamp(protocolTimestampMs)}';

  @override
  String toString() => value;

  @override
  bool operator ==(Object other) =>
      other is MessageKey &&
      other.senderCrc == senderCrc &&
      canonicalProtocolTimestamp(other.protocolTimestampMs) ==
          canonicalProtocolTimestamp(protocolTimestampMs);

  @override
  int get hashCode =>
      Object.hash(senderCrc, canonicalProtocolTimestamp(protocolTimestampMs));
}

class StateIdentity {
  const StateIdentity({
    required this.messageKey,
    required this.statusIndex,
    required this.isAck,
    required this.fromServer,
  });

  final MessageKey messageKey;
  final int statusIndex;
  final bool isAck;
  final bool fromServer;

  String get value =>
      '${messageKey.value}:$statusIndex:${isAck ? 1 : 0}:${fromServer ? 1 : 0}';

  @override
  String toString() => value;
}
