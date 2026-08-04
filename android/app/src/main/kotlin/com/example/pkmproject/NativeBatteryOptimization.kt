package com.example.pkmproject

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import android.util.Log

object NativeBatteryOptimization {
    private const val TAG = "NativeBatteryOptimization"

    fun isIgnoring(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true

        return try {
            val powerManager = context.getSystemService(Context.POWER_SERVICE) as PowerManager
            powerManager.isIgnoringBatteryOptimizations(context.packageName)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to read battery optimization state: ${e.message}", e)
            false
        }
    }

    fun requestExemption(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        if (isIgnoring(context)) return true

        return try {
            val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                data = Uri.parse("package:${context.packageName}")
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            context.startActivity(intent)
            Log.d(TAG, "Battery optimization exemption request opened")
            false
        } catch (e: Exception) {
            Log.e(TAG, "Error requesting battery optimization exemption: ${e.message}", e)
            false
        }
    }
}
