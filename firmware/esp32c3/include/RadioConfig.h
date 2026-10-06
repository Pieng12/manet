#pragma once
#include <array>
#include <cstdint>
#include "Protocol.h"

namespace resqmesh {
constexpr uint16_t kRadioIntervalUnits = 400; // 250 ms, not scheduler/burst time.
constexpr int8_t kRadioTxPowerDbm = 20; // Request ESP32-C3 maximum; log controller-selected power.
// Bluetooth 5.4 LE Set Extended Advertising Parameters V2 PHY options.
constexpr uint8_t kPreferS8 = 0x02;
constexpr uint8_t kRequireS8 = 0x04;
constexpr uint8_t codingOption(bool required, bool v2Supported) {
  return required && v2Supported ? kRequireS8 : 0;
}
using ManufacturerPayload = std::array<uint8_t, kPayloadLength + 2>;
inline ManufacturerPayload manufacturerPayload(
    const std::array<uint8_t, kPayloadLength>& payload) {
  ManufacturerPayload result{};
  result[0] = 0xff;
  result[1] = 0xff;
  for (size_t i = 0; i < payload.size(); ++i) result[i + 2] = payload[i];
  return result;
}
}
