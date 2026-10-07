package id.ac.usu.resqmesh

import android.content.Context

internal object ResearchParticipation {
    private const val PREFS = "resqmesh_participation"
    fun rxEnabled(context: Context) = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean("rx", true)
    fun txEnabled(context: Context) = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean("tx", true)
    fun set(context: Context, enabled: Boolean, rxOnly: Boolean): Map<String, Any?> {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val edit = prefs.edit().putBoolean("rx", enabled)
        if (!rxOnly) edit.putBoolean("tx", enabled)
        if (!edit.commit()) return mapOf("ok" to false, "error" to "PERSIST_FAILED")
        if (!enabled && !rxOnly) NativeBleAdvertiser.stopAdvertising()
        val success = if (enabled) NativeBleManager.startBleScan(context) else NativeBleManager.stopBleScan(context)
        return mapOf("ok" to success, "confirmed_enabled" to enabled, "rx_enabled" to rxEnabled(context), "tx_enabled" to txEnabled(context))
    }
}
