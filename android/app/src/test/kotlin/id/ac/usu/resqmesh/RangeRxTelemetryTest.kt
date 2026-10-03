package id.ac.usu.resqmesh

import java.io.File
import org.junit.Assert.*
import org.junit.Test

class RangeRxTelemetryTest {
    @Test fun usesActualPhyNeverRequestedCoding() {
        assertTrue(RangeRxTelemetry.coded(3, 3, false))
        assertFalse(RangeRxTelemetry.coded(1, 0, true))
        assertFalse(RangeRxTelemetry.coded(3, null, false))
        assertFalse(RangeRxTelemetry.coded(3, 3, null))
    }
    @Test fun disabledOutsidePilotAndAfterDeadline() {
        assertFalse(RangeRxTelemetry.eligible(null, 200, 100, "obs"))
        assertFalse(RangeRxTelemetry.eligible("pilot", 100, 100, "obs"))
        assertFalse(RangeRxTelemetry.eligible("pilot", 200, 100, ""))
        assertTrue(RangeRxTelemetry.eligible("pilot", 200, 100, "obs"))
    }
    @Test fun diagnosticFailureCannotEscapeIntoDurableProcessing() {
        assertFalse(RangeRxTelemetry.bestEffort { throw IllegalStateException("disk full") })
        var durableProcessingContinued = false
        RangeRxTelemetry.bestEffort { throw IllegalStateException("disk full") }
        durableProcessingContinued = true
        assertTrue(durableProcessingContinued)
    }
    @Test fun schemaIsIdempotentAndReceiverPersistsInboxBeforeSidecar() {
        val root = File("src/main/kotlin/com/example/pkmproject")
        val telemetry = File(root, "RangeRxTelemetry.kt").readText()
        assertTrue(telemetry.contains("observation_id TEXT PRIMARY KEY"))
        assertTrue(telemetry.contains("SQLiteDatabase.CONFLICT_IGNORE"))
        val receiver = File(root, "BleWakeUpReceiver.kt").readText()
        assertTrue(receiver.indexOf("NativeBleInbox.store(") < receiver.indexOf("RangeRxTelemetry.record("))
        assertTrue(receiver.contains("scanResult.primaryPhy"))
        assertTrue(receiver.contains("scanResult.secondaryPhy"))
        assertTrue(receiver.contains("RangeRxTelemetry.bestEffort"))
    }
}
