package id.ac.usu.resqmesh

import android.bluetooth.BluetoothAdapter
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        const val MESH_CHANNEL = "id.ac.usu.resqmesh/mesh"
        private const val SERVICE_PREFS = "resqmesh_service_state"
        private const val KEY_RELAY_MODE_ENABLED = "relay_mode_enabled"
        private const val KEY_HAS_PENDING_RELAY_WORK = "has_pending_relay_work"
    }

    private var bleStateReceiverRegistered = false

    private val bleStateReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action != BluetoothAdapter.ACTION_STATE_CHANGED) return

            val appContext = this@MainActivity.applicationContext
            val state = intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, BluetoothAdapter.ERROR)
            if (state == BluetoothAdapter.STATE_OFF || state == BluetoothAdapter.STATE_TURNING_OFF) {
                Log.d("MainActivity", "Bluetooth turned off. Stopping BLE scan.")
                NativeBleManager.stopBleScan(appContext)
            } else if (state == BluetoothAdapter.STATE_ON) {
                Log.d("MainActivity", "Bluetooth turned on. Restarting BLE scan.")
                NativeBleManager.startBleScan(appContext)
                NativeBleInboxWorker.enqueueIfPendingAndPermitted(appContext)
                requestSchedulerTick()
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, MESH_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getAndroidSdkInt" -> {
                        result.success(Build.VERSION.SDK_INT)
                    }
                    "startBackgroundService" -> {
                        startMeshBackgroundService()
                        result.success(true)
                    }
                    "requestSchedulerTick" -> {
                        requestSchedulerTick()
                        result.success(true)
                    }
                    "stopBackgroundService" -> {
                        stopMeshBackgroundService()
                        result.success(true)
                    }
                    "requestIgnoreBatteryOptimizations" -> {
                        result.success(NativeBatteryOptimization.requestExemption(this))
                    }
                    "isIgnoringBatteryOptimizations" -> {
                        result.success(NativeBatteryOptimization.isIgnoring(this))
                    }
                    "setRelayModeEnabled" -> {
                        servicePrefs().edit()
                            .putBoolean(KEY_RELAY_MODE_ENABLED, call.argument<Boolean>("enabled") != false)
                            .apply()
                        result.success(true)
                    }
                    "setHasPendingRelayWork" -> {
                        servicePrefs().edit()
                            .putBoolean(KEY_HAS_PENDING_RELAY_WORK, call.argument<Boolean>("hasPending") == true)
                            .apply()
                        result.success(true)
                    }
                    "hasPendingRelayWork" -> {
                        result.success(
                            servicePrefs().getBoolean(KEY_HAS_PENDING_RELAY_WORK, false) ||
                                NativeBleInbox.pendingCount(this) > 0
                        )
                    }
                    "getPendingBleInbox" -> {
                        result.success(NativeBleInbox.pending(this))
                    }
                    "acknowledgeBleInboxItem" -> {
                        val id = call.argument<String>("id")
                        result.success(id != null && NativeBleInbox.acknowledge(this, id))
                    }
                    "failBleInboxItem" -> {
                        val id = call.argument<String>("id")
                        result.success(id != null && NativeBleInbox.fail(this, id))
                    }
                    "resumePendingNativeBleInbox" -> {
                        result.success(NativeBleInboxWorker.enqueueIfPendingAndPermitted(this))
                    }
                    "clearNativeBleInboxPermissionBlocked" -> {
                        if (NativeBlePermissions.hasRequiredRuntimePermissions(this)) {
                            NativeBleInbox.clearPermissionBlocked(this)
                            result.success(true)
                        } else {
                            result.success(false)
                        }
                    }
                    "getBleCapabilities" -> {
                        result.success(bleCapabilities())
                    }
                    "startBleWakeUpScan" -> {
                        val scanAllAdvertisements =
                            call.argument<Boolean>("scanAllAdvertisements") ?: false
                        val success = NativeBleManager.startBleScan(this, scanAllAdvertisements)
                        result.success(success)
                    }
                    "stopBleWakeUpScan" -> {
                        val success = NativeBleManager.stopBleScan(this)
                        result.success(success)
                    }
                    "startNativeBleAdvertising" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                            val payloadBase64 = call.argument<String>("payload")
                            val payload = if (payloadBase64 != null) {
                                android.util.Base64.decode(
                                    payloadBase64,
                                    android.util.Base64.NO_WRAP
                                )
                            } else {
                                null
                            }
                            val debugVisible =
                                call.argument<Boolean>("debugVisible") ?: false
                            val connectable =
                                call.argument<Boolean>("connectable") ?: false
                            NativeBleAdvertiser.startAdvertising(
                                this,
                                payload,
                                debugVisible,
                                connectable
                            ) { success, _, _ ->
                                result.success(success)
                            }
                        } else {
                            result.success(false)
                        }
                    }
                    "stopNativeBleAdvertising" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                            NativeBleAdvertiser.stopAdvertising()
                            result.success(true)
                        } else {
                            result.success(false)
                        }
                    }
                    "isNativeBleAdvertising" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                            result.success(NativeBleAdvertiser.isCurrentlyAdvertising())
                        } else {
                            result.success(false)
                        }
                    }
                    "getNativeBleAdvertisingStatus" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                            result.success(NativeBleAdvertiser.statusMap())
                        } else {
                            result.success(
                                mapOf(
                                    "status" to "unsupported",
                                    "active" to false,
                                    "errorCode" to "SDK_UNSUPPORTED"
                                )
                            )
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onResume() {
        super.onResume()
        registerBleStateReceiver()
        if (NativeBlePermissions.hasRequiredRuntimePermissions(this)) {
            NativeBleInboxWorker.enqueueIfPendingAndPermitted(this)
            requestSchedulerTick()
        }
    }

    override fun onPause() {
        super.onPause()
        unregisterBleStateReceiver()
    }

    override fun onDestroy() {
        super.onDestroy()
        unregisterBleStateReceiver()
    }

    private fun registerBleStateReceiver() {
        if (bleStateReceiverRegistered) return

        val filter = IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                registerReceiver(bleStateReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
            } else {
                @Suppress("DEPRECATION")
                registerReceiver(bleStateReceiver, filter)
            }
            bleStateReceiverRegistered = true
        } catch (e: Exception) {
            Log.e("MainActivity", "Failed to register BLE receiver: ${e.message}", e)
        }
    }

    private fun servicePrefs() = getSharedPreferences(SERVICE_PREFS, Context.MODE_PRIVATE)

    private fun bleCapabilities(): Map<String, Any?> {
        val adapter = (getSystemService(Context.BLUETOOTH_SERVICE) as android.bluetooth.BluetoothManager).adapter
        val scanStatus = NativeBleManager.statusMap(this)
        val advertiseStatus = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            NativeBleAdvertiser.statusMap()
        } else {
            mapOf("status" to "unsupported", "active" to false, "errorCode" to "SDK_UNSUPPORTED")
        }
        return mapOf(
            "sdkInt" to Build.VERSION.SDK_INT,
            "deviceManufacturer" to Build.MANUFACTURER,
            "deviceModel" to Build.MODEL,
            "bluetoothEnabled" to (adapter?.isEnabled == true),
            "bleSupported" to packageManager.hasSystemFeature(
                android.content.pm.PackageManager.FEATURE_BLUETOOTH_LE
            ),
            "scannerAvailable" to scanStatus["scannerAvailable"],
            "advertiserAvailable" to (adapter?.bluetoothLeAdvertiser != null),
            "multipleAdvertisementSupported" to (adapter?.isMultipleAdvertisementSupported == true),
            "scanPermission" to NativeBlePermissions.hasScanPermission(this),
            "advertisePermission" to NativeBlePermissions.hasAdvertisePermission(this),
            "connectPermission" to NativeBlePermissions.hasConnectPermission(this),
            "nativeScanActive" to scanStatus["nativeScanActive"],
            "nativeAdvertisingActive" to advertiseStatus["active"],
            "nativeAdvertisingStatus" to advertiseStatus["status"],
            "lastErrorCode" to (advertiseStatus["errorCode"] ?: scanStatus["lastScanErrorCode"]),
            "foregroundServiceActive" to MeshBackgroundService.serviceStarted,
            "pendingNativeInbox" to NativeBleInbox.pendingCount(this),
            "nativeInboxPermissionBlockedAt" to NativeBleInbox.permissionBlockedAt(this),
            "relayModeEnabled" to servicePrefs().getBoolean(KEY_RELAY_MODE_ENABLED, true),
            "nativeManufacturerId" to NativeBleConfig.MANUFACTURER_ID
        )
    }

    private fun unregisterBleStateReceiver() {
        if (!bleStateReceiverRegistered) return

        try {
            unregisterReceiver(bleStateReceiver)
        } catch (e: Exception) {
            Log.e("MainActivity", "Failed to unregister BLE receiver: ${e.message}", e)
        } finally {
            bleStateReceiverRegistered = false
        }
    }

    private fun startMeshBackgroundService() {
        try {
            if (!NativeBlePermissions.hasRequiredRuntimePermissions(this)) {
                Log.w("MainActivity", "Required permissions missing. Background service start deferred.")
                return
            }

            val intent = Intent(this, MeshBackgroundService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(intent)
            } else {
                startService(intent)
            }
            Log.d("MainActivity", "Background service started")
        } catch (e: Exception) {
            Log.e("MainActivity", "Error starting background service: ${e.message}", e)
        }
    }

    private fun stopMeshBackgroundService() {
        try {
            val intent = Intent(this, MeshBackgroundService::class.java)
            stopService(intent)
            Log.d("MainActivity", "Background service stopped")
        } catch (e: Exception) {
            Log.e("MainActivity", "Error stopping background service: ${e.message}", e)
        }
    }

    private fun requestSchedulerTick() {
        try {
            val intent = Intent(this, MeshBackgroundService::class.java).apply {
                action = MeshBackgroundService.SCHEDULER_TICK_ACTION
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(intent)
            } else {
                startService(intent)
            }
            Log.d("MainActivity", "Scheduler tick requested")
        } catch (e: Exception) {
            Log.e("MainActivity", "Error requesting scheduler tick: ${e.message}", e)
        }
    }

}
