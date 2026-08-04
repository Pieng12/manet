package com.example.pkmproject

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.BluetoothLeAdvertiser
import android.content.Context
import android.os.Build
import android.os.ParcelUuid
import android.util.Log
import androidx.annotation.RequiresApi

object NativeBleAdvertiser {
    private const val TAG = "NativeBleAdvertiser"
    private const val RESQ_MESH_SERVICE_UUID_STRING = "000021FE-0000-1000-8000-00805F9B34FB"
    private val RESQ_MESH_SERVICE_UUID = ParcelUuid.fromString(RESQ_MESH_SERVICE_UUID_STRING)
    private const val MANUFACTURER_ID = 0xFFFF

    private var advertiser: BluetoothLeAdvertiser? = null
    private var isAdvertising = false
    private var currentPayload: ByteArray? = null
    private var currentDebugVisible = true

    private val advertiseCallback = object : AdvertiseCallback() {
        override fun onStartSuccess(settingsInEffect: AdvertiseSettings?) {
            super.onStartSuccess(settingsInEffect)
            Log.d(TAG, "BLE advertising started successfully")
            isAdvertising = true
        }

        override fun onStartFailure(errorCode: Int) {
            super.onStartFailure(errorCode)
            val errorMsg = when (errorCode) {
                ADVERTISE_FAILED_DATA_TOO_LARGE -> "DATA_TOO_LARGE"
                ADVERTISE_FAILED_TOO_MANY_ADVERTISERS -> "TOO_MANY_ADVERTISERS"
                ADVERTISE_FAILED_ALREADY_STARTED -> "ALREADY_STARTED"
                ADVERTISE_FAILED_INTERNAL_ERROR -> "INTERNAL_ERROR"
                ADVERTISE_FAILED_FEATURE_UNSUPPORTED -> "FEATURE_UNSUPPORTED"
                else -> "UNKNOWN_ERROR ($errorCode)"
            }
            Log.e(TAG, "BLE advertising failed: $errorMsg")
            isAdvertising = false
        }
    }

    private fun getBluetoothAdapter(context: Context): BluetoothAdapter? {
        val bluetoothManager =
            context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
        return bluetoothManager.adapter
    }

    @RequiresApi(Build.VERSION_CODES.LOLLIPOP)
    fun startAdvertising(
        context: Context,
        payload: ByteArray?,
        debugVisible: Boolean = currentDebugVisible
    ): Boolean {
        val finalPayload = payload ?: currentPayload
        currentDebugVisible = debugVisible

        Log.d(
            TAG,
            "Starting BLE broadcast. Payload: ${finalPayload?.size ?: 0} bytes, debugVisible=$debugVisible"
        )

        if (!NativeBlePermissions.hasAdvertisePermission(context)) {
            Log.e(TAG, "Missing BLUETOOTH_ADVERTISE permission")
            return false
        }

        val bluetoothAdapter = getBluetoothAdapter(context)
        if (bluetoothAdapter == null || !bluetoothAdapter.isEnabled) {
            Log.e(TAG, "Bluetooth disabled or unavailable")
            return false
        }

        advertiser = bluetoothAdapter.bluetoothLeAdvertiser
        if (advertiser == null) {
            Log.e(TAG, "Hardware does not support BLE advertising")
            return false
        }

        try {
            advertiser?.stopAdvertising(advertiseCallback)
        } catch (_: Exception) {
        }

        val dataBuilder = AdvertiseData.Builder()
            .setIncludeDeviceName(false)
            .setIncludeTxPowerLevel(debugVisible)

        if (finalPayload != null) {
            val dataToPack =
                if (finalPayload.size > 17) finalPayload.sliceArray(0 until 17) else finalPayload
            dataBuilder.addManufacturerData(MANUFACTURER_ID, dataToPack)
            currentPayload = dataToPack
        } else {
            dataBuilder.addServiceUuid(RESQ_MESH_SERVICE_UUID)
        }

        val scanResponse = if (debugVisible && finalPayload != null) {
            AdvertiseData.Builder()
                .setIncludeDeviceName(false)
                .addServiceUuid(RESQ_MESH_SERVICE_UUID)
                .build()
        } else {
            null
        }

        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_BALANCED)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_MEDIUM)
            .setConnectable(debugVisible)
            .setTimeout(0)
            .build()

        return try {
            if (scanResponse != null) {
                advertiser?.startAdvertising(
                    settings,
                    dataBuilder.build(),
                    scanResponse,
                    advertiseCallback
                )
            } else {
                advertiser?.startAdvertising(settings, dataBuilder.build(), advertiseCallback)
            }
            isAdvertising = true
            true
        } catch (e: Exception) {
            Log.e(TAG, "Fatal error starting advertiser: ${e.message}", e)
            isAdvertising = false
            false
        }
    }

    @RequiresApi(Build.VERSION_CODES.LOLLIPOP)
    fun stopAdvertising() {
        Log.d(TAG, "Stopping BLE broadcast")
        try {
            advertiser?.stopAdvertising(advertiseCallback)
        } catch (e: Exception) {
            Log.e(TAG, "Error stopping: ${e.message}", e)
        }
        isAdvertising = false
        currentPayload = null
    }

    fun isCurrentlyAdvertising(): Boolean {
        return isAdvertising
    }
}
