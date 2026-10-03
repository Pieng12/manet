package id.ac.usu.resqmesh

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import android.util.Log

object RangeRxTelemetry {
    private const val PREFS = "resqmesh_range_pilot"
    private const val LIMIT = 2048
    private class Store(context: Context) : SQLiteOpenHelper(context, "resqmesh_range_rx.db", null, 1) {
        override fun onCreate(db: SQLiteDatabase) {
            db.execSQL("CREATE TABLE samples (observation_id TEXT PRIMARY KEY, run_id TEXT NOT NULL, received_at INTEGER NOT NULL, primary_phy INTEGER, secondary_phy INTEGER, legacy INTEGER)")
        }
        override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) = Unit
    }
    @Volatile
    private var helper: Store? = null

    @Synchronized
    private fun db(context: Context): SQLiteDatabase {
        if (helper == null) helper = Store(context.applicationContext)
        return helper!!.writableDatabase
    }
    fun configure(context: Context, runId: String, until: Long) {
        require(runId.isNotBlank() && until > 0)
        context.getSharedPreferences(PREFS, 0).edit().putString("run_id", runId).putLong("until", until).commit()
    }
    internal fun eligible(runId: String?, until: Long, now: Long, observationId: String): Boolean =
        !runId.isNullOrBlank() && until > now && observationId.isNotBlank()

    internal fun bestEffort(write: () -> Unit): Boolean = try {
        write()
        true
    } catch (_: Exception) {
        false
    }

    fun record(context: Context, observationId: String, receivedAt: Long,
               primary: Int?, secondary: Int?, legacy: Boolean?) {
        val prefs = context.getSharedPreferences(PREFS, 0)
        val runId = prefs.getString("run_id", null)
        if (!eligible(runId, prefs.getLong("until", 0), System.currentTimeMillis(), observationId)) return
        if (!bestEffort {
            val values = ContentValues().apply {
                put("observation_id", observationId)
                put("run_id", runId)
                put("received_at", receivedAt)
                put("primary_phy", primary)
                put("secondary_phy", secondary)
                if (legacy == null) putNull("legacy") else put("legacy", if (legacy) 1 else 0)
            }
            val store = db(context)
            store.insertWithOnConflict("samples", null, values, SQLiteDatabase.CONFLICT_IGNORE)
            store.execSQL("DELETE FROM samples WHERE observation_id IN (SELECT observation_id FROM samples ORDER BY received_at DESC LIMIT -1 OFFSET $LIMIT)")
        }) Log.w("RangeRxTelemetry", "Pilot telemetry unavailable; protocol processing continues")
    }
    internal fun coded(primary: Int?, secondary: Int?, legacy: Boolean?): Boolean =
        primary == 3 && secondary == 3 && legacy == false

    fun snapshot(context: Context): Map<String, Any?> {
        val runId = context.getSharedPreferences(PREFS, 0).getString("run_id", null)
        val samples = mutableListOf<Map<String, Any?>>()
        if (runId != null) db(context).query("samples", null, "run_id = ?", arrayOf(runId), null, null, "received_at ASC").use { cursor ->
            while (cursor.moveToNext()) {
                fun number(key: String): Int? {
                    val i = cursor.getColumnIndexOrThrow(key)
                    return if (cursor.isNull(i)) null else cursor.getInt(i)
                }
                samples.add(mapOf("observation_id" to cursor.getString(cursor.getColumnIndexOrThrow("observation_id")),
                    "received_at" to cursor.getLong(cursor.getColumnIndexOrThrow("received_at")),
                    "primary_phy" to number("primary_phy"), "secondary_phy" to number("secondary_phy"),
                    "legacy" to number("legacy")?.let { it == 1 }))
            }
        }
        return mapOf("run_id" to runId, "samples" to samples)
    }
}
