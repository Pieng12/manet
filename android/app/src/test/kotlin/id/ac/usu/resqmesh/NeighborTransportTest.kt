package id.ac.usu.resqmesh
import org.junit.Assert.*
import org.junit.Test

class NeighborTransportTest {
    @Test fun neighborRecoveryNeverStartsAnIndependentEvidenceOwner() {
        assertFalse(NeighborTransport.requiresSchedulerOwner(null))
        assertFalse(NeighborTransport.requiresSchedulerOwner(""))
        for (mode in listOf("basic_flooding","trickle_no_suppression","trickle","trickle_neighbor_status")) {
            assertTrue(NeighborTransport.requiresSchedulerOwner("{\"mode\":\"$mode\",\"scope\":4}"))
        }
        assertTrue(NeighborTransport.requiresSchedulerOwner("corrupt-profile-retained-for-recovery"))
    }
    private fun hex(s: String) = s.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
    private val data = "524e0100000000010000000200000003000000040001524d1234567800002a0000000000000101"
    @Test fun goldenFrames() {
        val f=NeighborTransport.decode(hex(data))!!
        assertEquals("4:1:2:3",f.burstIdentity)
        assertArrayEquals(hex("524d1234567800002a0000000000000101"),f.inner)
        val empty=NeighborTransport.decode(hex("524e0101000000010000000200000003000000040001"))!!
        assertTrue(empty.status);assertTrue(empty.complete);assertTrue(empty.inventory.isEmpty())
        val status=NeighborTransport.decode(hex("524e01010000000100000002000000030000000401011234567800002a01"))!!
        assertEquals(1,status.inventory.size)
    }
    @Test fun malformedAndInvalidAckRejected() {
        for (offset in listOf(0,2,3,20,21,37)) { val b=hex(data);b[offset]=255.toByte();assertNull(NeighborTransport.decode(b)) }
        val noId=hex(data); (4..7).forEach { noId[it]=0 };assertNull(NeighborTransport.decode(noId))
        assertNull(NeighborTransport.decode(hex(data).dropLast(1).toByteArray()))
        val activeAck=hex(data);activeAck[38]=0x81.toByte();assertNull(NeighborTransport.decode(activeAck))
    }
    @Test fun payloadMetadataKeepsSourceDistinctFromTransmitter() {
        val f=NeighborTransport.decode(hex(data))!!
        val m=NativeBleInbox.protocolMetadata(hex(data))!!
        assertEquals(0x12345678L,m.senderCrc);assertEquals(1L,f.transmitter)
        assertEquals(42,m.timestampCompact)
        assertTrue(NeighborTransport.validPayload(f.inner!!))
    }
    @Test fun durableEnvelopeReplayUsesBurstNotMacOrGap() {
        val first=NativeBleInbox.storeForTest("[]",hex(data),"AA",-41,1000,500)
        val retry=NativeBleInbox.storeForTest(first.itemsJson,hex(data),"BB",-50,10000,9500)
        assertEquals(first.result.observationId,retry.result.observationId)
        assertEquals(NativeBleInboxStoreStatus.EXISTING_PENDING,retry.result.status)
        val items=org.json.JSONArray(retry.itemsJson)
        assertEquals(1000L,items.getJSONObject(0).getLong("received_at"))
        assertEquals(500L,items.getJSONObject(0).getLong("received_elapsed_realtime_ms"))
        items.getJSONObject(0).put("state","processed")
        assertFalse(NativeBleInbox.storeForTest(items.toString(),hex(data),"CC",-60,20000).result.shouldScheduleWorker)
        val next=hex(data);next[15]=4
        assertNotEquals(first.result.observationId,NativeBleInbox.storeForTest(items.toString(),next,"AA",-40,21000).result.observationId)
    }
}
