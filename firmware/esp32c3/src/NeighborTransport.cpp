#include "NeighborTransport.h"
#include <algorithm>
#include <sstream>
#include <cstring>

namespace resqmesh {
namespace {
uint32_t u32(const uint8_t* b) { return uint32_t(b[0]) << 24 | uint32_t(b[1]) << 16 | uint32_t(b[2]) << 8 | b[3]; }
void put32(std::vector<uint8_t>& b, size_t o, uint32_t v) { for (int i=3; i>=0; --i) { b[o+i] = v & 255; v >>= 8; } }
bool stateValid(const InventoryState& s) { return epochValid(s.seconds) && (s.flags & 63) <= 2 && !((s.flags & 128) && (s.flags & 63) == 1); }
int priority(uint8_t flags) { const auto s=flags & 63; return s==1 ? 0 : s==0 ? 1 : 2; }
}
InventoryState inventoryState(const Packet& p) { return {p.senderCrc, p.timestampSeconds, uint8_t(uint8_t(p.status) | (p.kind==PacketKind::Ack ? 128 : 0) | (p.fromServer ? 64 : 0))}; }
bool encodeFrame(const NeighborFrame& f, std::vector<uint8_t>& b) {
  if (!f.transmitter || !f.boot || !f.sequence || !f.scope || f.count>kInventoryCapacity || (!f.status && (f.count || !f.complete))) return false;
  b.assign(kFrameHeader + (f.status ? f.count * 8 : kPayloadLength), 0);
  b[0]=0x52; b[1]=0x4e; b[2]=1; b[3]=f.status ? 1 : 0;
  put32(b,4,f.transmitter); put32(b,8,f.boot); put32(b,12,f.sequence); put32(b,16,f.scope);
  b[20]=f.count; b[21]=f.complete ? 1 : 0;
  if (!f.status) { std::array<uint8_t,kPayloadLength> inner{}; if (!encode(f.packet,inner)) return false; std::copy(inner.begin(),inner.end(),b.begin()+kFrameHeader); }
  else for (size_t i=0; i<f.count; ++i) {
    const auto& s=f.inventory[i]; if (!stateValid(s)) return false;
    const size_t o=kFrameHeader+i*8; const auto seconds=s.seconds-kEpochSeconds;
    put32(b,o,s.sender); b[o+4]=seconds>>16; b[o+5]=(seconds>>8)&255; b[o+6]=seconds&255; b[o+7]=s.flags;
  }
  return true;
}
bool decodeFrame(const uint8_t* b, size_t n, NeighborFrame& f) {
  if (!b || n<kFrameHeader || b[0]!=0x52 || b[1]!=0x4e || b[2]!=1 || b[3]>1 || b[20]>kInventoryCapacity || b[21]>1) return false;
  f=NeighborFrame{}; f.status=b[3]==1; f.transmitter=u32(b+4); f.boot=u32(b+8); f.sequence=u32(b+12); f.scope=u32(b+16); f.count=b[20]; f.complete=b[21]==1;
  if (!f.transmitter || !f.boot || !f.sequence || !f.scope || n!=kFrameHeader+(f.status ? f.count*8 : kPayloadLength)) return false;
  if (!f.status) return !f.count && f.complete && decode(b+kFrameHeader,kPayloadLength,f.packet);
  for (size_t i=0; i<f.count; ++i) { const size_t o=kFrameHeader+i*8; auto& s=f.inventory[i]; s={u32(b+o),kEpochSeconds+(uint32_t(b[o+4])<<16 | uint32_t(b[o+5])<<8 | b[o+6]),b[o+7]}; if (!stateValid(s)) return false; }
  return true;
}
std::string burstIdentity(const NeighborFrame& f) { return std::to_string(f.scope)+":"+std::to_string(f.transmitter)+":"+std::to_string(f.boot)+":"+std::to_string(f.sequence); }
bool advanceBurstIdentity(uint32_t& incarnation,uint32_t& sequence) {
  if(!incarnation || (incarnation==UINT32_MAX && sequence==UINT32_MAX)) return false;
  if(sequence==UINT32_MAX) { incarnation++;sequence=1; }
  else sequence++;
  return true;
}
bool frameTimeValid(const NeighborFrame& f,uint64_t nowSeconds,uint32_t skewSeconds) {
  if(!epochValid(nowSeconds)) return false;
  if(!f.status) return f.packet.timestampSeconds<=nowSeconds+skewSeconds;
  for(size_t i=0;i<f.count;++i) if(f.inventory[i].seconds>nowSeconds+skewSeconds) return false;
  return true;
}
bool NeighborParameters::valid() const { return statusPeriod>=1000 && statusBurst>=250 && statusBurst<=2000 && freshness>=statusPeriod*2 && resetCooldown>=1000 && capacity>=5 && capacity<=64; }
void NeighborController::reset(uint32_t scope) { scope_=scope; entries_.clear(); repaired_=false; repairPending_.clear(); }
bool NeighborController::known(uint32_t transmitter) const {
  return std::any_of(entries_.begin(),entries_.end(),[&](const Entry& e){return e.frame.transmitter==transmitter;});
}
std::vector<NeighborFrame> NeighborController::newlyExpired(uint32_t now) {
  std::vector<NeighborFrame> result;
  for(auto& e:entries_) if(!e.expired && int32_t(now-e.at)>=0 && now-e.at>parameters.freshness) {
    e.expired=true;result.push_back(e.frame);
  }
  return result;
}
bool NeighborController::observe(const NeighborFrame& f, uint32_t at, uint32_t now) {
  if (f.scope!=scope_ || int32_t(now-at)<0 || now-at>parameters.freshness) return false;
  auto it=std::find_if(entries_.begin(),entries_.end(),[&](const Entry& e){return e.frame.transmitter==f.transmitter;});
  bool needsReview=false;
  if (it!=entries_.end()) {
    if (int32_t(at-it->at)<0 || f.boot<it->frame.boot || (it->frame.boot==f.boot && f.sequence<=it->frame.sequence)) return false;
    bool changed=it->frame.boot!=f.boot || it->frame.status!=f.status || it->frame.complete!=f.complete || it->frame.count!=f.count;
    if (!f.status && !changed) changed=stateIdentity(f.packet)!=stateIdentity(it->frame.packet);
    if (f.status && !changed) for (size_t i=0;i<f.count;++i) { const auto& a=f.inventory[i]; const auto& b=it->frame.inventory[i]; changed=changed || a.sender!=b.sender || a.seconds!=b.seconds || a.flags!=b.flags; }
    needsReview=changed || now-it->at>parameters.freshness;
    *it={f,at};
  } else { if (entries_.size()>=parameters.capacity) return false; entries_.push_back({f,at}); needsReview=true; }
  if(needsReview && std::find(repairPending_.begin(),repairPending_.end(),f.transmitter)==repairPending_.end()) repairPending_.push_back(f.transmitter);
  return true;
}
Knowledge NeighborController::knowledge(uint32_t id, const Packet& local, uint32_t now) const {
  const auto it=std::find_if(entries_.begin(),entries_.end(),[&](const Entry& e){return e.frame.transmitter==id;});
  if (it==entries_.end() || int32_t(now-it->at)<0 || now-it->at>parameters.freshness) return Knowledge::Unknown;
  const auto& f=it->frame;
  if(f.status && !f.complete) return Knowledge::Unknown;
  const auto own=inventoryState(local);
  const size_t count=f.status ? f.count : 1;
  for (size_t i=0;i<count;++i) { const auto s=f.status ? f.inventory[i] : inventoryState(f.packet); if (s.sender==own.sender && (s.seconds>own.seconds || (s.seconds==own.seconds && (s.flags==own.flags || (s.flags & 128) || priority(s.flags)>priority(own.flags))))) return Knowledge::Have; }
  return f.status && f.complete ? Knowledge::Missing : Knowledge::Unknown;
}
const char* NeighborController::decision(const Packet& p,uint32_t now,bool first) const {
  if (first) return "INITIAL_FORWARD_PENDING";
  bool unknown=entries_.empty();
  for (const auto& e:entries_) { const auto k=knowledge(e.frame.transmitter,p,now); if(k==Knowledge::Missing)return "FRESH_MISSING"; unknown=unknown || k==Knowledge::Unknown; }
  return unknown ? "UNKNOWN_OR_NO_NEIGHBORS" : "ALL_OBSERVED_HAVE";
}
bool NeighborController::repairAllowed(const Packet& p,uint32_t now,uint32_t interval,uint32_t imin) {
  if (repairPending_.empty() || interval<=imin || (repaired_ && now-lastRepair_<parameters.resetCooldown)) return false;
  bool need=false;
  for(const auto id:repairPending_) need=need || knowledge(id,p,now)!=Knowledge::Have;
  repairPending_.clear();
  if (!need) return false;
  repaired_=true; lastRepair_=now; return true;
}
KnowledgeCounts NeighborController::counts(const Packet& local,uint32_t now) const {
  KnowledgeCounts result;
  for(const auto& e:entries_) {
    switch(knowledge(e.frame.transmitter,local,now)) {
      case Knowledge::Have: result.have++;break;
      case Knowledge::Missing: result.missing++;break;
      default: result.unknown++;break;
    }
    result.maxAge=std::max(result.maxAge,now-e.at);
  }
  return result;
}
}
