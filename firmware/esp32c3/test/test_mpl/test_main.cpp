#include <unity.h>
#include "MplScheduler.h"
using namespace resqmesh;
void setUp() {}
void tearDown() {}
Packet p(uint32_t sender=123) {Packet v;v.senderCrc=sender;v.timestampSeconds=kEpochSeconds+42;v.hop=1;return v;}
NeighborFrame summary(uint32_t peer=3,bool have=false,uint32_t seq=1) {
  NeighborFrame f;f.status=true;f.transmitter=peer;f.boot=1;f.sequence=seq;f.scope=4;
  if(have) {f.count=1;f.inventory[0]=inventoryState(p());}return f;
}
void init(MplScheduler& m,uint32_t now=0) {m.random=[](uint32_t){return 0;};m.initialize(4,now);}
void timer_rules() {
  MplScheduler m;m.parameters.values["mpl_control_expirations"]=2;m.parameters.values["mpl_bootstrap_opportunities"]=0;init(m);
  TEST_ASSERT_FALSE(m.controlDue(1999));TEST_ASSERT_TRUE(m.receive(summary(),1000,1000));
  TEST_ASSERT_EQUAL_UINT32(1,m.control.c);TEST_ASSERT_FALSE(m.controlDue(2000));
  m.tick(4000);TEST_ASSERT_EQUAL_UINT32(8000,m.control.interval);TEST_ASSERT_EQUAL_UINT32(1,m.control.e);TEST_ASSERT_EQUAL_UINT32(0,m.control.c);
  m.receive(summary(3,false,2),5000,5000);TEST_ASSERT_FALSE(m.controlDue(8000));m.tick(12000);
  TEST_ASSERT_FALSE(m.control.active);TEST_ASSERT_EQUAL_UINT32(2,m.control.e);
}
void duplicate_freshness() {
  MplScheduler m;init(m);m.sync({p()},0);
  auto f=summary();f.status=false;f.packet=p();
  TEST_ASSERT_TRUE(m.receive(f,100,100));TEST_ASSERT_FALSE(m.receive(f,100,10000));
  TEST_ASSERT_EQUAL_UINT32(1,m.data.at(stateIdentity(p())).c);
  TEST_ASSERT_EQUAL(int(Knowledge::Unknown),int(m.neighbors.knowledge(3,p(),150101)));
  f.sequence=2;TEST_ASSERT_TRUE(m.receive(f,200,200));TEST_ASSERT_EQUAL_UINT32(2,m.data.at(stateIdentity(p())).c);
}
void inventory_classification() {
  MplScheduler m;init(m);m.sync({p()},0);auto f=summary();f.complete=false;
  TEST_ASSERT_TRUE(m.receive(f,100,100));TEST_ASSERT_EQUAL_UINT32(0,m.control.c);TEST_ASSERT_FALSE(m.repairProtected(stateIdentity(p()),100));
  f=summary(3,true,2);m.receive(f,200,200);TEST_ASSERT_EQUAL_UINT32(1,m.control.c);
  MplScheduler empty;init(empty);empty.receive(summary(3,true),100,100);
  TEST_ASSERT_TRUE(empty.deficit());TEST_ASSERT_EQUAL_UINT32(0,empty.data.size());TEST_ASSERT_EQUAL_UINT32(0,empty.buffer.size());
}
void bounded_branch_repair() {
  MplScheduler m;init(m);m.sync({p()},0);m.receive(summary(30),100,100);m.receive(summary(20,true),200,200);
  auto& t=m.data.at(stateIdentity(p()));t.consistent(300,300);TEST_ASSERT_EQUAL_UINT32(1,t.c);
  TEST_ASSERT_TRUE(m.dataDue(t.key,4000));m.dataResult(t.key,t.generation,4000,true);
  TEST_ASSERT_TRUE(m.repairProtected(t.key,4000));m.tick(8100);
  TEST_ASSERT_TRUE(m.dataDue(t.key,t.transmit));m.dataResult(t.key,t.generation,t.transmit,true);
  TEST_ASSERT_FALSE(m.repairProtected(t.key,t.transmit));
  for(uint32_t seq=2;seq<40;seq++) m.receive(summary(30,false,seq),9000+seq,9000+seq);
  TEST_ASSERT_FALSE(m.repairProtected(t.key,10000));
  TEST_ASSERT_EQUAL_UINT32(2,m.repairs.begin()->second.resets);
}
void bootstrap_restart() {
  MplScheduler m;m.parameters.values["mpl_control_expirations"]=1;init(m);
  m.receive(summary(),100,100);TEST_ASSERT_TRUE(m.controlDue(2000));m.controlResult(m.control.generation,m.inventoryGeneration,2000,true);
  TEST_ASSERT_EQUAL_UINT32(1,m.bootstrap);m.tick(4000);TEST_ASSERT_FALSE(m.control.active);
  m.discover(30000);TEST_ASSERT_TRUE(m.control.active);TEST_ASSERT_EQUAL_UINT32(2,m.bootstrap);
}
void retained_buffer() {
  MplScheduler m;m.parameters.values["mpl_data_expirations"]=1;init(m);m.sync({p()},0);m.tick(8000);
  TEST_ASSERT_FALSE(m.data.at(stateIdentity(p())).active);TEST_ASSERT_EQUAL_UINT32(1,m.buffer.size());
  m.receive(summary(),8100,8100);TEST_ASSERT_TRUE(m.data.at(stateIdentity(p())).active);
  m.sync({},8200);TEST_ASSERT_EQUAL_UINT32(0,m.data.size());TEST_ASSERT_EQUAL_UINT32(0,m.repairs.size());
}
void multi_peer_state_bounds() {
  MplScheduler m;init(m);m.sync({p(),p(456)},0);const auto at=m.data.at(stateIdentity(p())).transmit;
  for(uint32_t seq=1;seq<30;seq++) m.receive(summary(3,false,seq),seq*10,seq*10);
  TEST_ASSERT_EQUAL_UINT32(at,m.data.at(stateIdentity(p())).transmit);
  TEST_ASSERT_TRUE(m.repairProtected(stateIdentity(p()),300));TEST_ASSERT_TRUE(m.repairProtected(stateIdentity(p(456)),300));
  m.receive(summary(4),301,301);TEST_ASSERT_EQUAL_UINT32(4,m.repairs.size());
}
void native_failure_generation() {
  MplScheduler m;init(m);m.sync({p()},0);m.receive(summary(),100,100);
  auto& t=m.data.at(stateIdentity(p()));TEST_ASSERT_TRUE(m.dataDue(t.key,4000));
  m.dataResult(t.key,t.generation,4000,false);TEST_ASSERT_TRUE(t.pending);TEST_ASSERT_EQUAL_UINT32(5000,t.retryAt);
  m.dataResult(t.key,t.generation-1,5000,true);TEST_ASSERT_TRUE(t.pending);
  TEST_ASSERT_TRUE(m.dataDue(t.key,5000));m.dataResult(t.key,t.generation,5000,true);TEST_ASSERT_FALSE(t.pending);
  TEST_ASSERT_TRUE(m.controlDue(8000));const auto token=m.control.generation,inventory=m.inventoryGeneration;
  m.sync({p(),p(456)},8100);m.controlResult(token,inventory,8200,true);TEST_ASSERT_EQUAL_UINT32(2,m.bootstrap);
}
void control_slot_and_wrap() {
  MplScheduler m;init(m,UINT32_MAX-999);
  TEST_ASSERT_EQUAL_UINT32(1000,m.control.transmit);TEST_ASSERT_FALSE(m.controlDue(999));
  TEST_ASSERT_FALSE(m.controlDue(1000,false));TEST_ASSERT_TRUE(m.control.pending);TEST_ASSERT_TRUE(m.controlDue(1100));
  m.tick(3000);TEST_ASSERT_EQUAL_UINT32(1,m.control.e);TEST_ASSERT_EQUAL_UINT32(8000,m.control.interval);
}
void replay_boot_partial_and_supersession() {
  MplScheduler m;init(m);m.sync({p()},0);auto f=summary(3,true);f.boot=3;
  TEST_ASSERT_TRUE(m.receive(f,100,100));f.boot=2;f.sequence=4;TEST_ASSERT_FALSE(m.receive(f,200,200));
  f.boot=3;f.sequence=2;TEST_ASSERT_FALSE(m.receive(f,99,200));f.scope=5;TEST_ASSERT_FALSE(m.receive(f,200,200));
  f.scope=4;f.inventory[0].seconds++;TEST_ASSERT_TRUE(m.receive(f,200,200));TEST_ASSERT_TRUE(m.deficit());
  TEST_ASSERT_FALSE(m.repairProtected(stateIdentity(p()),200));
}
void first_data_and_ambiguous_inventory() {
  MplScheduler m;init(m);m.sync({p()},0);
  auto f=summary();f.status=false;f.packet=p();
  TEST_ASSERT_TRUE(m.receive(f,100,100,true));TEST_ASSERT_EQUAL_UINT32(0,m.data.at(stateIdentity(p())).c);
  f=summary(4,true);f.count=2;f.inventory[1]=f.inventory[0];
  TEST_ASSERT_FALSE(m.receive(f,200,200));TEST_ASSERT_EQUAL(int(Knowledge::Unknown),int(m.neighbors.knowledge(4,p(),200)));
}
void settled_late_join_branch() {
  MplScheduler a,d,e;init(a);init(d);init(e);a.sync({p()},0);a.tick(248000);
  TEST_ASSERT_FALSE(a.data.at(stateIdentity(p())).active);d.discover(250000);
  TEST_ASSERT_TRUE(d.controlDue(252000));d.controlResult(d.control.generation,d.inventoryGeneration,252000,false);
  TEST_ASSERT_EQUAL_UINT32(2,d.bootstrap);TEST_ASSERT_TRUE(d.controlDue(253000));
  a.receive(summary(30),253000,253000);a.receive(summary(20,true),253100,253100);
  auto& t=a.data.at(stateIdentity(p()));t.consistent(253200,253200);
  TEST_ASSERT_TRUE(a.dataDue(t.key,257000));a.dataResult(t.key,t.generation,257000,true);
  d.sync({p()},258001);e.discover(260000);e.receive(summary(30,true),260001,260001);
  TEST_ASSERT_TRUE(e.deficit());TEST_ASSERT_TRUE(e.controlDue(262000));
  d.receive(summary(40),262000,262000);TEST_ASSERT_TRUE(d.dataDue(stateIdentity(p()),262001));
  e.sync({p()},262002);TEST_ASSERT_FALSE(e.deficit());TEST_ASSERT_TRUE(e.data.at(stateIdentity(p())).active);
}
void upper_rng_and_late_callback() {
  MplScheduler m;m.random=[](uint32_t span){return span-1;};m.initialize(4,1000);m.sync({p()},1000);
  auto& t=m.data.at(stateIdentity(p()));TEST_ASSERT_EQUAL_UINT32(8999,t.transmit);
  TEST_ASSERT_FALSE(m.dataDue(t.key,8998));TEST_ASSERT_TRUE(m.dataDue(t.key,8999));
  const auto token=t.generation;t.advance(9000);TEST_ASSERT_EQUAL_UINT32(16000,t.interval);
  TEST_ASSERT_FALSE(t.nativeResult(token,9001,true));TEST_ASSERT_EQUAL_UINT32(1,t.e);
}
void expired_deficit_new_incarnation() {
  MplScheduler m;m.parameters.values["mpl_freshness_ms"]=4000;init(m);
  m.receive(summary(3,true),100,100);TEST_ASSERT_TRUE(m.deficit());m.tick(4101);TEST_ASSERT_FALSE(m.deficit());
  auto f=summary();f.boot=2;m.receive(f,4200,4200);TEST_ASSERT_FALSE(m.deficit());
}
int main(int,char**) {UNITY_BEGIN();RUN_TEST(expired_deficit_new_incarnation);RUN_TEST(upper_rng_and_late_callback);RUN_TEST(first_data_and_ambiguous_inventory);RUN_TEST(settled_late_join_branch);RUN_TEST(timer_rules);RUN_TEST(duplicate_freshness);RUN_TEST(inventory_classification);
 RUN_TEST(bounded_branch_repair);RUN_TEST(bootstrap_restart);RUN_TEST(retained_buffer);RUN_TEST(multi_peer_state_bounds);
 RUN_TEST(native_failure_generation);RUN_TEST(control_slot_and_wrap);RUN_TEST(replay_boot_partial_and_supersession);return UNITY_END();}
