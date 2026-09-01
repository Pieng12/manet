package id.ac.usu.resqmesh

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.json.JSONArray

class NativeBleInboxProtocolTest {
    @Test
    fun parsesKnownSosVectorWithCorrectOffsets() {
        val payload = hex("52 4D C6 A2 99 A9 E2 6F 7D 0E 45 FD 2A 83 1F 00 01")

        val metadata = NativeBleInbox.protocolMetadata(payload)

        assertNotNull(metadata)
        metadata!!
        assertEquals(0xC6A299A9L, metadata.senderCrc)
        assertEquals(0xE26F7D, metadata.timestampCompact)
        assertEquals(0, metadata.status)
        assertFalse(metadata.isAck)
        assertFalse(metadata.fromServer)
        assertEquals(1, metadata.hop)
    }

    @Test
    fun parsesAckFromServerAndSaturatedHopFlags() {
        val payload = hex("52 4D 00 00 30 39 00 00 2A 00 00 00 00 00 00 02 FF")

        val metadata = NativeBleInbox.protocolMetadata(payload)

        assertNotNull(metadata)
        metadata!!
        assertEquals(0x3039L, metadata.senderCrc)
        assertEquals(0x2A, metadata.timestampCompact)
        assertEquals(2, metadata.status)
        assertTrue(metadata.isAck)
        assertTrue(metadata.fromServer)
        assertEquals(63, metadata.hop)
    }

    @Test
    fun exactPayloadHashChangesWhenOnlyHopChanges() {
        val hopOne = hex("52 4D C6 A2 99 A9 E2 6F 7D 0E 45 FD 2A 83 1F 00 01")
        val hopTwo = hex("52 4D C6 A2 99 A9 E2 6F 7D 0E 45 FD 2A 83 1F 00 02")

        assertNotEquals(
            NativeBleInbox.exactPayloadHash(hopOne),
            NativeBleInbox.exactPayloadHash(hopTwo)
        )
    }

    @Test
    fun hopChangeKeepsLogicalTrickleConsistencyFields() {
        val hopOne = NativeBleInbox.protocolMetadata(
            hex("52 4D C6 A2 99 A9 E2 6F 7D 0E 45 FD 2A 83 1F 00 01")
        )!!
        val hopTwo = NativeBleInbox.protocolMetadata(
            hex("52 4D C6 A2 99 A9 E2 6F 7D 0E 45 FD 2A 83 1F 00 02")
        )!!

        assertEquals(hopOne.senderCrc, hopTwo.senderCrc)
        assertEquals(hopOne.timestampCompact, hopTwo.timestampCompact)
        assertEquals(hopOne.status, hopTwo.status)
        assertNotEquals(hopOne.hop, hopTwo.hop)
    }

    @Test
    fun sameDeviceSamePayloadRawRepeatsInsideBurstUseOneObservation() {
        val payload = hex("52 4D C6 A2 99 A9 E2 6F 7D 0E 45 FD 2A 83 1F 00 01")
        val first = NativeBleInbox.storeForTest("[]", payload, "AA:AA", -60, 1000L, 1000L)
        val second = NativeBleInbox.storeForTest(first.itemsJson, payload, "AA:AA", -61, 2000L, 2000L)
        val items = JSONArray(second.itemsJson)

        assertEquals(NativeBleInboxStoreStatus.NEW_PENDING, first.result.status)
        assertEquals(NativeBleInboxStoreStatus.EXISTING_PENDING, second.result.status)
        assertEquals(first.result.id, second.result.id)
        assertEquals(first.result.observationId, second.result.observationId)
        assertTrue(second.result.shouldScheduleWorker)
        assertEquals(1, items.length())
        assertEquals(1, items.getJSONObject(0).getInt("duplicate_count"))
        assertEquals(2000L, items.getJSONObject(0).getLong("last_seen_at"))
        assertEquals(-61, items.getJSONObject(0).getInt("last_rssi"))
        assertEquals(first.result.observationId, items.getJSONObject(0).getString("observation_id"))
    }

    @Test
    fun processedObservationRetryKeepsSameObservationAndDoesNotReschedule() {
        val payload = hex("52 4D C6 A2 99 A9 E2 6F 7D 0E 45 FD 2A 83 1F 00 01")
        val first = NativeBleInbox.storeForTest("[]", payload, "AA:AA", -60, 1000L, 1000L)
        val items = JSONArray(first.itemsJson)
        items.getJSONObject(0)
            .put("state", "processed")
            .put("processed_at", 1500L)

        val duplicate = NativeBleInbox.storeForTest(items.toString(), payload, "AA:AA", -62, 2000L, 2000L)
        val after = JSONArray(duplicate.itemsJson)

        assertEquals(
            NativeBleInboxStoreStatus.KNOWN_PROCESSED_DUPLICATE,
            duplicate.result.status
        )
        assertFalse(duplicate.result.shouldScheduleWorker)
        assertEquals(first.result.id, duplicate.result.id)
        assertEquals(first.result.observationId, duplicate.result.observationId)
        assertEquals(1, after.length())
        assertEquals("processed", after.getJSONObject(0).getString("state"))
        assertEquals(1, after.getJSONObject(0).getInt("duplicate_count"))
    }

    @Test
    fun differentDeviceSameExactPayloadCreatesDifferentObservations() {
        val payload = hex("52 4D C6 A2 99 A9 E2 6F 7D 0E 45 FD 2A 83 1F 00 01")
        val first = NativeBleInbox.storeForTest("[]", payload, "AA:AA", -60, 1000L, 1000L)
        val second = NativeBleInbox.storeForTest(first.itemsJson, payload, "BB:BB", -61, 1100L, 1100L)
        val items = JSONArray(second.itemsJson)

        assertEquals(NativeBleInboxStoreStatus.NEW_PENDING, second.result.status)
        assertNotEquals(first.result.id, second.result.id)
        assertNotEquals(first.result.observationId, second.result.observationId)
        assertEquals(2, items.length())
        assertEquals("ble:AA:AA", items.getJSONObject(0).getString("observer_key"))
        assertEquals("ble:BB:BB", items.getJSONObject(1).getString("observer_key"))
    }

    @Test
    fun sameDeviceSamePayloadLaterBurstCreatesNewObservation() {
        val payload = hex("52 4D C6 A2 99 A9 E2 6F 7D 0E 45 FD 2A 83 1F 00 01")
        val first = NativeBleInbox.storeForTest("[]", payload, "AA:AA", -60, 1000L, 1000L)
        val second = NativeBleInbox.storeForTest(first.itemsJson, payload, "AA:AA", -61, 8000L, 8000L)

        assertEquals(NativeBleInboxStoreStatus.NEW_PENDING, second.result.status)
        assertNotEquals(first.result.observationId, second.result.observationId)
        assertEquals(2, JSONArray(second.itemsJson).length())
    }

    @Test
    fun unknownDeviceLaterBurstDoesNotPermanentlyCollapse() {
        val payload = hex("52 4D C6 A2 99 A9 E2 6F 7D 0E 45 FD 2A 83 1F 00 01")
        val first = NativeBleInbox.storeForTest("[]", payload, "unknown", -60, 1000L, 1000L)
        val second = NativeBleInbox.storeForTest(first.itemsJson, payload, "unknown", -61, 8000L, 8000L)

        assertNotEquals(first.result.observationId, second.result.observationId)
        assertEquals(2, JSONArray(second.itemsJson).length())
    }

    @Test
    fun differentExactPayloadCreatesNewInboxRecord() {
        val hopOne = hex("52 4D C6 A2 99 A9 E2 6F 7D 0E 45 FD 2A 83 1F 00 01")
        val hopTwo = hex("52 4D C6 A2 99 A9 E2 6F 7D 0E 45 FD 2A 83 1F 00 02")
        val first = NativeBleInbox.storeForTest("[]", hopOne, "dev", -60, 1000L)
        val second = NativeBleInbox.storeForTest(first.itemsJson, hopTwo, "dev", -61, 2000L)

        assertEquals(NativeBleInboxStoreStatus.NEW_PENDING, second.result.status)
        assertNotEquals(first.result.id, second.result.id)
        assertEquals(2, JSONArray(second.itemsJson).length())
    }

    private fun hex(value: String): ByteArray {
        return value.split(" ")
            .filter { it.isNotEmpty() }
            .map { it.toInt(16).toByte() }
            .toByteArray()
    }
}
