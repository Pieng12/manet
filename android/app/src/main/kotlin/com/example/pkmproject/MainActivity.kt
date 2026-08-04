package com.example.pkmproject

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
        const val MESH_CHANNEL = "com.example.pkmproject/mesh"
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
