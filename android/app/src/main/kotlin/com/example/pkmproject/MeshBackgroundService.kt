package com.example.pkmproject

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
import androidx.core.app.NotificationCompat
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugins.GeneratedPluginRegistrant

class MeshBackgroundService : Service() {

    private val tag = "MeshBackgroundService"
    private val channelId = "ResQMeshBackgroundService"
    private val notificationId = 1
    private var flutterEngine: FlutterEngine? = null

    private val dutyCycleHandler = Handler(Looper.getMainLooper())
    private lateinit var dutyCycleRunnable: Runnable

    private val idleStopHandler = Handler(Looper.getMainLooper())
    private lateinit var idleStopRunnable: Runnable
    private val idleStopDelay = 60000L

    companion object {
        const val DART_ENTRYPOINT = "backgroundServiceMain"
        const val CONNECTIVITY_CHANGED_ACTION = "com.example.pkmproject.CONNECTIVITY_CHANGED"
        var serviceStarted = false
    }

    override fun onCreate() {
        super.onCreate()
        Log.d(tag, "MeshBackgroundService onCreate")

        if (!NativeBlePermissions.hasRequiredRuntimePermissions(this)) {
            Log.w(tag, "Required runtime permissions are missing. Service will not start.")
            stopSelf()
            return
        }

        createNotificationChannel()
        val notification = buildNotification()
        if (!startAsForeground(notification)) {
            stopSelf()
            return
        }

        if (!serviceStarted) {
            startFlutterHeadlessEngine()
            serviceStarted = true
        }

        ConnectivityReceiver.flutterEngine = flutterEngine
        ConnectivityReceiver.register(this)

        setupDutyCycle()
        setupIdleStop()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Log.d(tag, "MeshBackgroundService onStartCommand")

        if (!NativeBlePermissions.hasRequiredRuntimePermissions(this)) {
            Log.w(tag, "Missing permissions on start command. Stopping service.")
            stopSelf()
            return START_NOT_STICKY
        }

        if (!serviceStarted) {
            startFlutterHeadlessEngine()
            serviceStarted = true
        }

        if (::dutyCycleRunnable.isInitialized) {
            dutyCycleHandler.removeCallbacks(dutyCycleRunnable)
            dutyCycleHandler.post(dutyCycleRunnable)
        }

        resetIdleStop()

        intent?.action?.let { action ->
            Log.d(tag, "Received intent with action: $action")
            when (action) {
                NativeBleManager.BLE_WAKE_UP_ACTION -> {
                    val payloadBase64 = intent.getStringExtra("payload")
                    val deviceAddress = intent.getStringExtra("device_address")
                    val rssi = intent.getIntExtra("rssi", 0)
                    sendPayloadToFlutter(payloadBase64, deviceAddress, rssi)
                }
                CONNECTIVITY_CHANGED_ACTION -> {
                    sendWakeUpToFlutter("connectivityChanged", null, null, 0)
                }
            }
        }

        return START_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        super.onTaskRemoved(rootIntent)
        Log.d(tag, "onTaskRemoved called. Stopping foreground service.")
        stopSelf()
    }

    override fun onDestroy() {
        super.onDestroy()
        Log.d(tag, "MeshBackgroundService onDestroy")

        if (::dutyCycleRunnable.isInitialized) {
            dutyCycleHandler.removeCallbacks(dutyCycleRunnable)
        }
        if (::idleStopRunnable.isInitialized) {
            idleStopHandler.removeCallbacks(idleStopRunnable)
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            NativeBleAdvertiser.stopAdvertising()
        }

        ConnectivityReceiver.unregister(this)
        ConnectivityReceiver.flutterEngine = null
        flutterEngine?.destroy()
        flutterEngine = null
        serviceStarted = false
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun buildNotification(): Notification {
        return NotificationCompat.Builder(this, channelId)
            .setContentTitle("ResQMesh aktif")
            .setContentText("Memantau sinyal darurat BLE di sekitar")
            .setSmallIcon(R.mipmap.ic_launcher)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setShowWhen(false)
            .build()
    }

    private fun startAsForeground(notification: Notification): Boolean {
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    notificationId,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC or
                        ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
                )
            } else {
                startForeground(notificationId, notification)
            }
            Log.d(tag, "Foreground service started")
            true
        } catch (e: Exception) {
            Log.e(tag, "Failed to start foreground service: ${e.message}", e)
            false
        }
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val serviceChannel = NotificationChannel(
                channelId,
                "ResQMesh Background Service",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Background service for mesh networking and data sync"
                setShowBadge(false)
                enableLights(false)
                enableVibration(false)
                setSound(null, null)
            }

            val notificationManager = getSystemService(NotificationManager::class.java)
            notificationManager.createNotificationChannel(serviceChannel)
        }
    }

    private fun startFlutterHeadlessEngine() {
        if (flutterEngine != null) return

        Log.d(tag, "Starting Flutter headless engine.")

        val loader = FlutterInjector.instance().flutterLoader()
        loader.startInitialization(this)
        loader.ensureInitializationComplete(this, null)

        flutterEngine = FlutterEngine(this)
        GeneratedPluginRegistrant.registerWith(flutterEngine!!)
        registerMeshChannel(flutterEngine!!)

        flutterEngine?.dartExecutor?.executeDartEntrypoint(
            DartExecutor.DartEntrypoint(
                loader.findAppBundlePath(),
                DART_ENTRYPOINT
            )
        )

        ConnectivityReceiver.flutterEngine = flutterEngine
    }

    private fun registerMeshChannel(engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, MainActivity.MESH_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getAndroidSdkInt" -> {
                        result.success(Build.VERSION.SDK_INT)
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
                                call.argument<Boolean>("debugVisible") ?: true
                            val success =
                                NativeBleAdvertiser.startAdvertising(this, payload, debugVisible)
                            result.success(success)
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
                    "startBleWakeUpScan" -> {
                        result.success(NativeBleManager.startBleScan(this))
                    }
                    "stopBleWakeUpScan" -> {
                        result.success(NativeBleManager.stopBleScan(this))
                    }
                    "startBackgroundService" -> {
                        result.success(true)
                    }
                    "requestIgnoreBatteryOptimizations" -> {
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun setupDutyCycle() {
        dutyCycleRunnable = Runnable {
            NativeBleManager.startBleScan(this)

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP &&
                NativeBleAdvertiser.isCurrentlyAdvertising()
            ) {
                NativeBleAdvertiser.startAdvertising(this, null)
            }

            dutyCycleHandler.postDelayed(dutyCycleRunnable, 30000)
        }
    }

    private fun setupIdleStop() {
        idleStopRunnable = Runnable {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP &&
                NativeBleAdvertiser.isCurrentlyAdvertising()
            ) {
                resetIdleStop()
            } else {
                Log.d(tag, "No active advertising after idle timeout. Stopping service.")
                stopSelf()
            }
        }
    }

    private fun resetIdleStop() {
        if (!::idleStopRunnable.isInitialized) return

        idleStopHandler.removeCallbacks(idleStopRunnable)
        idleStopHandler.postDelayed(idleStopRunnable, idleStopDelay)
    }

    private fun sendPayloadToFlutter(
        payloadBase64: String?,
        deviceAddress: String?,
        rssi: Int,
        retryCount: Int = 0
    ) {
        sendWakeUpToFlutter("bleWakeUpTriggered", payloadBase64, deviceAddress, rssi, retryCount)
    }

    private fun sendWakeUpToFlutter(
        methodName: String,
        payloadBase64: String?,
        deviceAddress: String?,
        rssi: Int,
        retryCount: Int = 0
    ) {
        val maxRetries = 10
        val retryDelayMs = 500L

        if (flutterEngine == null) {
            startFlutterHeadlessEngine()
        }

        val engine = flutterEngine
        if (engine == null || !engine.dartExecutor.isExecutingDart) {
            if (retryCount < maxRetries) {
                dutyCycleHandler.postDelayed({
                    sendWakeUpToFlutter(
                        methodName,
                        payloadBase64,
                        deviceAddress,
                        rssi,
                        retryCount + 1
                    )
                }, retryDelayMs)
            } else {
                Log.e(tag, "Flutter engine not ready after $maxRetries retries")
            }
            return
        }

        try {
            val methodChannel =
                MethodChannel(engine.dartExecutor.binaryMessenger, MainActivity.MESH_CHANNEL)

            if (payloadBase64 != null &&
                payloadBase64.isNotEmpty() &&
                methodName == "bleWakeUpTriggered"
            ) {
                val arguments = mapOf(
                    "payload" to payloadBase64,
                    "device_address" to (deviceAddress ?: ""),
                    "rssi" to rssi
                )
                methodChannel.invokeMethod("blePayloadReceived", arguments)
                Log.d(tag, "Sent BLE payload to Flutter, device=$deviceAddress, rssi=$rssi")
            } else {
                methodChannel.invokeMethod(methodName, null)
                Log.d(tag, "Sent $methodName to Flutter")
            }
        } catch (e: Exception) {
            Log.e(tag, "Error sending to Flutter: ${e.message}", e)
        }
    }
}
