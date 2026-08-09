package id.ac.usu.resqmesh

import android.content.Context
import android.util.Base64
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.security.MessageDigest
import java.util.UUID

data class NativeBlePacketMetadata(
    val senderCrc: Long,
    val timestampCompact: Int,
    val status: Int,
    val isAck: Boolean,
    val fromServer: Boolean,
    val hop: Int
)

object NativeBleInbox {
    private const val TAG = "NativeBleInbox"
    private const val PREFS = "resqmesh_native_ble_inbox"
    private const val KEY_ITEMS = "items_json"
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
        receivedAt: Long = System.currentTimeMillis()
    ): String {
        cleanupProcessed(context, receivedAt)
        val payloadBase64 = Base64.encodeToString(payload, Base64.NO_WRAP)
        val identity = exactPayloadHash(payload)
        val metadata = protocolMetadata(payload)
        val items = readItems(context)

        for (i in 0 until items.length()) {
            val item = items.getJSONObject(i)
            if (item.optString("identity") == identity &&
                item.optString("state") != STATE_PROCESSED
            ) {
                return item.getString("id")
            }
        }

        val id = UUID.randomUUID().toString()
        items.put(
            JSONObject()
                .put("id", id)
                .put("payload_base64", payloadBase64)
                .put("device_address", deviceAddress ?: "")
                .put("rssi", rssi)
                .put("received_at", receivedAt)
                .put("processed_at", JSONObject.NULL)
                .put("attempt_count", 0)
                .put("state", STATE_PENDING)
                .put("identity", identity)
                .put("sender_crc", metadata?.senderCrc ?: JSONObject.NULL)
                .put("timestamp_compact", metadata?.timestampCompact ?: JSONObject.NULL)
                .put("status", metadata?.status ?: JSONObject.NULL)
                .put("is_ack", metadata?.isAck ?: JSONObject.NULL)
                .put("from_server", metadata?.fromServer ?: JSONObject.NULL)
                .put("hop", metadata?.hop ?: JSONObject.NULL)
        )
        writeItems(context, items)
        Log.i(TAG, "Stored pending BLE inbox item id=$id")
        return id
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
