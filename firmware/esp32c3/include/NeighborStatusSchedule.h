#pragma once
#include "NeighborTransport.h"
#include <algorithm>
#include <set>

namespace resqmesh {
// Local announcement coverage is not evidence of remote reception.
class NeighborStatusSchedule {
 public:
  NeighborParameters parameters;
  uint32_t nextAt = 0;
  const char* reason = "DISCOVERY";
  std::vector<std::string> inventory;
  void start(uint32_t now, uint32_t jitter) {
    inventory.clear(); forwarded_.clear(); announcement_=stable_=discovered_=false;
    maintenance_=parameters.statusMinPeriod; emptyRetry_=parameters.emptyRetryMin;
    reason="DISCOVERY"; nextAt=now+1000+jitter;
  }
  bool syncInventory(std::vector<std::string> states,uint32_t now,uint32_t jitter) {
    std::sort(states.begin(),states.end()); if(states==inventory) return false;
    const bool pending=announcement_;
    inventory=states;forwarded_.clear();stable_=false;
    maintenance_=parameters.statusMinPeriod;emptyRetry_=parameters.emptyRetryMin;
    announcement_=!states.empty();reason=states.empty() || !discovered_ ? "DISCOVERY" : "STATE_CHANGED";
    const uint32_t changedAt=now+(states.empty() ? 1000+jitter : parameters.dataGrace);
    if((discovered_ && !pending) || int32_t(changedAt-nextAt)<0) nextAt=changedAt;return true;
  }
  bool firstForwardComplete() const {
    return !inventory.empty() && std::all_of(inventory.begin(),inventory.end(),[&](const std::string& s){return forwarded_.count(s)>0;});
  }
  void peerChanged(uint32_t now,uint32_t jitter) {
    stable_=false;maintenance_=parameters.statusMinPeriod;
    const uint32_t candidate=now+maintenance_+jitter;
    if(!inventory.empty() && !announcement_ && int32_t(candidate-nextAt)<0) nextAt=candidate;
  }
  void stable(uint32_t now,bool allHave,uint32_t jitter) {
    const bool value=firstForwardComplete() && allHave;
    if(value && !stable_) { maintenance_=parameters.statusPeriod; if(!announcement_) nextAt=now+maintenance_+jitter; }
    if(!value && stable_) {
      maintenance_=parameters.statusMinPeriod;
      const uint32_t candidate=now+maintenance_+jitter;
      if(!announcement_ && int32_t(candidate-nextAt)<0) nextAt=candidate;
    }
    stable_=value;
  }
  bool dataSucceeded(const std::string& state,uint32_t now,bool allHave,uint32_t jitter) {
    if(std::find(inventory.begin(),inventory.end(),state)==inventory.end()) return false;
    forwarded_.insert(state);if(!firstForwardComplete()) return false;
    const bool coalesced=announcement_;announcement_=false;discovered_=true;stable(now,allHave,jitter);
    reason="HEARTBEAT";nextAt=now+maintenance_+jitter;return coalesced;
  }
  void statusSucceeded(std::vector<std::string> sent,uint32_t now,bool allHave,uint32_t jitter) {
    std::sort(sent.begin(),sent.end());if(sent!=inventory) return;
    discovered_=true;
    announcement_=false;stable(now,allHave,jitter);
    if(inventory.empty()) { reason="INVENTORY_EMPTY";nextAt=now+emptyRetry_+jitter;emptyRetry_=std::min(emptyRetry_*2,parameters.emptyRetryMax); }
    else { reason="HEARTBEAT";nextAt=now+maintenance_+jitter;maintenance_=std::min(maintenance_*2,parameters.statusPeriod); }
  }
  void failed(uint32_t now,uint32_t jitter) { reason="NATIVE_RETRY";nextAt=now+1000+jitter; }
 private:
  std::set<std::string> forwarded_;
  bool announcement_=false,stable_=false,discovered_=false;
  uint32_t maintenance_=15000,emptyRetry_=4000;
};
}
