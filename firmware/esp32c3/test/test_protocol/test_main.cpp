#include <unity.h>

#include <cmath>

#include "Protocol.h"
#include "RadioConfig.h"
#include "TrickleTiming.h"

using namespace resqmesh;

void setUp() {}

void tearDown() {}

void test_round_trip_signed_coordinates_and_hop() {
  Packet source;
  source.senderCrc = 0x12345678;
  source.timestampSeconds = kEpochSeconds + 42;
  source.latitude = -6.2001;
  source.longitude = 106.8167;
  source.status = Status::Active;
  source.hop = 63;
  std::array<uint8_t, kPayloadLength> bytes{};
  TEST_ASSERT_TRUE(encode(source, bytes));

  Packet decoded;
  TEST_ASSERT_TRUE(decode(bytes.data(), bytes.size(), decoded));
  TEST_ASSERT_EQUAL_UINT32(source.senderCrc, decoded.senderCrc);
  TEST_ASSERT_EQUAL_INT32(std::lround(source.latitude * 10000),
                          std::lround(decoded.latitude * 10000));
  TEST_ASSERT_EQUAL_INT32(std::lround(source.longitude * 10000),
                          std::lround(decoded.longitude * 10000));
  TEST_ASSERT_EQUAL_UINT8(63, decoded.hop);
  TEST_ASSERT_EQUAL_UINT8(63, saturatedRelayHop(decoded.hop));
}

void test_exact_epoch_boundaries() {
  TEST_ASSERT_TRUE(epochValid(kEpochSeconds));
  TEST_ASSERT_TRUE(epochValid(epochEndSeconds()));
  TEST_ASSERT_FALSE(epochValid(static_cast<uint64_t>(kEpochSeconds) - 1));
  TEST_ASSERT_FALSE(epochValid(epochEndSeconds() + 1));
}

void test_company_id_is_removed_from_manufacturer_data() {
  uint8_t raw[kPayloadLength + 2] = {0xFF, 0xFF};
  raw[2] = 0x52;
  raw[3] = 0x4D;
  std::array<uint8_t, kPayloadLength> payload{};
  TEST_ASSERT_TRUE(extractApplicationPayload(raw, sizeof(raw), payload));
  TEST_ASSERT_EQUAL_HEX8(0x52, payload[0]);
  TEST_ASSERT_EQUAL_HEX8(0x4D, payload[1]);
}

void test_research_protocol_contract_is_stable() {
  TEST_ASSERT_EQUAL_UINT32(17, kPayloadLength);
  TEST_ASSERT_EQUAL_HEX16(0xFFFF, kManufacturerId);
  TEST_ASSERT_EQUAL_STRING("resqmesh-ble17-v1", kProtocolVersion);
  TEST_ASSERT_EQUAL_UINT8(2, saturatedRelayHop(1));
  TEST_ASSERT_EQUAL_UINT8(63, saturatedRelayHop(63));
}

void test_cross_node_identities_use_millisecond_timestamp() {
  Packet packet;
  packet.senderCrc = 2110340604;
  packet.timestampSeconds = 1790450822;
  packet.status = Status::Active;

  TEST_ASSERT_EQUAL_STRING("2110340604:1790450822000",
                           messageKey(packet).c_str());
  TEST_ASSERT_EQUAL_STRING("2110340604:1790450822000:1:0:0",
                           stateIdentity(packet).c_str());
}

void test_only_parallel_relay_counts_trickle_consistency() {
  TEST_ASSERT_FALSE(
      shouldCountTrickleConsistency(true, true, true, true, 1, 1));
  TEST_ASSERT_TRUE(
      shouldCountTrickleConsistency(true, true, true, true, 2, 1));
  TEST_ASSERT_FALSE(
      shouldCountTrickleConsistency(false, true, true, true, 2, 1));
  TEST_ASSERT_FALSE(
      shouldCountTrickleConsistency(true, true, true, false, 2, 1));
  TEST_ASSERT_FALSE(
      shouldCountTrickleConsistency(true, false, true, true, 2, 1));
}

void test_observations_use_per_advertiser_inactivity_gap() {
  ObservationTracker tracker(1000);
  const auto firstA = tracker.observe("receiver", "A", "state", 100);
  const auto repeatA = tracker.observe("receiver", "A", "state", 500);
  const auto firstB = tracker.observe("receiver", "B", "state", 600);
  const auto interleavedA = tracker.observe("receiver", "A", "state", 1200);
  const auto nextA = tracker.observe("receiver", "A", "state", 2200);

  TEST_ASSERT_TRUE(firstA.isNew);
  TEST_ASSERT_FALSE(repeatA.isNew);
  TEST_ASSERT_EQUAL_STRING(firstA.observationId.c_str(),
                           repeatA.observationId.c_str());
  TEST_ASSERT_TRUE(firstB.isNew);
  TEST_ASSERT_FALSE(interleavedA.isNew);
  TEST_ASSERT_EQUAL_STRING(firstA.observationId.c_str(),
                           interleavedA.observationId.c_str());
  TEST_ASSERT_TRUE(nextA.isNew);
  TEST_ASSERT_NOT_EQUAL(0,
                        firstA.observationId.compare(nextA.observationId));
}

void test_observation_tracker_is_bounded_and_evicts_oldest() {
  ObservationTracker tracker(1000);
  for (size_t index = 0; index < kObservationTrackerCapacity; index++) {
    const auto decision = tracker.observe(
        "receiver", "advertiser-" + std::to_string(index), "state",
        static_cast<uint32_t>(100 + index));
    TEST_ASSERT_TRUE(decision.isNew);
  }
  TEST_ASSERT_EQUAL_UINT32(kObservationTrackerCapacity,
                           tracker.activeEntryCount());

  const auto overflow =
      tracker.observe("receiver", "overflow", "state", 10000);
  TEST_ASSERT_TRUE(overflow.isNew);
  TEST_ASSERT_EQUAL_UINT32(kObservationTrackerCapacity,
                           tracker.activeEntryCount());
  const auto evicted =
      tracker.observe("receiver", "advertiser-0", "state", 10001);
  TEST_ASSERT_TRUE(evicted.isNew);
  TEST_ASSERT_EQUAL_UINT32(kObservationTrackerCapacity,
                           tracker.activeEntryCount());
}

void test_extended_manufacturer_boundary_for_sos_and_ack() {
  for (auto kind : {PacketKind::Sos, PacketKind::Ack}) {
    Packet packet;
    packet.kind = kind;
    packet.timestampSeconds = kEpochSeconds + 123;
    packet.status = kind == PacketKind::Ack ? Status::Resolved : Status::Active;
    packet.hop = 63;
    std::array<uint8_t, kPayloadLength> payload{};
    TEST_ASSERT_TRUE(encode(packet, payload));
    const auto manufacturer = manufacturerPayload(payload);
    TEST_ASSERT_EQUAL_UINT32(19, manufacturer.size());
    TEST_ASSERT_EQUAL_HEX8(0xff, manufacturer[0]);
    TEST_ASSERT_EQUAL_HEX8(0xff, manufacturer[1]);
    std::array<uint8_t, kPayloadLength> recovered{};
    TEST_ASSERT_TRUE(extractApplicationPayload(manufacturer.data(), manufacturer.size(), recovered));
    TEST_ASSERT_EQUAL_UINT8_ARRAY(payload.data(), recovered.data(), kPayloadLength);
  }
}

void test_s8_options_do_not_silently_fallback() {
  TEST_ASSERT_EQUAL_HEX8(0x02, kPreferS8);
  TEST_ASSERT_EQUAL_HEX8(0x04, kRequireS8);
  TEST_ASSERT_EQUAL_HEX8(0x04, codingOption(true, true));
  TEST_ASSERT_EQUAL_HEX8(0, codingOption(false, true));
  TEST_ASSERT_EQUAL_HEX8(0, codingOption(true, false));
  TEST_ASSERT_EQUAL_UINT16(400, kRadioIntervalUnits);
}

void test_high_power_keeps_radio_and_payload_contract() {
  TEST_ASSERT_EQUAL_INT8(20, kRadioTxPowerDbm);
  TEST_ASSERT_EQUAL_UINT16(400, kRadioIntervalUnits);
  TEST_ASSERT_EQUAL_UINT32(17, kPayloadLength);
  TEST_ASSERT_EQUAL_HEX8(0, codingOption(true, false));
}

void test_trickle_first_opportunity_is_in_second_half() {
  for (uint32_t randomValue = 0; randomValue < 8000; randomValue++) {
    const uint32_t offset = trickleTransmitOffset(8000, randomValue);
    TEST_ASSERT_TRUE(offset >= 4000);
    TEST_ASSERT_TRUE(offset < 8000);
  }
}

void test_trickle_rejects_17ms_burst_and_stale_zero_deadline() {
  TEST_ASSERT_FALSE(trickleTransmitDue(10017, 10000, 8000, 0));
  TEST_ASSERT_FALSE(trickleTransmitDue(14000, 10000, 8000, 15000));
  TEST_ASSERT_TRUE(trickleTransmitDue(15000, 10000, 8000, 15000));
  TEST_ASSERT_FALSE(trickleTransmitDue(18000, 10000, 8000, 15000));
}

void test_trickle_deadlines_survive_millis_wraparound() {
  const uint32_t started = UINT32_MAX - 2000;
  const uint32_t transmit = started + 4000;
  TEST_ASSERT_FALSE(trickleTransmitDue(started + 17, started, 8000, transmit));
  TEST_ASSERT_TRUE(trickleTransmitDue(transmit, started, 8000, transmit));
  TEST_ASSERT_FALSE(trickleTransmitDue(started + 8000, started, 8000, transmit));
}

void test_trickle_suppression_ablation_only_changes_decision() {
  TEST_ASSERT_TRUE(trickleAllowsTransmission(true, 0, 1));
  TEST_ASSERT_TRUE(trickleAllowsTransmission(false, 0, 1));
  TEST_ASSERT_FALSE(trickleAllowsTransmission(true, 1, 1));
  TEST_ASSERT_TRUE(trickleAllowsTransmission(false, 1, 1));
  TEST_ASSERT_FALSE(trickleAllowsTransmission(true, 20, 1));
  TEST_ASSERT_TRUE(trickleAllowsTransmission(false, 20, 1));
}

void test_trickle_expired_opportunity_is_missed_not_late_transmit() {
  TEST_ASSERT_FALSE(trickleOpportunityMissed(4409966, 4402060, 8000, false));
  TEST_ASSERT_FALSE(trickleOpportunityMissed(4410059, 4402060, 8000, false));
  TEST_ASSERT_TRUE(trickleOpportunityMissed(4410060, 4402060, 8000, false));
  TEST_ASSERT_TRUE(trickleOpportunityMissed(4410061, 4402060, 8000, false));
  TEST_ASSERT_FALSE(trickleOpportunityMissed(4410061, 4402060, 8000, true));
  const uint32_t start = UINT32_MAX - 2000;
  TEST_ASSERT_TRUE(trickleOpportunityMissed(start + 8000, start, 8000, false));
  TEST_ASSERT_FALSE(trickleTransmitDue(4410060, 4402060, 8000, 4409966));
}

int main(int, char**) {
  UNITY_BEGIN();
  RUN_TEST(test_trickle_expired_opportunity_is_missed_not_late_transmit);
  RUN_TEST(test_trickle_suppression_ablation_only_changes_decision);
  RUN_TEST(test_extended_manufacturer_boundary_for_sos_and_ack);
  RUN_TEST(test_s8_options_do_not_silently_fallback);
  RUN_TEST(test_high_power_keeps_radio_and_payload_contract);
  RUN_TEST(test_trickle_first_opportunity_is_in_second_half);
  RUN_TEST(test_trickle_rejects_17ms_burst_and_stale_zero_deadline);
  RUN_TEST(test_trickle_deadlines_survive_millis_wraparound);
  RUN_TEST(test_round_trip_signed_coordinates_and_hop);
  RUN_TEST(test_exact_epoch_boundaries);
  RUN_TEST(test_company_id_is_removed_from_manufacturer_data);
  RUN_TEST(test_research_protocol_contract_is_stable);
  RUN_TEST(test_cross_node_identities_use_millisecond_timestamp);
  RUN_TEST(test_only_parallel_relay_counts_trickle_consistency);
  RUN_TEST(test_observations_use_per_advertiser_inactivity_gap);
  RUN_TEST(test_observation_tracker_is_bounded_and_evicts_oldest);
  return UNITY_END();
}
