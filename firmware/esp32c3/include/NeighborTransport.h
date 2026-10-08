#pragma once
#include "Protocol.h"
#include <array>
#include <vector>

namespace resqmesh {
constexpr size_t kFrameHeader = 22;
constexpr size_t kInventoryCapacity = 8;
constexpr size_t kFrameMax = 86;
constexpr const char* kNeighborProtocol = "resqmesh-neighbor-v1";
struct InventoryState {
  uint32_t sender = 0, seconds = 0;
  uint8_t flags = 1;
};
struct NeighborFrame {
  bool status = false, complete = true;
  uint32_t transmitter = 0, boot = 0, sequence = 0, scope = 0;
  Packet packet;
  uint8_t count = 0;
  std::array<InventoryState, kInventoryCapacity> inventory{};
};
bool encodeFrame(const NeighborFrame& frame, std::vector<uint8_t>& bytes);
bool decodeFrame(const uint8_t* bytes, size_t length, NeighborFrame& frame);
InventoryState inventoryState(const Packet& packet);
std::string burstIdentity(const NeighborFrame& frame);
bool advanceBurstIdentity(uint32_t& incarnation, uint32_t& sequence);
bool frameTimeValid(const NeighborFrame& frame, uint64_t nowSeconds, uint32_t skewSeconds=300);

enum class Knowledge { Have, Missing, Unknown };
struct KnowledgeCounts { size_t have=0, missing=0, unknown=0; uint32_t maxAge=0; };
struct NeighborParameters {
  uint32_t statusPeriod = 12000, statusBurst = 500, freshness = 45000;
  uint32_t jitter = 1500, resetCooldown = 8000;
  size_t capacity = 16;
  std::string policy = "periodic_v1";
  uint32_t statusMinPeriod = 15000, emptyRetryMin = 4000, emptyRetryMax = 32000, dataGrace = 10000;
  bool adaptive() const { return policy == "adaptive_v2"; }
  bool valid() const;
};
class NeighborController {
 public:
  NeighborParameters parameters;
  bool peerChanged = false;
  void reset(uint32_t scope);
  bool observe(const NeighborFrame& frame, uint32_t receivedAt, uint32_t now);
  Knowledge knowledge(uint32_t transmitter, const Packet& local, uint32_t now) const;
  const char* decision(const Packet& local, uint32_t now, bool firstPending) const;
  bool repairAllowed(const Packet& local, uint32_t now, uint32_t interval, uint32_t imin);
  void requestMissingPeer(uint32_t transmitter, const Packet& local, uint32_t now);
  bool known(uint32_t transmitter) const;
  std::vector<NeighborFrame> newlyExpired(uint32_t now);
  KnowledgeCounts counts(const Packet& local,uint32_t now) const;
  std::vector<uint32_t> observedTransmitters() const;
  bool takeRepairDeferred();
 private:
  struct Entry { NeighborFrame frame; uint32_t at; bool expired=false; };
  std::vector<Entry> entries_;
  uint32_t scope_ = 0, lastRepair_ = 0;
  bool repaired_ = false;
  std::vector<uint32_t> repairPending_;
  bool deferred_ = false, cooldownReported_ = false;
};
}
