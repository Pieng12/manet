#include <unity.h>
#include "NeighborTransport.h"
#include "NeighborStatusSchedule.h"
#include <cstring>
using namespace resqmesh;
void setUp() {}
void tearDown() {}
Packet packet() { Packet p; p.senderCrc=0x12345678; p.timestampSeconds=kEpochSeconds+42; p.hop=1; return p; }
NeighborFrame status(uint32_t id, bool have=false) { NeighborFrame f; f.status=true; f.transmitter=id; f.boot=2; f.sequence=1; f.scope=4; if(have){f.count=1;f.inventory[0]=inventoryState(packet());}return f; }
void golden() {
  NeighborFrame f=status(1); f.status=false; f.sequence=3; f.packet=packet();
  std::vector<uint8_t> b; TEST_ASSERT_TRUE(encodeFrame(f,b));
  const uint8_t expected[]={0x52,0x4e,1,0,0,0,0,1,0,0,0,2,0,0,0,3,0,0,0,4,0,1,0x52,0x4d,0x12,0x34,0x56,0x78,0,0,42,0,0,0,0,0,0,1,1};
  TEST_ASSERT_EQUAL_UINT32(39,b.size()); TEST_ASSERT_EQUAL_MEMORY(expected,b.data(),39);
  NeighborFrame decoded; TEST_ASSERT_TRUE(decodeFrame(b.data(),b.size(),decoded));
  TEST_ASSERT_EQUAL_UINT32(f.packet.senderCrc,decoded.packet.senderCrc);
  f=status(1); f.sequence=3; TEST_ASSERT_TRUE(encodeFrame(f,b)); TEST_ASSERT_EQUAL_UINT32(22,b.size());
  TEST_ASSERT_TRUE(decodeFrame(b.data(),b.size(),decoded)); TEST_ASSERT_EQUAL(0,decoded.count);
  b[2]=2; TEST_ASSERT_FALSE(decodeFrame(b.data(),b.size(),decoded));
}
void decisions() {
  NeighborController c; c.reset(4); auto have=status(3,true); auto missing=status(4);
  TEST_ASSERT_TRUE(c.observe(have,100,100)); TEST_ASSERT_TRUE(c.observe(missing,100,100));
  TEST_ASSERT_EQUAL_STRING("INITIAL_FORWARD_PENDING",c.decision(packet(),100,true));
  TEST_ASSERT_EQUAL_STRING("FRESH_MISSING",c.decision(packet(),100,false));
  const auto counts=c.counts(packet(),100);TEST_ASSERT_EQUAL_UINT32(1,counts.have);TEST_ASSERT_EQUAL_UINT32(1,counts.missing);
  TEST_ASSERT_FALSE(c.repairAllowed(packet(),100,8000,8000));
  TEST_ASSERT_TRUE(c.repairAllowed(packet(),100,16000,8000));
  missing.sequence=2; TEST_ASSERT_TRUE(c.observe(missing,10000,10000));
  TEST_ASSERT_FALSE(c.repairAllowed(packet(),10000,16000,8000));
  have.sequence=2;have.status=false;have.packet=packet();have.count=0;
  TEST_ASSERT_TRUE(c.observe(have,10001,10001));
  TEST_ASSERT_FALSE(c.repairAllowed(packet(),10001,16000,8000));
}
void freshness() {
  NeighborController c;c.reset(4);
  TEST_ASSERT_EQUAL_STRING("UNKNOWN_OR_NO_NEIGHBORS",c.decision(packet(),0,false));
  auto have=status(3,true);have.complete=false;c.observe(have,100,100);
  TEST_ASSERT_EQUAL(int(Knowledge::Unknown),int(c.knowledge(3,packet(),100)));
  have.complete=true;have.sequence=2;c.observe(have,200,200);
  TEST_ASSERT_EQUAL_STRING("ALL_OBSERVED_HAVE",c.decision(packet(),200,false));
  TEST_ASSERT_EQUAL_STRING("UNKNOWN_OR_NO_NEIGHBORS",c.decision(packet(),45201,false));
  have.scope=5;have.sequence=3;TEST_ASSERT_FALSE(c.observe(have,300,300));
}
void identity() {
  auto f=status(3); auto g=f; g.sequence=2;
  TEST_ASSERT_NOT_EQUAL(0,burstIdentity(f).compare(burstIdentity(g)));
  g=f;g.boot=3;TEST_ASSERT_NOT_EQUAL(0,burstIdentity(f).compare(burstIdentity(g)));
  NeighborController c;c.reset(4);TEST_ASSERT_TRUE(c.observe(f,100,100));TEST_ASSERT_FALSE(c.observe(f,200,200));
  uint32_t boot=3, seq=UINT32_MAX;
  TEST_ASSERT_TRUE(advanceBurstIdentity(boot,seq));TEST_ASSERT_EQUAL_UINT32(4,boot);TEST_ASSERT_EQUAL_UINT32(1,seq);
  boot=seq=UINT32_MAX;TEST_ASSERT_FALSE(advanceBurstIdentity(boot,seq));
  TEST_ASSERT_TRUE(c.newlyExpired(45201).size()==1);TEST_ASSERT_TRUE(c.newlyExpired(50000).empty());
  auto old=status(3);old.boot=1;old.sequence=99;TEST_ASSERT_FALSE(c.observe(old,50000,50000));
}
void timestamps() {
  auto f=status(3);TEST_ASSERT_TRUE(frameTimeValid(f,kEpochSeconds+42));
  f.count=1;f.inventory[0]=inventoryState(packet());
  TEST_ASSERT_TRUE(frameTimeValid(f,kEpochSeconds+42));
  f.inventory[0].seconds=kEpochSeconds+343;TEST_ASSERT_FALSE(frameTimeValid(f,kEpochSeconds+42));
  f.status=false;f.count=0;f.packet=packet();
  TEST_ASSERT_FALSE(frameTimeValid(f,kEpochSeconds-1));
}
void tombstones() {
  NeighborController c;c.reset(4);auto f=status(3,true);
  auto closed=packet();closed.status=Status::Resolved;
  auto ack=closed;ack.kind=PacketKind::Ack;ack.fromServer=true;
  f.inventory[0]=inventoryState(ack);TEST_ASSERT_TRUE(c.observe(f,100,100));
  TEST_ASSERT_EQUAL(int(Knowledge::Have),int(c.knowledge(3,closed,100)));
  TEST_ASSERT_FALSE(c.repairAllowed(closed,100,16000,8000));
  auto newer=packet();newer.timestampSeconds++;
  TEST_ASSERT_EQUAL(int(Knowledge::Missing),int(c.knowledge(3,newer,100)));
}
void cooldown_diagnostics_preserve_pending() {
  NeighborController c;c.reset(4);
  TEST_ASSERT_TRUE(c.observe(status(3),100,100));
  TEST_ASSERT_TRUE(c.repairAllowed(packet(),100,16000,8000));
  TEST_ASSERT_TRUE(c.observe(status(4),200,200));
  for(uint32_t now=200;now<210;++now) TEST_ASSERT_FALSE(c.repairAllowed(packet(),now,16000,8000));
  TEST_ASSERT_TRUE(c.takeRepairDeferred());TEST_ASSERT_FALSE(c.takeRepairDeferred());
  TEST_ASSERT_TRUE(c.observedTransmitters().size()==2);
  TEST_ASSERT_TRUE(c.repairAllowed(packet(),8100,16000,8000));
  TEST_ASSERT_FALSE(c.repairAllowed(packet(),8101,16000,8000));
  TEST_ASSERT_EQUAL_STRING("FRESH_MISSING",c.decision(packet(),8101,false));
}
NeighborStatusSchedule adaptive() {
  NeighborStatusSchedule s;s.parameters.policy="adaptive_v2";s.parameters.statusPeriod=60000;s.parameters.freshness=150000;s.start(0,0);return s;
}
void adaptive_empty_retry() {
  auto s=adaptive();TEST_ASSERT_TRUE(s.parameters.valid());s.start(100,1500);TEST_ASSERT_EQUAL_UINT32(2600,s.nextAt);
  for(const auto interval:{4000,8000,16000,32000,32000,32000}) {
    auto now=s.nextAt;s.statusSucceeded({},now,false,1500);TEST_ASSERT_EQUAL_UINT32(interval+1500,s.nextAt-now);
  }
  s=adaptive();s.failed(1000,1500);TEST_ASSERT_EQUAL_UINT32(3500,s.nextAt);
  s.statusSucceeded({},3500,false,0);TEST_ASSERT_EQUAL_UINT32(7500,s.nextAt);
}
void adaptive_grace_inventory_failure() {
  auto s=adaptive();s.statusSucceeded({},1000,false,0);s.syncInventory({"b","a"},2000,0);
  TEST_ASSERT_EQUAL_UINT32(12000,s.nextAt);
  TEST_ASSERT_FALSE(s.dataSucceeded("a",4000,false,0));TEST_ASSERT_EQUAL_UINT32(12000,s.nextAt);
  s.syncInventory({"a","b"},5000,0);TEST_ASSERT_EQUAL_UINT32(12000,s.nextAt);
  TEST_ASSERT_TRUE(s.dataSucceeded("b",6000,false,1500));TEST_ASSERT_EQUAL_UINT32(22500,s.nextAt);
  s.syncInventory({"c"},7000,0);TEST_ASSERT_EQUAL_UINT32(17000,s.nextAt);
  s.statusSucceeded({"a","b"},8000,true,0);TEST_ASSERT_EQUAL_UINT32(17000,s.nextAt);
  s.failed(17000,0);s.statusSucceeded({"c"},18000,false,0);TEST_ASSERT_EQUAL_UINT32(33000,s.nextAt);
}
void adaptive_maintenance_restart_wrap() {
  auto s=adaptive();s.statusSucceeded({},1000,false,0);s.syncInventory({"a"},2000,0);
  for(const auto interval:{15000,30000,60000,60000}) {
    auto now=s.nextAt;s.statusSucceeded({"a"},now,false,0);TEST_ASSERT_EQUAL_UINT32(interval,s.nextAt-now);
  }
  s=adaptive();s.syncInventory({"a"},0,0);s.dataSucceeded("a",5000,true,0);TEST_ASSERT_EQUAL_UINT32(65000,s.nextAt);
  s.stable(6000,true,0);TEST_ASSERT_EQUAL_UINT32(65000,s.nextAt);
  s.peerChanged(6000,0);TEST_ASSERT_EQUAL_UINT32(21000,s.nextAt);
  s.start(UINT32_MAX-500,1500);s.syncInventory({"a"},UINT32_MAX-500,0);
  TEST_ASSERT_EQUAL_UINT32(1999,s.nextAt);
  TEST_ASSERT_EQUAL_STRING("DISCOVERY",s.reason);
}
void adaptive_repeated_missing_and_freshness() {
  NeighborController c;c.parameters=adaptive().parameters;c.reset(4);
  auto f=status(4);TEST_ASSERT_TRUE(c.observe(f,100,100));TEST_ASSERT_TRUE(c.repairAllowed(packet(),100,16000,8000));
  f.sequence=2;TEST_ASSERT_TRUE(c.observe(f,1000,1000));c.requestMissingPeer(4,packet(),1000);
  TEST_ASSERT_FALSE(c.repairAllowed(packet(),1000,16000,8000));TEST_ASSERT_TRUE(c.repairAllowed(packet(),8100,16000,8000));
  f=status(4,true);f.sequence=3;TEST_ASSERT_TRUE(c.observe(f,10000,10000));
  TEST_ASSERT_EQUAL(int(Knowledge::Have),int(c.knowledge(4,packet(),160000)));
  TEST_ASSERT_EQUAL(int(Knowledge::Unknown),int(c.knowledge(4,packet(),160001)));
  f.sequence=4;TEST_ASSERT_TRUE(c.observe(f,160001,160001));TEST_ASSERT_TRUE(c.peerChanged);
  f.status=false;f.count=0;f.sequence=5;f.packet=packet();TEST_ASSERT_TRUE(c.observe(f,160002,160002));TEST_ASSERT_FALSE(c.peerChanged);
  f=status(4);f.boot=3;TEST_ASSERT_TRUE(c.observe(f,160003,160003));TEST_ASSERT_TRUE(c.peerChanged);
}
void adaptive_coalesced_triggers_and_lost_evidence() {
  auto s=adaptive();s.statusSucceeded({},1000,false,0);s.syncInventory({"a"},2000,0);
  s.syncInventory({"a","b"},3000,0);TEST_ASSERT_EQUAL_UINT32(12000,s.nextAt);
  s.syncInventory({"a","b","c"},4000,0);TEST_ASSERT_EQUAL_UINT32(12000,s.nextAt);
  s=adaptive();s.syncInventory({"a"},0,0);s.dataSucceeded("a",5000,true,0);
  s.stable(6000,false,1500);TEST_ASSERT_EQUAL_UINT32(22500,s.nextAt);
  s.stable(7000,false,0);TEST_ASSERT_EQUAL_UINT32(22500,s.nextAt);
  TEST_ASSERT_EQUAL_UINT32(1,s.inventory.size());
}
int main(int,char**) { UNITY_BEGIN();RUN_TEST(golden);RUN_TEST(decisions);RUN_TEST(freshness);RUN_TEST(identity);RUN_TEST(timestamps);RUN_TEST(tombstones);RUN_TEST(cooldown_diagnostics_preserve_pending);RUN_TEST(adaptive_empty_retry);RUN_TEST(adaptive_grace_inventory_failure);RUN_TEST(adaptive_maintenance_restart_wrap);RUN_TEST(adaptive_repeated_missing_and_freshness);RUN_TEST(adaptive_coalesced_triggers_and_lost_evidence);return UNITY_END(); }
