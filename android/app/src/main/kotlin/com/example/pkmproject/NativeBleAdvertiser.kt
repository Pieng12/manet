package id.ac.usu.resqmesh

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.BluetoothLeAdvertiser
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import android.util.Log
import androidx.annotation.RequiresApi

object NativeBleAdvertiser {
    private const val TAG = "NativeBleAdvertiser"
    private const val RESQ_MESH_SERVICE_UUID_STRING = NativeBleConfig.RESQ_MESH_SERVICE_UUID_STRING
    private val RESQ_MESH_SERVICE_UUID = ParcelUuid.fromString(RESQ_MESH_SERVICE_UUID_STRING)

    private var advertiser: BluetoothLeAdvertiser? = null
    private var isAdvertising = false
    private var currentPayload: ByteArray? = null
    private var currentDebugVisible = false
    private var currentConnectable = false
    private var advertiserStatus = "stopped"
    private var lastErrorCode: String? = null
    private var pendingStartCallback: ((Boolean, String, String?) -> Unit)? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private var advertiseGeneration = 0L
    private var activeAdvertiseCallback: AdvertiseCallback? = null

    private fun getBluetoothAdapter(context: Context): BluetoothAdapter? {
        val bluetoothManager =
            context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
        return bluetoothManager.adapter
    }

    @RequiresApi(Build.VERSION_CODES.LOLLIPOP)
    fun startAdvertising(
        context: Context,
        payload: ByteArray?,
        debugVisible: Boolean = currentDebugVisible,
        connectable: Boolean = currentConnectable,
        callback: ((Boolean, String, String?) -> Unit)? = null
    ): Boolean {
        val finalPayload = payload ?: currentPayload
        currentDebugVisible = debugVisible
        currentConnectable = connectable

        Log.d(
            TAG,
            "Starting BLE broadcast. Payload: ${finalPayload?.size ?: 0} bytes, debugVisible=$debugVisible, connectable=$connectable"
        )

        if (!NativeBlePermissions.hasAdvertisePermission(context)) {
            return failStart("MISSING_PERMISSION", callback)
        }

        val bluetoothAdapter = getBluetoothAdapter(context)
        if (bluetoothAdapter == null || !bluetoothAdapter.isEnabled) {
            return failStart("BLUETOOTH_UNAVAILABLE", callback)
        }

        advertiser = bluetoothAdapter.bluetoothLeAdvertiser
        if (advertiser == null) {
            return failStart("FEATURE_UNSUPPORTED", callback)
        }

        if (finalPayload == null) {
            return failStart("MISSING_PAYLOAD", callback)
        }

        if (finalPayload.size != NativeBleConfig.PROTOCOL_LENGTH_BYTES) {
            return failStart("INVALID_PAYLOAD_LENGTH_${finalPayload.size}", callback)
        }

        try {
            activeAdvertiseCallback?.let { advertiser?.stopAdvertising(it) }
        } catch (_: Exception) {
        }

        val dataBuilder = AdvertiseData.Builder()
            .setIncludeDeviceName(false)
            .setIncludeTxPowerLevel(debugVisible)

        dataBuilder.addManufacturerData(NativeBleConfig.MANUFACTURER_ID, finalPayload)
        currentPayload = finalPayload

        val scanResponse = if (debugVisible) {
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
            .setConnectable(connectable)
            .setTimeout(0)
            .build()

        return try {
            val generation = ++advertiseGeneration
            val advertiseCallback = buildAdvertiseCallback(generation)
            activeAdvertiseCallback = advertiseCallback
            isAdvertising = false
            advertiserStatus = "starting"
            lastErrorCode = null
            pendingStartCallback = callback
            if (callback != null) {
                mainHandler.postDelayed({
                    if (advertiserStatus == "starting" && advertiseGeneration == generation) {
                        Log.e(TAG, "BLE advertising start timed out")
                        advertiseGeneration++
                        try {
                            advertiser?.stopAdvertising(advertiseCallback)
                        } catch (_: Exception) {
                        }
                        isAdvertising = false
                        advertiserStatus = "failed"
                        lastErrorCode = "START_TIMEOUT"
                        pendingStartCallback?.invoke(false, advertiserStatus, lastErrorCode)
                        pendingStartCallback = null
                    }
                }, 2500L)
            }

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
            true
        } catch (e: Exception) {
            Log.e(TAG, "Fatal error starting advertiser: ${e.message}", e)
            failStart("START_EXCEPTION", callback)
        }
    }

    @RequiresApi(Build.VERSION_CODES.LOLLIPOP)
    fun stopAdvertising() {
        Log.d(TAG, "Stopping BLE broadcast")
        advertiseGeneration++
        try {
            activeAdvertiseCallback?.let { advertiser?.stopAdvertising(it) }
        } catch (e: Exception) {
            Log.e(TAG, "Error stopping: ${e.message}", e)
        }
        isAdvertising = false
        advertiserStatus = "stopped"
        lastErrorCode = null
        currentPayload = null
        activeAdvertiseCallback = null
    }

    fun isCurrentlyAdvertising(): Boolean {
        return isAdvertising
    }

    fun statusMap(): Map<String, Any?> {
        return mapOf(
            "status" to advertiserStatus,
            "active" to isAdvertising,
            "errorCode" to lastErrorCode,
            "connectable" to currentConnectable,
            "debugVisible" to currentDebugVisible
        )
    }

    private fun failStart(
        errorCode: String,
        callback: ((Boolean, String, String?) -> Unit)?
    ): Boolean {
        Log.e(TAG, "BLE advertising failed before start: $errorCode")
        isAdvertising = false
        advertiserStatus = "failed"
        lastErrorCode = errorCode
        pendingStartCallback = null
        callback?.invoke(false, advertiserStatus, errorCode)
        return false
    }

    private fun buildAdvertiseCallback(generation: Long): AdvertiseCallback {
        return object : AdvertiseCallback() {
            override fun onStartSuccess(settingsInEffect: AdvertiseSettings?) {
                super.onStartSuccess(settingsInEffect)
                if (generation != advertiseGeneration || advertiserStatus != "starting") {
                    Log.w(TAG, "Ignoring stale advertiser success callback generation=$generation")
                    return
                }
                Log.d(TAG, "BLE advertising started successfully")
                isAdvertising = true
                advertiserStatus = "active"
                lastErrorCode = null
                pendingStartCallback?.invoke(true, advertiserStatus, null)
                pendingStartCallback = null
            }

            override fun onStartFailure(errorCode: Int) {
                super.onStartFailure(errorCode)
                if (generation != advertiseGeneration || advertiserStatus != "starting") {
                    Log.w(TAG, "Ignoring stale advertiser failure callback generation=$generation")
                    return
                }
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
                advertiserStatus = "failed"
                lastErrorCode = errorMsg
                pendingStartCallback?.invoke(false, advertiserStatus, errorMsg)
                pendingStartCallback = null
            }
        }
    }
}
