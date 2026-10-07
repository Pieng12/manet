package id.ac.usu.resqmesh

import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertisingSet
import android.bluetooth.le.AdvertisingSetCallback
import android.bluetooth.le.AdvertisingSetParameters
import android.bluetooth.le.BluetoothLeAdvertiser
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log

object NativeBleAdvertiser {
    private var advertiser: BluetoothLeAdvertiser? = null
    private var activeCallback: AdvertisingSetCallback? = null
    private var pending: ((Boolean, String, String?) -> Unit)? = null
    private var payload: ByteArray? = null
    private var debugVisible = false
    private var status = "stopped"
    private var error: String? = null
    private val lifecycle = AdvertisingLifecycle()
    private val handler by lazy { Handler(Looper.getMainLooper()) }

    fun startAdvertising(context: Context, payload: ByteArray?,
                         debugVisible: Boolean = this.debugVisible, connectable: Boolean = false,
                         callback: ((Boolean, String, String?) -> Unit)? = null): Boolean {
        // UI, service and worker share this single advertising-set owner.
        val next = (payload ?: this.payload)?.copyOf()
        stopAdvertising()
        this.debugVisible = debugVisible
        val rejection = if (!ResearchParticipation.txEnabled(context)) "PARTICIPATION_DISABLED" else NativeBleRadio.rejection(context)
            ?: if (next == null || !NeighborTransport.validPayload(next)) "INVALID_PAYLOAD_LENGTH" else null
        if (rejection != null) {
            status = "failed"; error = rejection; NativeBleRadio.lastError = rejection
            callback?.invoke(false, status, error)
            return false
        }
        this.payload = next
        val adapter = (context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager).adapter
        if (next!!.size + 4 > adapter.leMaximumAdvertisingDataLength) {
            status = "failed"; error = "ADVERTISING_CAPACITY_EXCEEDED"
            callback?.invoke(false, status, error)
            return false
        }
        val owner = try {
            (context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager)
                .adapter?.bluetoothLeAdvertiser
        } catch (_: SecurityException) { null }
        if (owner == null) {
            status = "failed"; error = "ADVERTISER_UNAVAILABLE"
            NativeBleRadio.lastError = error
            callback?.invoke(false, status, error)
            return false
        }
        advertiser = owner
        val token = lifecycle.begin()
        status = "starting"; error = null; pending = callback
        val setCallback = object : AdvertisingSetCallback() {
            override fun onAdvertisingSetStarted(set: AdvertisingSet?, txPower: Int, result: Int) {
                if (!lifecycle.finish(token)) {
                    if (token == lifecycle.generation && status == "active") return
                    // Timed-out/cancelled sets can still start on the controller.
                    release(owner, this)
                    return
                }
                if (result == ADVERTISE_SUCCESS && set != null) {
                    NativeBleRadio.configured = true
                    NativeBleRadio.actualTxPower = txPower
                    complete(true, null)
                } else {
                    release(owner, this)
                    complete(false, "ADVERTISE_STATUS_$result")
                }
            }
            override fun onAdvertisingSetStopped(set: AdvertisingSet?) {
                if (token == lifecycle.generation && status == "active") status = "stopped"
            }
        }
        activeCallback = setCallback
        return try {
            val parameters = AdvertisingSetParameters.Builder()
                .setLegacyMode(false).setConnectable(false).setScannable(false)
                .setPrimaryPhy(BluetoothDevice.PHY_LE_CODED)
                .setSecondaryPhy(BluetoothDevice.PHY_LE_CODED)
                .setInterval(CodedRadioPolicy.INTERVAL_UNITS)
                .setTxPowerLevel(CodedRadioPolicy.TX_POWER_DBM).build()
            val data = AdvertiseData.Builder().setIncludeDeviceName(false)
                .setIncludeTxPowerLevel(false)
                .addManufacturerData(NativeBleConfig.MANUFACTURER_ID, next!!).build()
            handler.postDelayed({
                if (lifecycle.finish(token)) {
                    lifecycle.cancel()
                    release(owner, setCallback)
                    complete(false, "START_TIMEOUT")
                }
            }, 2500L)
            owner.startAdvertisingSet(parameters, data, null, null, null, setCallback, handler)
            true
        } catch (exception: Exception) {
            Log.e("NativeBleAdvertiser", "Extended advertising failed", exception)
            if (lifecycle.finish(token)) {
                lifecycle.cancel()
                release(owner, setCallback)
                complete(false, "START_EXCEPTION_${exception.javaClass.simpleName}")
            }
            false
        }
    }

    private fun complete(success: Boolean, reason: String?) {
        status = if (success) "active" else "failed"
        error = reason; NativeBleRadio.lastError = reason
        val callback = pending
        pending = null
        callback?.invoke(success, status, reason)
    }
    private fun release(owner: BluetoothLeAdvertiser?, callback: AdvertisingSetCallback) {
        try { owner?.stopAdvertisingSet(callback) }
        catch (exception: Exception) { Log.w("NativeBleAdvertiser", "Cannot release advertising set", exception) }
    }
    fun stopAdvertising() {
        lifecycle.cancel()
        val old = activeCallback
        activeCallback = null
        old?.let { release(advertiser, it) }
        val cancelled = pending
        pending = null
        status = "stopped"; error = null; payload = null
        cancelled?.invoke(false, "stopped", "START_CANCELLED")
    }
    fun isCurrentlyAdvertising() = status == "active"
    fun isCurrentlyAdvertising(context: Context) = statusMap(context)["active"] == true
    fun statusMap(): Map<String, Any?> = mapOf("status" to status,
        "active" to isCurrentlyAdvertising(), "errorCode" to error,
        "connectable" to false, "debugVisible" to debugVisible)
    fun statusMap(context: Context): Map<String, Any?> {
        val adapter = (context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager).adapter
        val enabled = adapter?.isEnabled == true
        return NativeBleRuntimeTelemetry.advertisingStatusMap(status, isCurrentlyAdvertising(),
            error, false, debugVisible, enabled, enabled && adapter?.bluetoothLeAdvertiser != null) +
            mapOf("radio" to NativeBleRadio.statusMap(context))
    }
}
