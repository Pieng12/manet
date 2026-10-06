package id.ac.usu.resqmesh

import android.app.Activity
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.content.Context
import android.content.Intent
import android.util.Log

object NativeBluetoothEnableRequest {
    fun decision(adapterAvailable: Boolean, permitted: Boolean, enabled: Boolean): String = when {
        !adapterAvailable -> "unavailable"
        !permitted -> "permission_required"
        enabled -> "already_enabled"
        else -> "request_consent"
    }

    fun request(activity: Activity): Map<String, Any?> {
        return try {
            val adapter = (activity.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)?.adapter
            val permitted = NativeBlePermissions.hasConnectPermission(activity)
            val state = decision(adapter != null, permitted, permitted && adapter?.isEnabled == true)
            if (state != "request_consent") return mapOf("state" to state)
            // Opening the system dialog is not evidence that Bluetooth is enabled.
            activity.startActivity(Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE))
            mapOf("state" to "requested")
        } catch (error: Exception) {
            Log.w("NativeBluetoothEnable", "Bluetooth consent request failed", error)
            mapOf("state" to "failed", "error" to error.message)
        }
    }
}
