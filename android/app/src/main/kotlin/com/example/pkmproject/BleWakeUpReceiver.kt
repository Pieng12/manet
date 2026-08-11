package id.ac.usu.resqmesh

import android.bluetooth.le.BluetoothLeScanner
import android.bluetooth.le.ScanResult
import android.app.ForegroundServiceStartNotAllowedException
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.SystemClock
import android.util.Log

class BleWakeUpReceiver : BroadcastReceiver() {

    companion object {
        private const val TAG = "BleWakeUpReceiver"
        private const val DEDUPLICATION_WINDOW_MS = 5000L

        private val lastProcessedPayloads = mutableMapOf<String, Long>()
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != NativeBleManager.BLE_WAKE_UP_ACTION) return

        val results = scanResultsFrom(intent)
        if (results.isEmpty()) return

        for (scanResult in results) {
            val scanRecord = scanResult.scanRecord ?: continue
            val manufacturerData = scanRecord.manufacturerSpecificData
            val id = when {
                manufacturerData?.get(NativeBleConfig.MANUFACTURER_ID) != null ->
                    NativeBleConfig.MANUFACTURER_ID
                manufacturerData?.get(NativeBleConfig.SIMULATION_MANUFACTURER_ID) != null ->
                    NativeBleConfig.SIMULATION_MANUFACTURER_ID
                else -> -1
            }

            val data = if (id != -1) {
                manufacturerData?.get(id)
            } else {
                scanRecord.bytes
            } ?: continue
            val hex = data.joinToString("") { String.format("%02X", it) }
            val cacheKey = hex
            val currentTime = System.currentTimeMillis()
            val lastProcessed = lastProcessedPayloads[cacheKey] ?: 0L

            if (currentTime - lastProcessed <= DEDUPLICATION_WINDOW_MS) {
                continue
            }

            lastProcessedPayloads[cacheKey] = currentTime
            if (lastProcessedPayloads.size > 50) {
                lastProcessedPayloads.entries.removeIf {
                    currentTime - it.value > DEDUPLICATION_WINDOW_MS
                }
            }

            val idLabel = if (id == -1) "raw" else "0x${String.format("%04X", id)}"
            Log.i(TAG, "ResQMesh BLE candidate. ID=$idLabel, RSSI=${scanResult.rssi}")
            processPotentialPayload(context, data, safeDeviceAddress(scanResult), scanResult.rssi)
        }
    }

    private fun scanResultsFrom(intent: Intent): List<ScanResult> {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableArrayListExtra(
                BluetoothLeScanner.EXTRA_LIST_SCAN_RESULT,
                ScanResult::class.java
            ) ?: emptyList()
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableArrayListExtra<ScanResult>(
                BluetoothLeScanner.EXTRA_LIST_SCAN_RESULT
            ) ?: emptyList()
        }
    }

    private fun safeDeviceAddress(scanResult: ScanResult): String {
        return try {
            scanResult.device?.address ?: "unknown"
        } catch (_: SecurityException) {
            "unknown"
        }
    }

    private fun processPotentialPayload(
        context: Context,
        rawPayload: ByteArray,
        deviceAddress: String,
        rssi: Int
    ) {
        var startIndex = -1
        for (i in 0 until rawPayload.size - 1) {
            if (rawPayload[i] == 0x52.toByte() && rawPayload[i + 1] == 0x4D.toByte()) {
                startIndex = i
                break
            }
        }

        if (startIndex == -1 ||
            rawPayload.size < startIndex + NativeBleConfig.PROTOCOL_LENGTH_BYTES
        ) {
            return
        }

        val payload = rawPayload.sliceArray(
            startIndex until startIndex + NativeBleConfig.PROTOCOL_LENGTH_BYTES
        )
        val payloadBase64 = android.util.Base64.encodeToString(
            payload,
            android.util.Base64.NO_WRAP
        )
        val receivedAt = System.currentTimeMillis()
        val receivedElapsedRealtimeMs = SystemClock.elapsedRealtime()
        val storeResult = NativeBleInbox.store(
            context,
            payload,
            deviceAddress,
            rssi,
            receivedAt,
            receivedElapsedRealtimeMs
        )
        if (!storeResult.shouldScheduleWorker) {
            Log.i(TAG, "Exact BLE payload already processed; worker recovery not scheduled")
            return
        }
        val inboxId = storeResult.id

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && !MeshBackgroundService.serviceStarted) {
            val pendingResult = goAsync()
            try {
                NativeBleInboxWorker.enqueue(context)
                Log.i(TAG, "Stored BLE payload and deferred service start on Android 12+")
            } finally {
                pendingResult.finish()
            }
            return
        }

        val serviceIntent = Intent(context, MeshBackgroundService::class.java).apply {
            action = NativeBleManager.BLE_WAKE_UP_ACTION
            putExtra("payload", payloadBase64)
            putExtra("inbox_id", inboxId)
            putExtra("device_address", deviceAddress)
            putExtra("rssi", rssi)
            putExtra("received_at", receivedAt)
            putExtra("received_elapsed_realtime_ms", receivedElapsedRealtimeMs)
        }

        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(serviceIntent)
            } else {
                context.startService(serviceIntent)
            }
            Log.i(TAG, "Wake-up service started for valid ResQMesh payload")
        } catch (e: ForegroundServiceStartNotAllowedException) {
            NativeBleInboxWorker.enqueue(context)
            Log.e(TAG, "Foreground service start rejected; inbox worker scheduled", e)
        } catch (e: SecurityException) {
            NativeBleInboxWorker.enqueue(context)
            Log.e(TAG, "Foreground service start security failure; inbox worker scheduled", e)
        } catch (e: IllegalStateException) {
            NativeBleInboxWorker.enqueue(context)
            Log.e(TAG, "Foreground service start illegal state; inbox worker scheduled", e)
        } catch (e: Exception) {
            NativeBleInboxWorker.enqueue(context)
            Log.e(TAG, "Failed to start wake-up service: ${e.message}", e)
        }
    }
}
