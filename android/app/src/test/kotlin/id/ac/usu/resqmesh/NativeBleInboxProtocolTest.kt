package id.ac.usu.resqmesh

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

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

    private fun hex(value: String): ByteArray {
        return value.split(" ")
            .filter { it.isNotEmpty() }
            .map { it.toInt(16).toByte() }
            .toByteArray()
    }
}
