package id.ac.usu.resqmesh

import android.content.Context

object NativeBleConfig {
    const val RESQ_MESH_SERVICE_UUID_STRING = "000021FE-0000-1000-8000-00805F9B34FB"
    const val MANUFACTURER_ID = 0xFFFF
    const val SIMULATION_MANUFACTURER_ID = 0x0006
    const val PROTOCOL_LENGTH_BYTES = 17
    const val DEFAULT_RX_BURST_GAP_MS = 5000L
    private const val PREFS = "resqmesh_research_config"
    private const val KEY_RX_BURST_GAP_MS = "rx_burst_gap_ms"

    fun rxBurstGapMs(context: Context): Long =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getLong(KEY_RX_BURST_GAP_MS, DEFAULT_RX_BURST_GAP_MS)
            .coerceAtLeast(1L)

    fun setRxBurstGapMs(context: Context, value: Long) {
        require(value > 0L) { "rx_burst_gap_ms must be positive" }
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putLong(KEY_RX_BURST_GAP_MS, value)
            .apply()
    }
}
