#pragma once
#include <ArduinoJson.h>
#include "RadioConfig.h"

namespace resqmesh {
// Owns GAP advertising instance 0. Never use NimBLEDevice::getAdvertising().
class CodedRadio {
 public:
  bool configure(bool requireS8);
  bool start(const std::array<uint8_t, kPayloadLength>& payload);
  bool start(const uint8_t* payload, size_t length);
  bool stop();
  bool ready() const { return configured_; }
  void telemetry(JsonObject object) const;
 private:
  bool configured_ = false;
  bool requireS8_ = false;
  bool v2Supported_ = false;
  int lastRc_ = 0;
  int8_t actualPower_ = 0;
};
}
