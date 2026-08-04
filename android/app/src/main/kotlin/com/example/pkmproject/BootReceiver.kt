package id.ac.usu.resqmesh

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context?, intent: Intent?) {
        val appContext = context ?: return
        val action = intent?.action ?: return

        if (action != Intent.ACTION_BOOT_COMPLETED &&
            action != "android.intent.action.QUICKBOOT_POWERON"
        ) {
            return
        }

        val relayModeEnabled = appContext
            .getSharedPreferences("resqmesh_service_state", Context.MODE_PRIVATE)
            .getBoolean("relay_mode_enabled", true)
        if (!relayModeEnabled) {
            Log.i("BootReceiver", "Relay mode disabled. Boot recovery skipped.")
            return
        }

        if (!NativeBlePermissions.hasRequiredRuntimePermissions(appContext)) {
            Log.w("BootReceiver", "Permissions missing. Mesh service start deferred.")
            NativeBleInboxWorker.enqueue(appContext)
            return
        }

        val serviceIntent = Intent(appContext, MeshBackgroundService::class.java).apply {
            this.action = MeshBackgroundService.BOOT_RECOVERY_ACTION
        }
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                appContext.startForegroundService(serviceIntent)
            } else {
                appContext.startService(serviceIntent)
            }
            Log.d("BootReceiver", "Mesh background service started after boot")
        } catch (e: SecurityException) {
            NativeBleInboxWorker.enqueue(appContext)
            Log.e("BootReceiver", "Boot recovery rejected by security policy", e)
        } catch (e: IllegalStateException) {
            NativeBleInboxWorker.enqueue(appContext)
            Log.e("BootReceiver", "Boot recovery deferred by OS state", e)
        } catch (e: Exception) {
            NativeBleInboxWorker.enqueue(appContext)
            Log.e("BootReceiver", "Error starting service: ${e.message}", e)
        }
    }
}
