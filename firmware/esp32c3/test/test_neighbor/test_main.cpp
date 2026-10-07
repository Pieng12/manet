#include <unity.h>
#include "NeighborTransport.h"
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
int main(int,char**) { UNITY_BEGIN();RUN_TEST(golden);RUN_TEST(decisions);RUN_TEST(freshness);RUN_TEST(identity);RUN_TEST(timestamps);RUN_TEST(tombstones);return UNITY_END(); }
