package id.ac.usu.resqmesh

import android.content.Context
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
            Log.w(TAG, "Permissions missing; BLE inbox recovery deferred")
            return Result.retry()
        }

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

    companion object {
        private const val TAG = "NativeBleInboxWorker"
        private const val WORK_NAME = "resqmeshNativeBleInboxRecovery"

        fun enqueue(context: Context) {
            val request = OneTimeWorkRequestBuilder<NativeBleInboxWorker>()
                .setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
                .build()
            WorkManager.getInstance(context.applicationContext)
                .enqueueUniqueWork(WORK_NAME, ExistingWorkPolicy.KEEP, request)
        }
    }
}
