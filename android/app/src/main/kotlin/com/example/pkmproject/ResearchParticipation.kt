package id.ac.usu.resqmesh

import android.content.Context

internal object ResearchParticipation {
    private const val PREFS = "resqmesh_participation"
    fun rxEnabled(context: Context) = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean("rx", true)
    fun txEnabled(context: Context) = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean("tx", true)
    internal fun reactivates(enabled: Boolean, rxOnly: Boolean, previousRx: Boolean, previousTx: Boolean) =
        enabled && (!previousRx || (!rxOnly && !previousTx))
    fun set(context: Context, enabled: Boolean, rxOnly: Boolean): Map<String, Any?> {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val previousRx = rxEnabled(context)
        val previousTx = txEnabled(context)
        val reactivated = reactivates(enabled, rxOnly, previousRx, previousTx)
        val edit = prefs.edit().putBoolean("rx", enabled)
        if (!rxOnly) edit.putBoolean("tx", enabled)
        if (!edit.commit()) return mapOf("ok" to false, "error" to "PERSIST_FAILED")
        if (!enabled && !rxOnly) NativeBleAdvertiser.stopAdvertising()
        val success = if (enabled) NativeBleManager.startBleScan(context) else NativeBleManager.stopBleScan(context)
        if (!success && enabled) {
            prefs.edit().putBoolean("rx", previousRx).putBoolean("tx", previousTx).commit()
        }
        return mapOf("ok" to success, "confirmed_enabled" to if (success) enabled else null,
            "reactivated" to (success && reactivated), "rx_enabled" to rxEnabled(context), "tx_enabled" to txEnabled(context))
    }
}
