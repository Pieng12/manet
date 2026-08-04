package id.ac.usu.resqmesh

import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log
import androidx.work.CoroutineWorker
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.OutOfQuotaPolicy
import androidx.work.WorkManager
import androidx.work.WorkerParameters

class NativeBleInboxWorker(
    appContext: Context,
    workerParams: WorkerParameters
) : CoroutineWorker(appContext, workerParams) {
    override suspend fun doWork(): Result {
        if (!NativeBlePermissions.hasRequiredRuntimePermissions(applicationContext)) {
            Log.w(TAG, "Permissions missing; BLE inbox recovery deferred")
            return Result.retry()
        }

        val intent = Intent(applicationContext, MeshBackgroundService::class.java).apply {
            action = MeshBackgroundService.NATIVE_INBOX_RECOVERY_ACTION
        }
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                applicationContext.startForegroundService(intent)
            } else {
                applicationContext.startService(intent)
            }
            Log.i(TAG, "BLE inbox recovery service requested")
            Result.success()
        } catch (e: SecurityException) {
            Log.e(TAG, "BLE inbox recovery rejected: ${e.message}", e)
            Result.retry()
        } catch (e: IllegalStateException) {
            Log.e(TAG, "BLE inbox recovery deferred: ${e.message}", e)
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
