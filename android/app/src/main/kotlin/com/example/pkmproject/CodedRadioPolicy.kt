package id.ac.usu.resqmesh

object CodedRadioPolicy {
    const val CODED = "coded"
    const val S8_REQUIRED = "coded_s8_required"
    const val INTERVAL_UNITS = 400 // 0.625 ms units; independent of scheduler/burst.
    const val TX_POWER_DBM = 1 // AdvertisingSetParameters.TX_POWER_HIGH; controller reports actual power.
    const val SCAN_REPORT_DELAY_MS = 0L
    fun codingEvidence(): Map<String, Any> = mapOf(
        "coding_selection_support" to "unsupported",
        "s8_requirement_accepted" to false,
        "on_air_coding_verified" to false,
        "coding_actual" to "UNKNOWN",
        "on_air_coding_status" to "UNVERIFIED")
    fun rejection(sdk: Int, bluetooth: Boolean, permission: Boolean,
                  advertiser: Boolean, coded: Boolean, extended: Boolean, mode: String): String? = when {
        mode != CODED && mode != S8_REQUIRED -> "INVALID_RADIO_MODE"
        sdk < 26 -> "SDK_UNSUPPORTED"
        !permission -> "MISSING_PERMISSION"
        !bluetooth -> "BLUETOOTH_UNAVAILABLE"
        !advertiser -> "ADVERTISER_UNAVAILABLE"
        !coded -> "CODED_PHY_UNSUPPORTED"
        !extended -> "EXTENDED_ADVERTISING_UNSUPPORTED"
        mode == S8_REQUIRED -> "S8_SELECTION_UNSUPPORTED"
        else -> null
    }
}

internal class AdvertisingLifecycle {
    var generation = 0L
        private set
    var starting = false
        private set
    fun begin(): Long { generation++; starting = true; return generation }
    fun finish(token: Long): Boolean {
        if (token != generation || !starting) return false
        starting = false
        return true
    }
    fun cancel() { generation++; starting = false }
}
