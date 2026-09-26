#include <unity.h>

#include <cmath>

#include "Protocol.h"

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

int main(int, char**) {
  UNITY_BEGIN();
  RUN_TEST(test_round_trip_signed_coordinates_and_hop);
  RUN_TEST(test_exact_epoch_boundaries);
  RUN_TEST(test_company_id_is_removed_from_manufacturer_data);
  RUN_TEST(test_research_protocol_contract_is_stable);
  RUN_TEST(test_only_parallel_relay_counts_trickle_consistency);
  RUN_TEST(test_observations_use_per_advertiser_inactivity_gap);
  RUN_TEST(test_observation_tracker_is_bounded_and_evicts_oldest);
  return UNITY_END();
}
