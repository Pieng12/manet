#include <NimBLEDevice.h>
#include <algorithm>
#include "nimble/nimble/host/src/ble_hs_hci_priv.h"
#include "nimble/nimble/host/include/host/ble_hs_mbuf.h"
#include "CodedRadio.h"

namespace resqmesh {
namespace {
constexpr uint8_t kInstance = 0;
int onGapEvent(ble_gap_event*, void*) { return 0; }
}

bool CodedRadio::configure(bool requireS8) {
  if (configured_) {
    if (!stop()) return false;
    lastRc_ = ble_gap_ext_adv_remove(kInstance);
    if (lastRc_ != 0) return false;
  }
  configured_ = false;
  requireS8_ = requireS8;
  // Same supported-command bit checked by NimBLE 2.5.1 ble_gap.c.
  v2Supported_ = (ble_hs_hci_get_hci_supported_cmd().commands[46] & 0x04) != 0;
  if (requireS8 && !v2Supported_) {
    lastRc_ = BLE_HS_ENOTSUP;
    return false;
  }
  ble_gap_ext_adv_params params{};
  lastRc_ = ble_hs_id_infer_auto(0, &params.own_addr_type);
  if (lastRc_ != 0) return false;
  params.itvl_min = params.itvl_max = kRadioIntervalUnits;
  params.channel_map = 7;
  params.primary_phy = params.secondary_phy = BLE_HCI_LE_PHY_CODED;
  params.primary_phy_opt = params.secondary_phy_opt = codingOption(requireS8, v2Supported_);
  params.tx_power = kRadioTxPowerDbm;
  lastRc_ = ble_gap_ext_adv_configure(kInstance, &params, &actualPower_, onGapEvent, nullptr);
  configured_ = lastRc_ == 0;
  return configured_;
}

bool CodedRadio::start(const std::array<uint8_t, kPayloadLength>& payload) {
  if (!configured_) return false;
  if (!stop()) return false;
  const auto manufacturer = manufacturerPayload(payload);
  // Manufacturer AD structure: length, type, company ID exactly once, payload.
  std::array<uint8_t, kPayloadLength + 4> data{};
  data[0] = manufacturer.size() + 1;
  data[1] = 0xff;
  std::copy(manufacturer.begin(), manufacturer.end(), data.begin() + 2);
  auto* buffer = ble_hs_mbuf_from_flat(data.data(), data.size());
  if (buffer == nullptr) { lastRc_ = BLE_HS_ENOMEM; return false; }
  // GAP takes ownership of buffer on both success and failure.
  lastRc_ = ble_gap_ext_adv_set_data(kInstance, buffer);
  if (lastRc_ != 0) return false;
  lastRc_ = ble_gap_ext_adv_start(kInstance, 0, 0);
  return lastRc_ == 0; // Controller command acknowledged, not just a capability flag.
}

bool CodedRadio::stop() {
  if (!configured_) return true;
  lastRc_ = ble_gap_ext_adv_stop(kInstance);
  if (lastRc_ == BLE_HS_EALREADY) lastRc_ = 0;
  return lastRc_ == 0;
}

void CodedRadio::telemetry(JsonObject object) const {
  object["requested_mode"] = requireS8_ ? "coded_s8_required" : "coded";
  if (configured_) object["configured_mode"] = requireS8_ ? "coded_s8_required" : "coded";
  else object["configured_mode"] = nullptr;
  object["ready"] = configured_;
  object["primary_phy"] = "coded";
  object["secondary_phy"] = "coded";
  object["scan_phy"] = "coded";
  object["legacy"] = false;
  object["connectable"] = false;
  object["scannable"] = false;
  object["coding_requested"] = requireS8_ ? "require_s8" : "unspecified";
  object["coding_selection_support"] = v2Supported_ ? "supported" : "unsupported";
  object["s8_requirement_accepted"] = requireS8_ && configured_;
  object["on_air_coding_verified"] = false;
  object["tx_power_requested_dbm"] = kRadioTxPowerDbm;
  if (configured_) object["tx_power_actual_dbm"] = actualPower_;
  else object["tx_power_actual_dbm"] = nullptr;
  object["advertising_interval_units"] = kRadioIntervalUnits;
  object["advertising_interval_ms"] = 250;
  object["last_error"] = lastRc_;
}
}
