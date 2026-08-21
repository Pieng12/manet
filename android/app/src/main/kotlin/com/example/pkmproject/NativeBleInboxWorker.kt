package id.ac.usu.resqmesh

import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugins.GeneratedPluginRegistrant
import androidx.work.CoroutineWorker
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.OutOfQuotaPolicy
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

class NativeBleInboxWorker(
    appContext: Context,
    workerParams: WorkerParameters
) : CoroutineWorker(appContext, workerParams) {
    override suspend fun doWork(): Result {
        if (!NativeBlePermissions.hasRequiredRuntimePermissions(applicationContext)) {
            NativeBleInbox.markPermissionBlocked(applicationContext)
            Log.w(TAG, "Permissions missing; BLE inbox recovery deferred")
            return Result.success()
        }
        NativeBleInbox.clearPermissionBlocked(applicationContext)

        val completed = CountDownLatch(1)
        val success = AtomicBoolean(false)
        val engineRef = arrayOfNulls<FlutterEngine>(1)

        Handler(Looper.getMainLooper()).post {
            try {
                val loader = FlutterInjector.instance().flutterLoader()
                loader.startInitialization(applicationContext)
                loader.ensureInitializationComplete(applicationContext, null)

                val engine = FlutterEngine(applicationContext)
                engineRef[0] = engine
                GeneratedPluginRegistrant.registerWith(engine)
                MethodChannel(engine.dartExecutor.binaryMessenger, MainActivity.MESH_CHANNEL)
                    .setMethodCallHandler { call, result ->
                        when (call.method) {
                            "getPendingBleInbox" -> {
                                result.success(NativeBleInbox.pending(applicationContext))
                            }
                            "acknowledgeBleInboxItem" -> {
                                val id = call.argument<String>("id")
                                result.success(
                                    id != null && NativeBleInbox.acknowledge(applicationContext, id)
                                )
                            }
                            "failBleInboxItem" -> {
                                val id = call.argument<String>("id")
                                result.success(
                                    id != null && NativeBleInbox.fail(applicationContext, id)
                                )
                            }
                            "startNativeBleAdvertising" -> {
                                startNativeBleAdvertising(call, result)
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
                                    result.success(
                                        NativeBleAdvertiser.isCurrentlyAdvertising(
                                            applicationContext
                                        )
                                    )
                                } else {
                                    result.success(false)
                                }
                            }
                            "getNativeBleAdvertisingStatus" -> {
                                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                                    result.success(
                                        NativeBleAdvertiser.statusMap(applicationContext)
                                    )
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
                            "setHasPendingRelayWork" -> {
                                servicePrefs(applicationContext).edit()
                                    .putBoolean(
                                        KEY_HAS_PENDING_RELAY_WORK,
                                        call.argument<Boolean>("hasPending") == true
                                    )
                                    .apply()
                                result.success(true)
                            }
                            "hasPendingRelayWork" -> {
                                result.success(
                                    servicePrefs(applicationContext)
                                        .getBoolean(KEY_HAS_PENDING_RELAY_WORK, false) ||
                                        NativeBleInbox.pendingCount(applicationContext) > 0
                                )
                            }
                            "resumePendingNativeBleInbox" -> {
                                result.success(enqueueIfPendingAndPermitted(applicationContext))
                            }
                            "clearNativeBleInboxPermissionBlocked" -> {
                                NativeBleInbox.clearPermissionBlocked(applicationContext)
                                result.success(true)
                            }
                            "nativeBleInboxWorkerComplete" -> {
                                success.set(call.argument<Boolean>("success") == true)
                                result.success(true)
                                completed.countDown()
                            }
                            else -> result.notImplemented()
                        }
                    }

                engine.dartExecutor.executeDartEntrypoint(
                    DartExecutor.DartEntrypoint(
                        loader.findAppBundlePath(),
                        "nativeBleInboxWorkerMain"
                    )
                )
                Log.i(TAG, "Headless Native BLE inbox processor started")
            } catch (e: Exception) {
                Log.e(TAG, "Failed to start headless inbox processor: ${e.message}", e)
                completed.countDown()
            }
        }

        val finished = completed.await(2, TimeUnit.MINUTES)
        Handler(Looper.getMainLooper()).post {
            engineRef[0]?.destroy()
        }

        return if (finished && success.get()) {
            Log.i(TAG, "Native BLE inbox worker completed")
            Result.success()
        } else {
            Log.w(TAG, "Native BLE inbox worker retry scheduled; finished=$finished success=${success.get()}")
            Result.retry()
        }
    }

    private fun startNativeBleAdvertising(
        call: io.flutter.plugin.common.MethodCall,
        result: MethodChannel.Result
    ) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.LOLLIPOP) {
            result.success(false)
            return
        }
        val payloadBase64 = call.argument<String>("payload")
        val payload = if (payloadBase64 != null) {
            android.util.Base64.decode(payloadBase64, android.util.Base64.NO_WRAP)
        } else {
            null
        }
        val debugVisible = call.argument<Boolean>("debugVisible") ?: false
        val connectable = call.argument<Boolean>("connectable") ?: false
        NativeBleAdvertiser.startAdvertising(
            applicationContext,
            payload,
            debugVisible,
            connectable
        ) { success, _, _ ->
            result.success(success)
        }
    }

    companion object {
        private const val TAG = "NativeBleInboxWorker"
        private const val WORK_NAME = "resqmeshNativeBleInboxRecovery"
        private const val SERVICE_PREFS = "resqmesh_service_state"
        private const val KEY_HAS_PENDING_RELAY_WORK = "has_pending_relay_work"

        fun enqueue(context: Context) {
            val request = OneTimeWorkRequestBuilder<NativeBleInboxWorker>()
                .setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
                .build()
            WorkManager.getInstance(context.applicationContext)
                .enqueueUniqueWork(WORK_NAME, ExistingWorkPolicy.KEEP, request)
        }

        fun enqueueIfPendingAndPermitted(context: Context): Boolean {
            val appContext = context.applicationContext
            if (!NativeBlePermissions.hasRequiredRuntimePermissions(appContext)) {
                NativeBleInbox.markPermissionBlocked(appContext)
                return false
            }
            NativeBleInbox.clearPermissionBlocked(appContext)
            if (NativeBleInbox.pendingCount(appContext) <= 0) return false
            enqueue(appContext)
            return true
        }

        private fun servicePrefs(context: Context) =
            context.getSharedPreferences(SERVICE_PREFS, Context.MODE_PRIVATE)
    }
}
