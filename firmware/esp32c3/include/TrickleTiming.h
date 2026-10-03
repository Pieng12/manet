#pragma once

#include <cstdint>

namespace resqmesh {

inline bool trickleAllowsTransmission(bool suppressionEnabled, uint32_t c,
                                      uint32_t k) {
  return !suppressionEnabled || c < k;
}

inline bool deadlineReached(uint32_t now, uint32_t deadline) {
  return static_cast<int32_t>(now - deadline) >= 0;
}

inline uint32_t trickleTransmitOffset(uint32_t intervalMs, uint32_t randomValue) {
  const uint32_t half = intervalMs / 2;
  return half + randomValue % (intervalMs - half);
}

inline bool trickleTransmitDue(uint32_t now, uint32_t startedAt,
                               uint32_t intervalMs, uint32_t transmitAt) {
  const uint32_t age = now - startedAt;
  return age >= intervalMs / 2 && age < intervalMs &&
         deadlineReached(now, transmitAt);
}

inline bool trickleOpportunityMissed(uint32_t now, uint32_t startedAt,
                                     uint32_t intervalMs, bool evaluated) {
  return !evaluated && now - startedAt >= intervalMs;
}

}  // namespace resqmesh
