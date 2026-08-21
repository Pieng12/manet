package id.ac.usu.resqmesh

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class NativeBleRuntimeTelemetryTest {
    @Test
    fun stopWhenBluetoothAlreadyOffClearsScanTelemetry() {
        val telemetry = NativeBleManager.stopTelemetryForUnavailable("BLUETOOTH_DISABLED")
        val status = NativeBleManager.scanStatusMapForTest(
            rawNativeScanActive = true,
            rawLastScanErrorCode = telemetry.errorCode,
            bluetoothEnabled = false,
            bleSupported = true,
            scannerAvailable = true
        )

        assertTrue(telemetry.success)
        assertFalse(telemetry.active)
        assertEquals("BLUETOOTH_DISABLED", telemetry.errorCode)
        assertFalse(status["nativeScanActive"] as Boolean)
        assertFalse(status["scannerAvailable"] as Boolean)
    }

    @Test
    fun scannerNullClearsScanTelemetry() {
        val telemetry = NativeBleManager.stopTelemetryForUnavailable("SCANNER_UNAVAILABLE")
        val status = NativeBleManager.scanStatusMapForTest(
            rawNativeScanActive = telemetry.active,
            rawLastScanErrorCode = telemetry.errorCode,
            bluetoothEnabled = true,
            bleSupported = true,
            scannerAvailable = false
        )

        assertTrue(telemetry.success)
        assertFalse(telemetry.active)
        assertEquals("SCANNER_UNAVAILABLE", telemetry.errorCode)
        assertFalse(status["nativeScanActive"] as Boolean)
    }

    @Test
    fun exceptionDuringStopClearsScanTelemetryAndRecordsError() {
        val telemetry = NativeBleManager.stopTelemetryForStopAttempt(
            success = false,
            exceptionName = "IllegalStateException"
        )

        assertFalse(telemetry.success)
        assertFalse(telemetry.active)
        assertEquals("IllegalStateException", telemetry.errorCode)
    }

    @Test
    fun statusMapCannotContradictDisabledBluetooth() {
        val status = NativeBleManager.scanStatusMapForTest(
            rawNativeScanActive = true,
            rawLastScanErrorCode = null,
            bluetoothEnabled = false,
            bleSupported = true,
            scannerAvailable = true
        )

        assertFalse(status["bluetoothEnabled"] as Boolean)
        assertFalse(status["nativeScanActive"] as Boolean)
    }

    @Test
    fun normalActiveScanStillReportsTrue() {
        val status = NativeBleManager.scanStatusMapForTest(
            rawNativeScanActive = true,
            rawLastScanErrorCode = null,
            bluetoothEnabled = true,
            bleSupported = true,
            scannerAvailable = true
        )

        assertTrue(status["nativeScanActive"] as Boolean)
        assertTrue(status["scannerAvailable"] as Boolean)
    }

    @Test
    fun normalStopClearsScanTelemetryAndLastError() {
        val telemetry = NativeBleManager.stopTelemetryForStopAttempt(success = true)

        assertTrue(telemetry.success)
        assertFalse(telemetry.active)
        assertNull(telemetry.errorCode)
    }

    @Test
    fun advertiserTelemetryCannotReportActiveWhenBluetoothIsOff() {
        val status = NativeBleRuntimeTelemetry.advertisingStatusMap(
            rawStatus = "active",
            rawActive = true,
            rawErrorCode = null,
            connectable = false,
            debugVisible = false,
            bluetoothEnabled = false,
            advertiserAvailable = false
        )

        assertFalse(status["active"] as Boolean)
        assertEquals("bluetooth_disabled", status["status"])
        assertEquals("BLUETOOTH_DISABLED", status["errorCode"])
    }
}
