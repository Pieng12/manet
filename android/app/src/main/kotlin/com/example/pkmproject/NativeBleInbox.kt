package id.ac.usu.resqmesh

import android.content.Context
import android.os.SystemClock
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.security.MessageDigest
import java.util.Base64

data class NativeBlePacketMetadata(
    val senderCrc: Long,
    val timestampCompact: Int,
    val status: Int,
    val isAck: Boolean,
    val fromServer: Boolean,
    val hop: Int
)

enum class NativeBleInboxStoreStatus {
    NEW_PENDING,
    EXISTING_PENDING,
    KNOWN_PROCESSED_DUPLICATE
}

data class NativeBleInboxStoreResult(
    val id: String,
    val observationId: String,
    val observerKey: String,
    val status: NativeBleInboxStoreStatus,
    val shouldScheduleWorker: Boolean
)

data class NativeBleInboxStoreMutation(
    val itemsJson: String,
    val result: NativeBleInboxStoreResult
)

object NativeBleInbox {
    private data class ObservationWindow(
        val observationId: String,
        val burstStartedAt: Long
    )

    private const val TAG = "NativeBleInbox"
    private const val PREFS = "resqmesh_native_ble_inbox"
    private const val KEY_ITEMS = "items_json"
    private const val KEY_PERMISSION_BLOCKED_AT = "permission_blocked_at"
    private const val STATE_PENDING = "pending"
    private const val STATE_PROCESSED = "processed"
    private const val STATE_FAILED = "failed"
    private const val CLEANUP_AFTER_MS = 14L * 24L * 60L * 60L * 1000L

    @Synchronized
    fun store(
        context: Context,
        payload: ByteArray,
        deviceAddress: String?,
        rssi: Int,
        receivedAt: Long = System.currentTimeMillis(),
        receivedElapsedRealtimeMs: Long = SystemClock.elapsedRealtime()
    ): NativeBleInboxStoreResult {
        cleanupProcessed(context, receivedAt)
        val payloadBase64 = Base64.getEncoder().encodeToString(payload)
        val payloadHash = exactPayloadHash(payload)
        val rxBurstGapMs = NativeBleConfig.rxBurstGapMs(context)
        val observerKey = observerKey(
            deviceAddress,
            receivedAt,
            receivedElapsedRealtimeMs,
            rxBurstGapMs
        )
        val metadata = protocolMetadata(payload)
        val items = readItems(context)
        val observation = observationWindow(
            items,
            payloadHash,
            observerKey,
            receivedAt,
            receivedElapsedRealtimeMs,
            rxBurstGapMs
        )
        val mutation = storeIntoItems(
            items = items,
            payloadBase64 = payloadBase64,
            observationId = observation.observationId,
            payloadHash = payloadHash,
            observerKey = observerKey,
            burstStartedAt = observation.burstStartedAt,
            metadata = metadata,
            deviceAddress = deviceAddress,
            rssi = rssi,
            receivedAt = receivedAt,
            receivedElapsedRealtimeMs = receivedElapsedRealtimeMs
        )
        writeItems(context, JSONArray(mutation.itemsJson))
        Log.i(TAG, "BLE inbox store status=${mutation.result.status} id=${mutation.result.id}")
        return mutation.result
    }

    @Synchronized
    fun pending(context: Context): List<Map<String, Any?>> {
        val items = readItems(context)
        val result = mutableListOf<Map<String, Any?>>()
        for (i in 0 until items.length()) {
            val item = items.getJSONObject(i)
            val state = item.optString("state")
            if (state != STATE_PENDING && state != STATE_FAILED) continue
            result.add(item.toMap())
        }
        return result
    }

    @Synchronized
    fun acknowledge(context: Context, id: String): Boolean {
        return updateItem(context, id) { item ->
            item.put("state", STATE_PROCESSED)
            item.put("processed_at", System.currentTimeMillis())
        }
    }

    @Synchronized
    fun fail(context: Context, id: String): Boolean {
        return updateItem(context, id) { item ->
            item.put("state", STATE_FAILED)
            item.put("attempt_count", item.optInt("attempt_count", 0) + 1)
        }
    }

    @Synchronized
    fun pendingCount(context: Context): Int {
        return pending(context).size
    }

    @Synchronized
    fun clear(context: Context) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .remove(KEY_ITEMS)
            .apply()
    }

    @Synchronized
    fun markPermissionBlocked(context: Context, blockedAt: Long = System.currentTimeMillis()) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putLong(KEY_PERMISSION_BLOCKED_AT, blockedAt)
            .apply()
    }

    @Synchronized
    fun clearPermissionBlocked(context: Context) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .remove(KEY_PERMISSION_BLOCKED_AT)
            .apply()
    }

    @Synchronized
    fun permissionBlockedAt(context: Context): Long {
        return context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getLong(KEY_PERMISSION_BLOCKED_AT, 0L)
    }

    fun storeForTest(
        rawItemsJson: String,
        payload: ByteArray,
        deviceAddress: String?,
        rssi: Int,
        receivedAt: Long,
        receivedElapsedRealtimeMs: Long = receivedAt,
        rxBurstGapMs: Long = NativeBleConfig.DEFAULT_RX_BURST_GAP_MS
    ): NativeBleInboxStoreMutation {
        val payloadBase64 = Base64.getEncoder().encodeToString(payload)
        val payloadHash = exactPayloadHash(payload)
        val observerKey = observerKey(
            deviceAddress,
            receivedAt,
            receivedElapsedRealtimeMs,
            rxBurstGapMs
        )
        val items = JSONArray(rawItemsJson)
        val observation = observationWindow(
            items,
            payloadHash,
            observerKey,
            receivedAt,
            receivedElapsedRealtimeMs,
            rxBurstGapMs
        )
        return storeIntoItems(
            items = items,
            payloadBase64 = payloadBase64,
            observationId = observation.observationId,
            payloadHash = payloadHash,
            observerKey = observerKey,
            burstStartedAt = observation.burstStartedAt,
            metadata = protocolMetadata(payload),
            deviceAddress = deviceAddress,
            rssi = rssi,
            receivedAt = receivedAt,
            receivedElapsedRealtimeMs = receivedElapsedRealtimeMs
        )
    }

    private fun storeIntoItems(
        items: JSONArray,
        payloadBase64: String,
        observationId: String,
        payloadHash: String,
        observerKey: String,
        burstStartedAt: Long,
        metadata: NativeBlePacketMetadata?,
        deviceAddress: String?,
        rssi: Int,
        receivedAt: Long,
        receivedElapsedRealtimeMs: Long
    ): NativeBleInboxStoreMutation {
        for (i in 0 until items.length()) {
            val item = items.getJSONObject(i)
            if (item.optString("observation_id", item.optString("id")) != observationId) continue

            val duplicateCount = item.optInt("duplicate_count", 0) + 1
            item.put("last_seen_at", receivedAt)
            item.put("last_seen_elapsed_realtime_ms", receivedElapsedRealtimeMs)
            item.put("last_rssi", rssi)
            item.put("duplicate_count", duplicateCount)

            if (item.optString("state") == STATE_PROCESSED) {
                return NativeBleInboxStoreMutation(
                    items.toString(),
                    NativeBleInboxStoreResult(
                        id = item.getString("id"),
                        observationId = observationId,
                        observerKey = observerKey,
                        status = NativeBleInboxStoreStatus.KNOWN_PROCESSED_DUPLICATE,
                        shouldScheduleWorker = false
                    )
                )
            }

            return NativeBleInboxStoreMutation(
                items.toString(),
                NativeBleInboxStoreResult(
                    id = item.getString("id"),
                    observationId = observationId,
                    observerKey = observerKey,
                    status = NativeBleInboxStoreStatus.EXISTING_PENDING,
                    shouldScheduleWorker = true
                )
            )
        }

        val id = observationId
        items.put(
            JSONObject()
                .put("id", id)
                .put("observation_id", observationId)
                .put("payload_base64", payloadBase64)
                .put("device_address", deviceAddress ?: "")
                .put("observer_key", observerKey)
                .put("burst_started_elapsed_realtime_ms", burstStartedAt)
                .put("exact_payload_hash", payloadHash)
                .put("rssi", rssi)
                .put("last_rssi", rssi)
                .put("received_at", receivedAt)
                .put("received_elapsed_realtime_ms", receivedElapsedRealtimeMs)
                .put("last_seen_at", receivedAt)
                .put("last_seen_elapsed_realtime_ms", receivedElapsedRealtimeMs)
                .put("processed_at", JSONObject.NULL)
                .put("attempt_count", 0)
                .put("duplicate_count", 0)
                .put("state", STATE_PENDING)
                .put("identity", observationId)
                .put("sender_crc", metadata?.senderCrc ?: JSONObject.NULL)
                .put("timestamp_compact", metadata?.timestampCompact ?: JSONObject.NULL)
                .put("status", metadata?.status ?: JSONObject.NULL)
                .put("is_ack", metadata?.isAck ?: JSONObject.NULL)
                .put("from_server", metadata?.fromServer ?: JSONObject.NULL)
                .put("hop", metadata?.hop ?: JSONObject.NULL)
        )
        return NativeBleInboxStoreMutation(
            items.toString(),
            NativeBleInboxStoreResult(
                id = id,
                observationId = observationId,
                observerKey = observerKey,
                status = NativeBleInboxStoreStatus.NEW_PENDING,
                shouldScheduleWorker = true
            )
        )
    }

    private fun cleanupProcessed(context: Context, now: Long) {
        val items = readItems(context)
        val kept = JSONArray()
        var changed = false
        for (i in 0 until items.length()) {
            val item = items.getJSONObject(i)
            val processedAt = item.optLong("processed_at", 0L)
            if (item.optString("state") == STATE_PROCESSED &&
                processedAt > 0 &&
                now - processedAt > CLEANUP_AFTER_MS
            ) {
                changed = true
                continue
            }
            kept.put(item)
        }
        if (changed) writeItems(context, kept)
    }

    private fun updateItem(
        context: Context,
        id: String,
        update: (JSONObject) -> Unit
    ): Boolean {
        val items = readItems(context)
        var changed = false
        for (i in 0 until items.length()) {
            val item = items.getJSONObject(i)
            if (item.optString("id") != id) continue
            update(item)
            changed = true
            break
        }
        if (changed) writeItems(context, items)
        return changed
    }

    private fun readItems(context: Context): JSONArray {
        val raw = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getString(KEY_ITEMS, "[]")
        return try {
            JSONArray(raw)
        } catch (e: Exception) {
            Log.e(TAG, "Invalid inbox JSON, resetting: ${e.message}", e)
            JSONArray()
        }
    }

    private fun writeItems(context: Context, items: JSONArray) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY_ITEMS, items.toString())
            .apply()
    }

    fun protocolMetadata(payload: ByteArray): NativeBlePacketMetadata? {
        if (payload.size != NativeBleConfig.PROTOCOL_LENGTH_BYTES) return null
        if (payload[0] != 0x52.toByte() || payload[1] != 0x4D.toByte()) return null
        val flags = payload[16].toInt() and 0xFF
        return NativeBlePacketMetadata(
            senderCrc = u32(payload[2], payload[3], payload[4], payload[5]),
            timestampCompact = u24(payload[6], payload[7], payload[8]),
            status = payload[15].toInt() and 0xFF,
            isAck = (flags and 0x80) != 0,
            fromServer = (flags and 0x40) != 0,
            hop = flags and 0x3F
        )
    }

    fun exactPayloadHash(payload: ByteArray): String {
        return MessageDigest.getInstance("SHA-256")
            .digest(payload)
            .joinToString("") { "%02x".format(it) }
    }

    fun observationId(payloadHash: String, observerKey: String, burstStartedAt: Long): String {
        val raw = "$payloadHash|$observerKey|$burstStartedAt"
        return MessageDigest.getInstance("SHA-256")
            .digest(raw.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }
    }

    private fun observationWindow(
        items: JSONArray,
        payloadHash: String,
        observerKey: String,
        receivedAt: Long,
        receivedElapsedRealtimeMs: Long,
        rxBurstGapMs: Long
    ): ObservationWindow {
        val gap = rxBurstGapMs.coerceAtLeast(1L)
        var matchingItem: JSONObject? = null
        var shortestInactivity = Long.MAX_VALUE
        for (i in 0 until items.length()) {
            val item = items.getJSONObject(i)
            if (item.optString("exact_payload_hash") != payloadHash ||
                item.optString("observer_key") != observerKey
            ) {
                continue
            }
            val previousElapsed = item.optLong("last_seen_elapsed_realtime_ms", 0L)
            val useElapsed = receivedElapsedRealtimeMs > 0L && previousElapsed > 0L
            val currentTime = if (useElapsed) receivedElapsedRealtimeMs else receivedAt
            val previousTime = if (useElapsed) previousElapsed else item.optLong("last_seen_at", 0L)
            val inactivity = currentTime - previousTime
            if (previousTime > 0L && inactivity >= 0L && inactivity < shortestInactivity) {
                shortestInactivity = inactivity
                matchingItem = item
            }
        }
        if (matchingItem != null && shortestInactivity < gap) {
            return ObservationWindow(
                observationId = matchingItem.optString(
                    "observation_id",
                    matchingItem.getString("id")
                ),
                burstStartedAt = matchingItem.optLong(
                    "burst_started_elapsed_realtime_ms",
                    0L
                )
            )
        }
        val startedAt = burstStartedAt(receivedElapsedRealtimeMs, receivedAt, gap)
        return ObservationWindow(
            observationId = observationId(payloadHash, observerKey, startedAt),
            burstStartedAt = startedAt
        )
    }

    fun observerKey(
        deviceAddress: String?,
        receivedAt: Long,
        receivedElapsedRealtimeMs: Long,
        rxBurstGapMs: Long = NativeBleConfig.DEFAULT_RX_BURST_GAP_MS
    ): String {
        val normalized = deviceAddress?.trim().orEmpty()
        return if (normalized.isNotEmpty() && normalized != "unknown") {
            "ble:$normalized"
        } else {
            "unknown"
        }
    }

    fun burstStartedAt(
        receivedElapsedRealtimeMs: Long,
        receivedAt: Long = 0L,
        rxBurstGapMs: Long = NativeBleConfig.DEFAULT_RX_BURST_GAP_MS
    ): Long {
        val base = if (receivedElapsedRealtimeMs > 0L) receivedElapsedRealtimeMs else receivedAt
        return if (base > 0L) base else 0L
    }

    private fun u24(b0: Byte, b1: Byte, b2: Byte): Int {
        return ((b0.toInt() and 0xFF) shl 16) or
            ((b1.toInt() and 0xFF) shl 8) or
            (b2.toInt() and 0xFF)
    }

    private fun u32(b0: Byte, b1: Byte, b2: Byte, b3: Byte): Long {
        return ((b0.toLong() and 0xFF) shl 24) or
            ((b1.toLong() and 0xFF) shl 16) or
            ((b2.toLong() and 0xFF) shl 8) or
            (b3.toLong() and 0xFF)
    }

    private fun JSONObject.toMap(): Map<String, Any?> {
        val output = mutableMapOf<String, Any?>()
        keys().forEach { key ->
            output[key] = if (isNull(key)) null else get(key)
        }
        return output
    }
}
