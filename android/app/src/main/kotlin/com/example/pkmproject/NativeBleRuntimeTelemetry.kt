package id.ac.usu.resqmesh

object NativeBleRuntimeTelemetry {
    fun advertisingStatusMap(
        rawStatus: String,
        rawActive: Boolean,
        rawErrorCode: String?,
        connectable: Boolean,
        debugVisible: Boolean,
        bluetoothEnabled: Boolean,
        advertiserAvailable: Boolean
    ): Map<String, Any?> {
        val effectiveActive = bluetoothEnabled && advertiserAvailable && rawActive
        val effectiveStatus = when {
            effectiveActive -> rawStatus
            !bluetoothEnabled && rawActive -> "bluetooth_disabled"
            !advertiserAvailable && rawActive -> "advertiser_unavailable"
            else -> rawStatus
        }
        val effectiveError = when {
            !bluetoothEnabled && rawActive -> rawErrorCode ?: "BLUETOOTH_DISABLED"
            !advertiserAvailable && rawActive -> rawErrorCode ?: "ADVERTISER_UNAVAILABLE"
            else -> rawErrorCode
        }

        return mapOf(
            "status" to effectiveStatus,
            "active" to effectiveActive,
            "errorCode" to effectiveError,
            "connectable" to connectable,
            "debugVisible" to debugVisible
        )
    }
}
