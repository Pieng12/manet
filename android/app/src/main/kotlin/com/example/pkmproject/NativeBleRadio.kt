package id.ac.usu.resqmesh

import android.bluetooth.BluetoothManager
import android.content.Context
import android.os.Build

object NativeBleRadio {
    private const val PREFS = "resqmesh_research_config"
    private const val KEY = "radio_mode"
    var configured = false
    var actualTxPower: Int? = null
    var lastError: String? = null
    fun mode(context: Context): String = context.getSharedPreferences(PREFS, 0)
        .getString(KEY, CodedRadioPolicy.CODED) ?: CodedRadioPolicy.CODED
    fun configure(context: Context, mode: String): Map<String, Any?> {
        require(mode == CodedRadioPolicy.CODED || mode == CodedRadioPolicy.S8_REQUIRED)
        NativeBleAdvertiser.stopAdvertising()
        context.getSharedPreferences(PREFS, 0).edit().putString(KEY, mode).apply()
        configured = false; actualTxPower = null
        lastError = rejection(context)
        return statusMap(context)
    }
    fun rejection(context: Context): String? {
        val adapter = (context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager).adapter
        return try {
            val enabled = adapter?.isEnabled == true
            CodedRadioPolicy.rejection(Build.VERSION.SDK_INT, enabled,
                NativeBlePermissions.hasAdvertisePermission(context),
                enabled && adapter?.bluetoothLeAdvertiser != null,
                Build.VERSION.SDK_INT >= 26 && adapter?.isLeCodedPhySupported == true,
                Build.VERSION.SDK_INT >= 26 && adapter?.isLeExtendedAdvertisingSupported == true, mode(context))
        } catch (_: SecurityException) { "MISSING_PERMISSION" }
    }
    fun statusMap(context: Context): Map<String, Any?> {
        val error = rejection(context)
        return mapOf(
            "requested_mode" to mode(context),
            "configured_mode" to if (configured && error == null) CodedRadioPolicy.CODED else null,
            "ready" to (error == null),
            "primary_phy" to "coded", "secondary_phy" to "coded", "scan_phy" to "coded",
            "legacy" to false, "connectable" to false, "scannable" to false,
            "coding_requested" to if (mode(context) == CodedRadioPolicy.S8_REQUIRED) "require_s8" else "unspecified",
            "coding_selection_support" to "unsupported", "s8_requirement_accepted" to false,
            "on_air_coding_verified" to false,
            "tx_power_requested_dbm" to CodedRadioPolicy.TX_POWER_DBM,
            "tx_power_actual_dbm" to actualTxPower,
            "advertising_interval_units" to CodedRadioPolicy.INTERVAL_UNITS,
            "advertising_interval_ms" to 250, "last_error" to (error ?: lastError))
    }
}
