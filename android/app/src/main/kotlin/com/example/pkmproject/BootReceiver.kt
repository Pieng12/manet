package com.example.pkmproject

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

        if (!NativeBlePermissions.hasRequiredRuntimePermissions(appContext)) {
            Log.w("BootReceiver", "Permissions missing. Mesh service start deferred.")
            return
        }

        val serviceIntent = Intent(appContext, MeshBackgroundService::class.java)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                appContext.startForegroundService(serviceIntent)
            } else {
                appContext.startService(serviceIntent)
            }
            Log.d("BootReceiver", "Mesh background service started after boot")
        } catch (e: Exception) {
            Log.e("BootReceiver", "Error starting service: ${e.message}", e)
        }
    }
}
