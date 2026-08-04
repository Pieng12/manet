package id.ac.usu.resqmesh

import android.content.Context
import android.util.Base64
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.security.MessageDigest
import java.util.UUID

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
        val identity = packetIdentity(payload)
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

    private fun packetIdentity(payload: ByteArray): String {
        val digest = MessageDigest.getInstance("SHA-256")
            .digest(payload)
            .joinToString("") { "%02x".format(it) }
        if (payload.size < NativeBleConfig.PROTOCOL_LENGTH_BYTES) return digest
        val sender = u16(payload[2], payload[3])
        val timestamp = u32(payload[4], payload[5], payload[6], payload[7])
        val status = payload[16].toInt() and 0x03
        return "$sender:$timestamp:$status:$digest"
    }

    private fun u16(high: Byte, low: Byte): Int {
        return ((high.toInt() and 0xFF) shl 8) or (low.toInt() and 0xFF)
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
