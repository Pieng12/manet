package id.ac.usu.resqmesh

import android.bluetooth.le.AdvertisingSetParameters
import org.junit.Assert.*
import org.junit.Test

class CodedRadioPolicyTest {
    @Test fun highPowerKeepsRadioIntervalAndUnsupportedS8Policy() {
        assertEquals(AdvertisingSetParameters.TX_POWER_HIGH, CodedRadioPolicy.TX_POWER_DBM)
        assertEquals(400, CodedRadioPolicy.INTERVAL_UNITS)
        assertEquals("S8_SELECTION_UNSUPPORTED", CodedRadioPolicy.rejection(30, true, true, true, true, true, "coded_s8_required"))
    }
    @Test fun codedScanAvoidsBatchReportsThatLosePhyMetadata() {
        assertEquals(0L, CodedRadioPolicy.SCAN_REPORT_DELAY_MS)
    }
    @Test fun capabilitiesDoNotInventS8Support() {
        assertNull(CodedRadioPolicy.rejection(30, true, true, true, true, true, "coded"))
        assertEquals("S8_SELECTION_UNSUPPORTED", CodedRadioPolicy.rejection(30, true, true, true, true, true, "coded_s8_required"))
        assertEquals("CODED_PHY_UNSUPPORTED", CodedRadioPolicy.rejection(30, true, true, true, false, true, "coded"))
        assertEquals("EXTENDED_ADVERTISING_UNSUPPORTED", CodedRadioPolicy.rejection(30, true, true, true, true, false, "coded"))
        assertEquals("SDK_UNSUPPORTED", CodedRadioPolicy.rejection(25, true, true, true, true, true, "coded"))
        assertEquals("MISSING_PERMISSION", CodedRadioPolicy.rejection(30, true, false, true, true, true, "coded"))
        assertEquals("BLUETOOTH_UNAVAILABLE", CodedRadioPolicy.rejection(30, false, true, true, true, true, "coded"))
    }
    @Test fun payloadReplacementAndLateCallbackCannotCompleteNewBurst() {
        val state = AdvertisingLifecycle()
        val sos = state.begin()
        state.cancel()
        val ack = state.begin()
        assertFalse(state.finish(sos))
        assertTrue(state.starting)
        assertTrue(state.finish(ack))
        assertFalse(state.finish(ack))
    }
    @Test fun timeoutAndStopRejectLateSuccess() {
        val state = AdvertisingLifecycle()
        val token = state.begin()
        assertTrue(state.finish(token)) // Timeout consumes the pending completion.
        state.cancel()
        assertFalse(state.finish(token))
        val pending = state.begin()
        state.cancel()
        assertFalse(state.finish(pending))
    }
}
