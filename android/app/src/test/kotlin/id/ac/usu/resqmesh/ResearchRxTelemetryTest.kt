package id.ac.usu.resqmesh

import java.io.File
import org.junit.Assert.*
import org.junit.Test

class ResearchRxTelemetryTest {
    @Test fun inactiveResearchNeverCollects() {
        assertFalse(ResearchRxTelemetry.eligible(null, "trial", 200, 100, "obs"))
        assertFalse(ResearchRxTelemetry.eligible("session", null, 200, 100, "obs"))
        assertFalse(ResearchRxTelemetry.eligible("session", "trial", 100, 100, "obs"))
        assertFalse(ResearchRxTelemetry.eligible("session", "trial", 200, 100, ""))
        assertTrue(ResearchRxTelemetry.eligible("session", "trial", 200, 100, "obs"))
    }
    @Test fun optionalActualPhyNeverGatesInboxAndIsIdempotent() {
        val root = File("src/main/kotlin/com/example/pkmproject")
        val receiver = File(root, "BleWakeUpReceiver.kt").readText()
        assertTrue(receiver.indexOf("NativeBleInbox.store(") < receiver.indexOf("ResearchRxTelemetry.record("))
        assertTrue(receiver.contains("RangeRxTelemetry.bestEffort {\n            ResearchRxTelemetry.record"))
        val store = File(root, "ResearchRxTelemetry.kt").readText()
        assertTrue(store.contains("observation_id TEXT PRIMARY KEY"))
        assertTrue(store.contains("SQLiteDatabase.CONFLICT_IGNORE"))
        assertTrue(store.contains("put(\"primary_phy\", primary"))
        assertTrue(store.contains("put(\"secondary_phy\", secondary"))
        assertTrue(store.contains("put(\"coding\", \"unknown\")"))
        assertFalse(RangeRxTelemetry.bestEffort { throw IllegalStateException("disk full") })
    }
}
