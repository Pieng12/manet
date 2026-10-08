#pragma once
#include "NeighborTransport.h"
#include "TrickleTiming.h"
#include <algorithm>
#include <functional>
#include <map>
#include <string>

namespace resqmesh {
constexpr const char* kMplSemantics="resqmesh-trickle-mpl-v1";
struct MplParameters {
  std::map<std::string,uint32_t> values{
    {"mpl_data_imin_ms",8000},{"mpl_data_imax_ms",256000},{"mpl_data_k",1},{"mpl_data_expirations",5},
    {"mpl_control_imin_ms",4000},{"mpl_control_imax_ms",32000},{"mpl_control_k",1},{"mpl_control_expirations",4},
    {"mpl_repair_cooldown_ms",8000},{"mpl_repair_budget",2},{"mpl_repair_expiry_ms",60000},
    {"mpl_bootstrap_opportunities",2},{"mpl_retry_ms",1000},{"mpl_retry_limit",3},
    {"mpl_probe_interval_ms",60000},{"mpl_probe_limit",0},{"mpl_freshness_ms",150000},{"mpl_discovery_jitter_ms",1500}};
  uint32_t get(const std::string& key) const {return values.at("mpl_"+key);}
  bool valid() const {
    for(const auto& v:values) if(v.second>0x1fffffff) return false;
    for(const std::string kind:{"data","control"}) {
      const auto a=get(kind+"_imin_ms"),b=get(kind+"_imax_ms");
      if(a<2000 || b<a || b%a || ((b/a)&(b/a-1)) || !get(kind+"_k") ||
        !get(kind+"_expirations") || get(kind+"_expirations")>32) return false;
    }
    return get("repair_cooldown_ms")>=get("data_imin_ms") && get("repair_expiry_ms")>=get("repair_cooldown_ms") &&
      get("repair_budget")>0 && get("repair_budget")<=8 && get("bootstrap_opportunities")<=8 &&
      get("retry_limit")>0 && get("retry_limit")<=8 && get("retry_ms")>=250 &&
      get("freshness_ms")>=get("control_imin_ms") && get("probe_limit")<=8 && get("probe_interval_ms")>=get("control_imax_ms");
  }
};
struct MplEvent {
  std::string event,kind,key,reason;
  uint32_t now=0,interval=0,start=0,transmit=0,end=0,c=0,k=0,e=0,limit=0,generation=0;
  uint32_t peer=0,peerBoot=0,budget=0,budgetLimit=0,episodeUntil=0,physical=0;
  bool active=false,overrideUsed=false,retained=false;
};
using MplEmit=std::function<void(const MplEvent&)>;
using MplRandom=std::function<uint32_t(uint32_t)>;
class MplTimer {
 public:
  std::string kind,key,reason="NEW_STATE";
  const MplParameters* parameters=nullptr;
  MplRandom random;
  MplEmit emit;
  bool active=false,evaluated=false,pending=false;
  uint32_t interval=0,start=0,transmit=0,end=0,c=0,e=0,generation=0,retryAt=0,attempts=0;
  uint32_t k() const {return parameters->get(kind+"_k");}
  uint32_t nextAt() const {return pending ? retryAt : evaluated ? end : transmit;}
  MplEvent fields(uint32_t now) const {
    MplEvent v;v.kind=kind;v.key=key;v.reason=reason;v.now=now;v.interval=interval;
    v.start=start;v.transmit=transmit;v.end=end;v.c=c;v.k=k();v.e=e;
    v.limit=parameters->get(kind+"_expirations");v.generation=generation;v.active=active;return v;
  }
  void log(const char* event,uint32_t now,const char* cause=nullptr,bool overrideUsed=false) const {
    if(!emit) return;auto v=fields(now);v.event=std::string("MPL_")+event;
    if(cause) v.reason=cause;v.overrideUsed=overrideUsed;v.retained=v.event=="MPL_TIMER_STOPPED";emit(v);
  }
  void begin(uint32_t now,uint32_t size) {
    start=now;interval=size;end=now+size;transmit=now+size/2+random(size-size/2);
    c=0;evaluated=false;pending=false;attempts=0;generation++;log("INTERVAL_STARTED",now);
  }
  void advance(uint32_t now) {
    while(active && deadlineReached(now,end)) {
      if(!evaluated || pending) log("TX_MISSED",now,"SCHEDULER_LATE");
      ++e;log("INTERVAL_ENDED",end);
      if(e>=parameters->get(kind+"_expirations")) {active=false;pending=false;log("TIMER_STOPPED",end,"EXPIRATION_LIMIT");break;}
      begin(end,std::min(interval*2,parameters->get(kind+"_imax_ms")));
    }
  }
  bool reset(uint32_t now,const char* cause,bool external=false) {
    advance(now);reason=cause;
    if(active && interval==parameters->get(kind+"_imin_ms") && !external) {
      e=0;log("RESET_DEFERRED",now,"ALREADY_AT_IMIN");return false;
    }
    active=true;e=0;begin(now,parameters->get(kind+"_imin_ms"));log("TIMER_RESTARTED",now);return true;
  }
  void consistent(uint32_t physical,uint32_t now) {
    advance(now);
    if(!active || !deadlineReached(physical,start) || deadlineReached(physical,end)) return;
    ++c;auto v=fields(now);v.event="MPL_C_INCREMENT";v.physical=physical;if(emit) emit(v);
  }
  bool opportunity(uint32_t now,bool protect=false,bool slot=true) {
    advance(now);
    if(!active || !deadlineReached(now,nextAt()) || (evaluated && !pending)) return false;
    if(!evaluated) {
      evaluated=true;log("TX_OPPORTUNITY",now,nullptr,protect);
      if(c>=k() && !protect) {log("TX_SUPPRESSED",now);return false;}
      pending=true;retryAt=now;log("TX_ALLOWED",now,nullptr,protect);
    }
    if(!slot) {retryAt=now+100;log("TX_DEFERRED",now,"DATA_SLOT_PROTECTED");return false;}
    return !deadlineReached(now,end);
  }
  bool nativeResult(uint32_t token,uint32_t now,bool success) {
    if(token!=generation || !active || !pending || deadlineReached(now,end)) {
      log("CALLBACK_IGNORED",now);return false;
    }
    log(success ? "NATIVE_STARTED" : "NATIVE_FAILED",now);
    if(success) {pending=false;return true;}
    if(++attempts>=parameters->get("retry_limit")) {pending=false;log("TX_MISSED",now,"NATIVE_RETRY_EXHAUSTED");}
    else retryAt=now+parameters->get("retry_ms");return false;
  }
};
class MplScheduler {
 public:
  MplParameters parameters;
  MplRandom random=[](uint32_t){return 0;};
  MplEmit emit;
  MplTimer control;
  NeighborController neighbors;
  std::map<std::string,MplTimer> data;
  std::map<std::string,Packet> buffer;
  uint32_t scope=0,bootstrap=0,inventoryGeneration=0,probes=0,probeAt=0,lastNow=0;
  bool probeScheduled=false;
  struct Repair {std::string state,inventorySignature;uint32_t peer=0,boot=0,until=0,used=0,next=0,resets=0;bool scheduled=false,expiryReported=false;};
  std::map<std::string,Repair> repairs;
  struct Demand {uint32_t peer=0,boot=0,until=0,next=0,resets=0;std::string signature;std::vector<InventoryState> offered;bool scheduled=false;};
  std::map<uint32_t,Demand> demands;
  bool deficit() const {
    for(const auto& entry:demands) if(!deadlineReached(lastNow,entry.second.until) && neighbors.fresh(entry.first,lastNow)) for(const auto& p:entry.second.offered) {
      bool covered=false;for(const auto& local:buffer) covered=covered || covers(inventoryState(local.second),p);
      if(!covered) return true;
    }return false;
  }
  MplTimer timer(const std::string& kind,const std::string& key) {
    MplTimer v;v.kind=kind;v.key=key;v.parameters=&parameters;v.random=random;v.emit=emit;return v;
  }
  void initialize(uint32_t domain,uint32_t now) {
    scope=domain;data.clear();buffer.clear();repairs.clear();demands.clear();probes=0;probeScheduled=false;inventoryGeneration=0;
    neighbors.parameters.freshness=parameters.get("freshness_ms");neighbors.reset(scope);
    control=timer("control","scope:"+std::to_string(scope));discover(now);
  }
  void discover(uint32_t now) {
    bootstrap=parameters.get("bootstrap_opportunities");
    control.reset(now+random(parameters.get("discovery_jitter_ms")+1),"BLE_BOOTSTRAP",true);
    control.log("DISCOVERY",now);
  }
  void sync(const std::vector<Packet>& inventory,uint32_t now) {
    std::map<std::string,Packet> next;
    for(const auto& p:inventory) next.emplace(stateIdentity(p),p);
    bool changed=next.size()!=buffer.size();
    for(auto it=data.begin();it!=data.end();) {if(!next.count(it->first)) it=data.erase(it);else ++it;}
    for(auto it=repairs.begin();it!=repairs.end();) {if(!next.count(it->second.state)) it=repairs.erase(it);else ++it;}
    for(const auto& entry:next) if(!data.count(entry.first)) {
      changed=true;auto v=timer("data",entry.first);v.reset(now,"BUFFER_INSERT");data.emplace(entry.first,v);
    }
    buffer=next;
    if(changed) {inventoryGeneration++;control.reset(now,"INVENTORY_CHANGED");}tick(now);
  }
  void repairEvent(const char* event,const Repair& r,uint32_t now) {
    if(!emit) return;auto v=data.at(r.state).fields(now);v.event=event;v.peer=r.peer;v.peerBoot=r.boot;
    v.budget=r.used;v.budgetLimit=parameters.get("repair_budget");v.episodeUntil=r.until;emit(v);
  }
  void tick(uint32_t now) {
    lastNow=now;
    control.advance(now);for(auto& entry:data) entry.second.advance(now);
    for(const auto& expired:neighbors.newlyExpired(now)) {
      if(emit) {MplEvent v;v.event="NEIGHBOR_STATUS_EXPIRED";v.now=now;v.peer=expired.transmitter;v.peerBoot=expired.boot;emit(v);}
    }
    for(auto& entry:repairs) {
      auto& r=entry.second;
      if(deadlineReached(now,r.until) && !r.expiryReported) {r.expiryReported=true;repairEvent("MPL_REPAIR_EXPIRED",r,now);}
      if(deadlineReached(now,r.until) || r.used>=parameters.get("repair_budget") || r.resets>=parameters.get("repair_budget") || !buffer.count(r.state) ||
        neighbors.knowledge(r.peer,buffer.at(r.state),now)!=Knowledge::Missing) continue;
      if(!r.scheduled || deadlineReached(now,r.next)) {
        r.resets++;
        data.at(r.state).reset(now,"MISSING_PEER");r.next=now+parameters.get("repair_cooldown_ms");r.scheduled=true;
        repairEvent("MPL_REPAIR_RESET",r,now);
        repairEvent("MPL_REPAIR_DEFERRED",r,now);
      }
    }
    for(auto& entry:demands) {
      auto& d=entry.second;
      if(deadlineReached(now,d.until) || d.resets>=parameters.get("repair_budget") || !neighbors.fresh(d.peer,now)) continue;
      if(!d.scheduled || deadlineReached(now,d.next)) {
        d.resets++;control.reset(now,"INVENTORY_MISMATCH");d.next=now+parameters.get("repair_cooldown_ms");d.scheduled=true;
      }
    }
    if(!control.active && probes<parameters.get("probe_limit")) {
      if(!probeScheduled) {probeAt=now+parameters.get("probe_interval_ms");probeScheduled=true;}
      if(deadlineReached(now,probeAt)) {++probes;probeScheduled=false;discover(now);}
    }
  }
  static bool covers(const InventoryState& a,const InventoryState& b) {
    if(a.sender!=b.sender) return false;if(a.seconds!=b.seconds) return a.seconds>b.seconds;
    auto priority=[](uint8_t s){return s==1 ? 0 : s==0 ? 1 : 2;};
    return a.flags==b.flags || (a.flags&128) || (!(b.flags&128) && priority(a.flags&63)>priority(b.flags&63));
  }
  bool receive(const NeighborFrame& f,uint32_t physical,uint32_t now,bool newState=false) {
    if(f.status) for(size_t i=0;i<f.count;i++) for(size_t j=i+1;j<f.count;j++)
      if(f.inventory[i].sender==f.inventory[j].sender) {control.log("CONTROL_CLASSIFIED",now,"AMBIGUOUS_UNKNOWN");return false;}
    if(!neighbors.observe(f,physical,now)) return false;
    auto demand=demands.find(f.transmitter);if(demand!=demands.end() && demand->second.boot!=f.boot) demands.erase(demand);
    if(emit) {auto v=control.fields(now);v.event="MPL_RX_CLASSIFIED";v.peer=f.transmitter;v.peerBoot=f.boot;v.physical=physical;emit(v);}
    for(auto it=repairs.begin();it!=repairs.end();) {
      const auto& r=it->second;
      if(r.peer==f.transmitter && (r.boot!=f.boot || (buffer.count(r.state) && neighbors.knowledge(r.peer,buffer.at(r.state),now)==Knowledge::Have))) it=repairs.erase(it);
      else ++it;
    }
    if(!f.status) {auto it=data.find(stateIdentity(f.packet));if(it!=data.end() && !newState) it->second.consistent(physical,now);return true;}
    if(!f.complete || buffer.size()>kInventoryCapacity) {control.log("CONTROL_CLASSIFIED",now,"PARTIAL_UNKNOWN");return true;}
    std::vector<std::string> missing;std::vector<InventoryState> offered;
    for(const auto& local:buffer) if(neighbors.knowledge(f.transmitter,local.second,now)==Knowledge::Missing) missing.push_back(local.first);
    for(size_t i=0;i<f.count;i++) {
      bool covered=false;for(const auto& local:buffer) covered=covered || covers(inventoryState(local.second),f.inventory[i]);
      if(!covered) offered.push_back(f.inventory[i]);
    }
    if(missing.empty() && offered.empty()) {demands.erase(f.transmitter);control.consistent(physical,now);}
    else {
      std::vector<std::string> signatures;
      for(size_t i=0;i<f.count;i++) {const auto& s=f.inventory[i];signatures.push_back(std::to_string(s.sender)+":"+std::to_string(s.seconds)+":"+std::to_string(s.flags));}
      std::sort(signatures.begin(),signatures.end());std::string signature;
      for(const auto& s:signatures) signature+=s+"|";
      const auto inventorySignature=signature;
      signature+="@"+std::to_string(inventoryGeneration);
      auto old=demands.find(f.transmitter);
      if(old==demands.end() || old->second.boot!=f.boot || old->second.signature!=signature) {
        Demand d;d.peer=f.transmitter;d.boot=f.boot;d.signature=signature;d.until=now+parameters.get("repair_expiry_ms");d.offered=offered;demands[f.transmitter]=d;
      }
      for(const auto& key:missing) {
        const auto id=key+"|"+std::to_string(f.transmitter)+"|"+std::to_string(f.boot);
        if(!repairs.count(id) || repairs.at(id).inventorySignature!=inventorySignature) {
          Repair r;r.state=key;r.peer=f.transmitter;r.boot=f.boot;r.until=now+parameters.get("repair_expiry_ms");
          r.inventorySignature=inventorySignature;repairs[id]=r;repairEvent("MPL_REPAIR_PENDING",r,now);
        }
      }
      tick(now);
    }
    control.log("CONTROL_CLASSIFIED",now,missing.empty() && offered.empty() ? "CONSISTENT" : "MISMATCH");return true;
  }
  bool repairProtected(const std::string& state,uint32_t now) const {
    for(const auto& entry:repairs) {const auto& r=entry.second;
      if(r.state==state && !deadlineReached(now,r.until) && r.used<parameters.get("repair_budget") && buffer.count(state) &&
        neighbors.knowledge(r.peer,buffer.at(state),now)==Knowledge::Missing) return true;
    }return false;
  }
  bool dataDue(const std::string& state,uint32_t now) {
    tick(now);auto it=data.find(state);return it!=data.end() && it->second.opportunity(now,repairProtected(state,now));
  }
  bool controlDue(uint32_t now,bool slot=true) {tick(now);return control.opportunity(now,bootstrap>0 || deficit(),slot);}
  void dataResult(const std::string& state,uint32_t token,uint32_t now,bool success) {
    auto it=data.find(state);if(it==data.end() || !it->second.nativeResult(token,now,success)) return;
    for(auto& entry:repairs) {auto& r=entry.second;
      if(r.state==state && !deadlineReached(now,r.until) && r.used<parameters.get("repair_budget")) {++r.used;repairEvent("MPL_REPAIR_COMPLETED",r,now);}
    }
  }
  void controlResult(uint32_t token,uint32_t inventoryToken,uint32_t now,bool success) {
    if(inventoryToken!=inventoryGeneration) {control.log("CALLBACK_IGNORED",now,"INVENTORY_GENERATION_CHANGED");return;}
    if(control.nativeResult(token,now,success) && bootstrap>0) --bootstrap;
  }
};
}
