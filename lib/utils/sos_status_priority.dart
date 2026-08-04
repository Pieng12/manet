import 'package:pkmproject/models/sos_message.dart';

int sosStatusPriority(SOSMessageStatus status) {
  return switch (status) {
    SOSMessageStatus.active => 0,
    SOSMessageStatus.cancelled => 1,
    SOSMessageStatus.resolved => 2,
  };
}

bool isValidAckStatus(SOSMessageStatus status) {
  return status == SOSMessageStatus.cancelled ||
      status == SOSMessageStatus.resolved;
}
