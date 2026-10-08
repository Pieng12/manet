package id.ac.usu.resqmesh

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

// The research broadcast receiver and its payload helper exist only in debug builds.
class ResearchCommandPayloadTest {
    @Test fun adbStringArrayIsExplicitJsonArrayWithUnsignedIdsPreserved() {
        val payload = researchCommandPayload("configure_session", mapOf(
            "command" to "ignored",
            "node_id" to "android-source",
            "allowed_transmitters" to arrayOf("3376660029", "1347088263")))
        // Assert before serializing: JVM org.json can hide the Android raw-array bug.
        assertTrue(payload.opt("allowed_transmitters") is JSONArray)
        val decoded = JSONObject(payload.toString()).getJSONArray("allowed_transmitters")
        assertEquals(2, decoded.length())
        assertEquals("3376660029", decoded.getString(0))
        assertEquals("1347088263", decoded.getString(1))
        assertEquals("configure_session", payload.getString("command"))
        assertEquals("android-source", payload.getString("node_id"))
    }

    @Test fun emptyAndPrimitiveArraysKeepTheirArrayType() {
        val payload = researchCommandPayload("configure_session", mapOf(
            "empty" to emptyArray<String>(), "numbers" to longArrayOf(3376660029L, 4294967295L)))
        assertTrue(payload.opt("empty") is JSONArray)
        assertTrue(payload.opt("numbers") is JSONArray)
        assertEquals(0, payload.getJSONArray("empty").length())
        assertEquals(4294967295L, payload.getJSONArray("numbers").getLong(1))
    }

    @Test fun scalarExtraTypesAndSpacedNotesRemainUnchanged() {
        val payload = researchCommandPayload("start_trial", mapOf(
            "command_id" to "unique-command", "main_experiment" to true,
            "target_hop" to 0, "protocol_timestamp_ms" to 1791400000000L,
            "latitude" to 3.5952f, "notes" to "catatan dengan spasi", "absent" to null))
        val decoded = JSONObject(payload.toString())
        assertEquals("unique-command", decoded.getString("command_id"))
        assertEquals(true, decoded.getBoolean("main_experiment"))
        assertEquals(0, decoded.getInt("target_hop"))
        assertEquals(1791400000000L, decoded.getLong("protocol_timestamp_ms"))
        assertEquals(3.5952, decoded.getDouble("latitude"), 0.0001)
        assertEquals("catatan dengan spasi", decoded.getString("notes"))
        assertFalse(decoded.has("absent"))
    }

    @Test fun receiverUsesTheTestedPayloadBeforeStartingService() {
        val source = java.io.File("src/debug/kotlin/id/ac/usu/resqmesh/ResearchCommandReceiver.kt").readText()
        assertTrue(source.contains("val json = researchCommandPayload(command,"))
        assertTrue(source.contains("putExtra(\"research_command_json\", json.toString())"))
    }
}
