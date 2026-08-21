package id.ac.usu.resqmesh

import android.app.PendingIntent
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log

object NativeBleManager {

    private const val TAG = "NativeBleManager"
    private const val REQUEST_CODE_PENDING_INTENT = 123
    const val RESQ_MESH_SERVICE_UUID_STRING = NativeBleConfig.RESQ_MESH_SERVICE_UUID_STRING
    const val BLE_WAKE_UP_ACTION = "id.ac.usu.resqmesh.BLE_WAKE_UP"
    private const val DEFAULT_SCAN_ALL_ADVERTISEMENTS = false
    private var nativeScanActive = false
    private var lastScanErrorCode: String? = null

    internal data class ScanStopTelemetry(
        val success: Boolean,
        val active: Boolean,
        val errorCode: String?
    )

    internal fun stopTelemetryForUnavailable(errorCode: String): ScanStopTelemetry {
        return ScanStopTelemetry(success = true, active = false, errorCode = errorCode)
    }

    internal fun stopTelemetryForStopAttempt(
        success: Boolean,
        exceptionName: String? = null
    ): ScanStopTelemetry {
        return ScanStopTelemetry(
            success = success,
            active = false,
            errorCode = if (success) null else exceptionName
        )
    }

    internal fun scanStatusMapForTest(
        rawNativeScanActive: Boolean,
        rawLastScanErrorCode: String?,
        bluetoothEnabled: Boolean,
        bleSupported: Boolean,
        scannerAvailable: Boolean
    ): Map<String, Any?> {
        val effectiveScannerAvailable = bluetoothEnabled && scannerAvailable
        val effectiveScanActive =
            bluetoothEnabled && rawNativeScanActive && effectiveScannerAvailable
        return mapOf(
            "nativeScanActive" to effectiveScanActive,
            "lastScanErrorCode" to rawLastScanErrorCode,
            "bluetoothEnabled" to bluetoothEnabled,
            "bleSupported" to bleSupported,
            "scannerAvailable" to effectiveScannerAvailable
        )
    }

    private fun getBluetoothAdapter(context: Context): BluetoothAdapter? {
        val bluetoothManager =
            context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
        return bluetoothManager.adapter
    }

    private fun applyStopTelemetry(telemetry: ScanStopTelemetry): Boolean {
        nativeScanActive = telemetry.active
        lastScanErrorCode = telemetry.errorCode
        return telemetry.success
    }

    fun startBleScan(
        context: Context,
        scanAllAdvertisements: Boolean = DEFAULT_SCAN_ALL_ADVERTISEMENTS
    ): Boolean {
        Log.i(TAG, "Starting BLE scan (PendingIntent mode), scanAll=$scanAllAdvertisements")

        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            Log.w(TAG, "BLE PendingIntent scan requires Android 8.0+")
            nativeScanActive = false
            lastScanErrorCode = "SDK_UNSUPPORTED"
            return false
        }

        if (!NativeBlePermissions.hasScanPermission(context)) {
            Log.e(TAG, "Missing required permission for BLE scan")
            nativeScanActive = false
            lastScanErrorCode = "MISSING_PERMISSION"
            return false
        }

        val bluetoothAdapter = getBluetoothAdapter(context)
        if (bluetoothAdapter == null || !bluetoothAdapter.isEnabled) {
            Log.e(TAG, "Bluetooth disabled or unavailable")
            nativeScanActive = false
            lastScanErrorCode = "BLUETOOTH_DISABLED"
            return false
        }

        val scanner = bluetoothAdapter.bluetoothLeScanner
        if (scanner == null) {
            Log.e(TAG, "BLE scanner not available")
            nativeScanActive = false
            lastScanErrorCode = "SCANNER_UNAVAILABLE"
            return false
        }

        val filters = if (scanAllAdvertisements) {
            Log.w(TAG, "Debug scan-all mode is active. Experiment filters are disabled.")
            emptyList()
        } else {
            listOf(
                ScanFilter.Builder()
                    .setManufacturerData(
                        NativeBleConfig.MANUFACTURER_ID,
                        byteArrayOf(0x52, 0x4D),
                        byteArrayOf(0xFF.toByte(), 0xFF.toByte())
                    )
                    .build()
            )
        }

        val scanSettings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_BALANCED)
            .setCallbackType(ScanSettings.CALLBACK_TYPE_ALL_MATCHES)
            .setMatchMode(ScanSettings.MATCH_MODE_AGGRESSIVE)
            .setReportDelay(1000L)
            .build()

        val pendingIntent = buildScanPendingIntent(context)

        return try {
            scanner.startScan(filters, scanSettings, pendingIntent)
            nativeScanActive = true
            lastScanErrorCode = null
            Log.i(TAG, "BLE scan active via PendingIntent")
            true
        } catch (e: Exception) {
            Log.e(TAG, "Fatal error starting scan: ${e.message}", e)
            nativeScanActive = false
            lastScanErrorCode = e.javaClass.simpleName
            false
        }
    }

    fun stopBleScan(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return applyStopTelemetry(
                ScanStopTelemetry(
                    success = false,
                    active = false,
                    errorCode = "SDK_UNSUPPORTED"
                )
            )
        }

        val bluetoothAdapter = getBluetoothAdapter(context)
        if (bluetoothAdapter == null) {
            Log.i(TAG, "Bluetooth adapter unavailable; scan marked inactive")
            return applyStopTelemetry(stopTelemetryForUnavailable("BLUETOOTH_UNAVAILABLE"))
        }

        if (!bluetoothAdapter.isEnabled) {
            Log.i(TAG, "Bluetooth disabled; scan marked inactive")
            return applyStopTelemetry(stopTelemetryForUnavailable("BLUETOOTH_DISABLED"))
        }

        val scanner = bluetoothAdapter.bluetoothLeScanner
        if (scanner == null) {
            Log.i(TAG, "BLE scanner unavailable; scan marked inactive")
            return applyStopTelemetry(stopTelemetryForUnavailable("SCANNER_UNAVAILABLE"))
        }

        return try {
            scanner.stopScan(buildScanPendingIntent(context))
            Log.i(TAG, "BLE scan stopped")
            applyStopTelemetry(stopTelemetryForStopAttempt(success = true))
        } catch (e: Exception) {
            Log.e(TAG, "Error stopping scan: ${e.message}", e)
            applyStopTelemetry(
                stopTelemetryForStopAttempt(
                    success = false,
                    exceptionName = e.javaClass.simpleName
                )
            )
        }
    }

    fun statusMap(context: Context): Map<String, Any?> {
        val adapter = getBluetoothAdapter(context)
        val bluetoothEnabled = adapter?.isEnabled == true
        val scannerAvailable = if (bluetoothEnabled) {
            adapter?.bluetoothLeScanner != null
        } else {
            false
        }
        return scanStatusMapForTest(
            rawNativeScanActive = nativeScanActive,
            rawLastScanErrorCode = lastScanErrorCode,
            bluetoothEnabled = bluetoothEnabled,
            bleSupported = context.packageManager.hasSystemFeature(
                android.content.pm.PackageManager.FEATURE_BLUETOOTH_LE
            ),
            scannerAvailable = scannerAvailable
        )
    }

    private fun buildScanPendingIntent(context: Context): PendingIntent {
        val intent = Intent(context, BleWakeUpReceiver::class.java).apply {
            action = BLE_WAKE_UP_ACTION
            setPackage(context.packageName)
        }
        val mutabilityFlag =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                PendingIntent.FLAG_MUTABLE
            } else {
                0
            }

        return PendingIntent.getBroadcast(
            context,
            REQUEST_CODE_PENDING_INTENT,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or mutabilityFlag
        )
    }
}
