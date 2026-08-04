package id.ac.usu.resqmesh

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
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
    private var bleStateReceiverRegistered = false

    private val bleStateReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action != BluetoothAdapter.ACTION_STATE_CHANGED) return
            when (intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, BluetoothAdapter.ERROR)) {
                BluetoothAdapter.STATE_OFF, BluetoothAdapter.STATE_TURNING_OFF -> {
                    Log.w(tag, "Bluetooth disabled; stopping scan and advertiser, queue preserved")
                    NativeBleManager.stopBleScan(this@MeshBackgroundService)
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                        NativeBleAdvertiser.stopAdvertising()
                    }
                }
                BluetoothAdapter.STATE_ON -> {
                    Log.i(tag, "Bluetooth re-enabled; restarting scan and scheduler recovery")
                    NativeBleManager.startBleScan(this@MeshBackgroundService)
                    sendWakeUpToFlutter("recoverPersistedRelayState", null, null, 0)
                }
            }
        }
    }

    companion object {
        const val DART_ENTRYPOINT = "backgroundServiceMain"
        const val CONNECTIVITY_CHANGED_ACTION = "id.ac.usu.resqmesh.CONNECTIVITY_CHANGED"
        const val BOOT_RECOVERY_ACTION = "id.ac.usu.resqmesh.BOOT_RECOVERY"
        const val TASK_REMOVED_RECOVERY_ACTION = "id.ac.usu.resqmesh.TASK_REMOVED_RECOVERY"
        const val SCHEDULER_TICK_ACTION = "id.ac.usu.resqmesh.SCHEDULER_TICK"
        const val NATIVE_INBOX_RECOVERY_ACTION = "id.ac.usu.resqmesh.NATIVE_INBOX_RECOVERY"
        private const val PREFS = "resqmesh_service_state"
        private const val KEY_RELAY_MODE_ENABLED = "relay_mode_enabled"
        private const val KEY_HAS_PENDING_RELAY_WORK = "has_pending_relay_work"
        private const val KEY_RECOVERY_RUNNING = "recovery_running"
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
        registerBluetoothStateReceiver()

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
                    val inboxId = intent.getStringExtra("inbox_id")
                    val deviceAddress = intent.getStringExtra("device_address")
                    val rssi = intent.getIntExtra("rssi", 0)
                    sendPayloadToFlutter(payloadBase64, deviceAddress, rssi, inboxId = inboxId)
                }
                CONNECTIVITY_CHANGED_ACTION -> {
                    sendWakeUpToFlutter("connectivityChanged", null, null, 0)
                }
                BOOT_RECOVERY_ACTION, TASK_REMOVED_RECOVERY_ACTION, NATIVE_INBOX_RECOVERY_ACTION -> {
                    setRecoveryRunning(true)
                    NativeBleManager.startBleScan(this)
                    sendWakeUpToFlutter("recoverPersistedRelayState", null, null, 0)
                    setRecoveryRunning(false)
                }
                SCHEDULER_TICK_ACTION -> {
                    sendWakeUpToFlutter("schedulerTick", null, null, 0)
                }
            }
        }

        return START_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        super.onTaskRemoved(rootIntent)
        Log.d(tag, "onTaskRemoved called. Keeping relay state and scan recoverable.")
        NativeBleManager.startBleScan(this)
        sendWakeUpToFlutter("recoverPersistedRelayState", null, null, 0)
        resetIdleStop()
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
        unregisterBluetoothStateReceiver()
        flutterEngine?.destroy()
        flutterEngine = null
        serviceStarted = false
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun buildNotification(): Notification {
        return NotificationCompat.Builder(this, channelId)
            .setContentTitle("ResQMesh aktif")
            .setContentText("Memantau dan meneruskan sinyal darurat BLE")
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
                description = "Background service for ResQMesh BLE relay"
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
                    "hasPendingRelayWork" -> {
                        result.success(hasPendingRelayWork())
                    }
                    "setHasPendingRelayWork" -> {
                        setHasPendingRelayWork(call.argument<Boolean>("hasPending") == true)
                        result.success(true)
                    }
                    "setRelayModeEnabled" -> {
                        setRelayModeEnabled(call.argument<Boolean>("enabled") != false)
                        result.success(true)
                    }
                    "getBleCapabilities" -> {
                        result.success(bleCapabilities())
                    }
                    "startBleWakeUpScan" -> {
                        val scanAllAdvertisements =
                            call.argument<Boolean>("scanAllAdvertisements") ?: false
                        result.success(NativeBleManager.startBleScan(this, scanAllAdvertisements))
                    }
                    "stopBleWakeUpScan" -> {
                        result.success(NativeBleManager.stopBleScan(this))
                    }
                    "startBackgroundService" -> {
                        result.success(true)
                    }
                    "requestSchedulerTick" -> {
                        sendWakeUpToFlutter("schedulerTick", null, null, 0)
                        result.success(true)
                    }
                    "requestIgnoreBatteryOptimizations" -> {
                        result.success(NativeBatteryOptimization.requestExemption(this))
                    }
                    "isIgnoringBatteryOptimizations" -> {
                        result.success(NativeBatteryOptimization.isIgnoring(this))
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
                NativeBleAdvertiser.startAdvertising(this, null, callback = null)
            }

            dutyCycleHandler.postDelayed(dutyCycleRunnable, 30000)
        }
    }

    private fun setupIdleStop() {
        idleStopRunnable = Runnable {
            if (shouldKeepAliveForRelayWork()) {
                updateNotification("Menunggu jadwal relay berikutnya")
                Log.d(tag, "Keeping service alive for pending relay work")
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
        retryCount: Int = 0,
        inboxId: String? = null
    ) {
        sendWakeUpToFlutter(
            "bleWakeUpTriggered",
            payloadBase64,
            deviceAddress,
            rssi,
            retryCount,
            inboxId
        )
    }

    private fun sendWakeUpToFlutter(
        methodName: String,
        payloadBase64: String?,
        deviceAddress: String?,
        rssi: Int,
        retryCount: Int = 0,
        inboxId: String? = null
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
                        retryCount + 1,
                        inboxId
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
                    "inbox_id" to (inboxId ?: ""),
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

    private fun servicePrefs() = getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private fun setRelayModeEnabled(enabled: Boolean) {
        servicePrefs().edit().putBoolean(KEY_RELAY_MODE_ENABLED, enabled).apply()
    }

    private fun setHasPendingRelayWork(hasPending: Boolean) {
        servicePrefs().edit().putBoolean(KEY_HAS_PENDING_RELAY_WORK, hasPending).apply()
    }

    private fun setRecoveryRunning(running: Boolean) {
        servicePrefs().edit().putBoolean(KEY_RECOVERY_RUNNING, running).apply()
    }

    private fun hasPendingRelayWork(): Boolean {
        return servicePrefs().getBoolean(KEY_HAS_PENDING_RELAY_WORK, false) ||
            NativeBleInbox.pendingCount(this) > 0
    }

    private fun shouldKeepAliveForRelayWork(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP &&
            NativeBleAdvertiser.isCurrentlyAdvertising()
        ) {
            return true
        }
        val prefs = servicePrefs()
        return prefs.getBoolean(KEY_RELAY_MODE_ENABLED, true) ||
            prefs.getBoolean(KEY_HAS_PENDING_RELAY_WORK, false) ||
            prefs.getBoolean(KEY_RECOVERY_RUNNING, false) ||
            NativeBleInbox.pendingCount(this) > 0
    }

    private fun updateNotification(text: String) {
        val manager = getSystemService(NotificationManager::class.java)
        manager.notify(notificationId, buildNotification(text))
    }

    private fun buildNotification(text: String): Notification {
        return NotificationCompat.Builder(this, channelId)
            .setContentTitle("ResQMesh aktif")
            .setContentText(text)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setShowWhen(false)
            .build()
    }

    private fun bleCapabilities(): Map<String, Any?> {
        val bluetoothManager =
            getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
        val adapter = bluetoothManager.adapter
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
            "foregroundServiceActive" to serviceStarted,
            "pendingNativeInbox" to NativeBleInbox.pendingCount(this),
            "relayModeEnabled" to servicePrefs().getBoolean(KEY_RELAY_MODE_ENABLED, true)
        )
    }

    private fun registerBluetoothStateReceiver() {
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
            Log.e(tag, "Failed to register Bluetooth state receiver: ${e.message}", e)
        }
    }

    private fun unregisterBluetoothStateReceiver() {
        if (!bleStateReceiverRegistered) return
        try {
            unregisterReceiver(bleStateReceiver)
        } catch (e: Exception) {
            Log.e(tag, "Failed to unregister Bluetooth state receiver: ${e.message}", e)
        } finally {
            bleStateReceiverRegistered = false
        }
    }
}
