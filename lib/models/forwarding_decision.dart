enum ForwardingDecisionReason {
  relayAccepted('RELAY_ACCEPTED'),
  dropInvalid('DROP_INVALID'),
  dropDuplicate('DROP_DUPLICATE'),
  dropStale('DROP_STALE'),
  dropCooldown('DROP_COOLDOWN'),
  dropAcked('DROP_ACKED'),
  dropOwnPacket('DROP_OWN_PACKET');

  const ForwardingDecisionReason(this.code);

  final String code;
}

class ForwardingDecision {
  final bool shouldStore;
  final bool shouldRelay;
  final ForwardingDecisionReason reason;
  final int? nextHopCount;
  final int? nextEligibleAt;

  const ForwardingDecision({
    required this.shouldStore,
    required this.shouldRelay,
    required this.reason,
    this.nextHopCount,
    this.nextEligibleAt,
  });
}
