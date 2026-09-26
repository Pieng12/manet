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

int main(int, char**) {
  UNITY_BEGIN();
  RUN_TEST(test_round_trip_signed_coordinates_and_hop);
  RUN_TEST(test_exact_epoch_boundaries);
  RUN_TEST(test_company_id_is_removed_from_manufacturer_data);
  RUN_TEST(test_research_protocol_contract_is_stable);
  RUN_TEST(test_only_parallel_relay_counts_trickle_consistency);
  return UNITY_END();
}
