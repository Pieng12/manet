package com.example.pkmproject

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
    const val BLE_WAKE_UP_ACTION = "com.example.pkmproject.BLE_WAKE_UP"
    private const val DEFAULT_SCAN_ALL_ADVERTISEMENTS = false

    private fun getBluetoothAdapter(context: Context): BluetoothAdapter? {
        val bluetoothManager =
            context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
        return bluetoothManager.adapter
    }

    fun startBleScan(
        context: Context,
        scanAllAdvertisements: Boolean = DEFAULT_SCAN_ALL_ADVERTISEMENTS
    ): Boolean {
        Log.i(TAG, "Starting BLE scan (PendingIntent mode), scanAll=$scanAllAdvertisements")

        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            Log.w(TAG, "BLE PendingIntent scan requires Android 8.0+")
            return false
        }

        if (!NativeBlePermissions.hasScanPermission(context)) {
            Log.e(TAG, "Missing required permission for BLE scan")
            return false
        }

        val bluetoothAdapter = getBluetoothAdapter(context)
        if (bluetoothAdapter == null || !bluetoothAdapter.isEnabled) {
            Log.e(TAG, "Bluetooth disabled or unavailable")
            return false
        }

        val scanner = bluetoothAdapter.bluetoothLeScanner
        if (scanner == null) {
            Log.e(TAG, "BLE scanner not available")
            return false
        }

        val filters = if (scanAllAdvertisements) {
            Log.w(TAG, "Debug scan-all mode is active. Experiment filters are disabled.")
            emptyList()
        } else {
            listOf(
                ScanFilter.Builder()
                    .setManufacturerData(NativeBleConfig.MANUFACTURER_ID, byteArrayOf())
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
            Log.i(TAG, "BLE scan active via PendingIntent")
            true
        } catch (e: Exception) {
            Log.e(TAG, "Fatal error starting scan: ${e.message}", e)
            false
        }
    }

    fun stopBleScan(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return false
        }

        val bluetoothAdapter = getBluetoothAdapter(context)
        val scanner = bluetoothAdapter?.bluetoothLeScanner ?: return false

        return try {
            scanner.stopScan(buildScanPendingIntent(context))
            Log.i(TAG, "BLE scan stopped")
            true
        } catch (e: Exception) {
            Log.e(TAG, "Error stopping scan: ${e.message}", e)
            false
        }
    }

    private fun buildScanPendingIntent(context: Context): PendingIntent {
        val intent = Intent(context, BleWakeUpReceiver::class.java).apply {
            action = BLE_WAKE_UP_ACTION
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
