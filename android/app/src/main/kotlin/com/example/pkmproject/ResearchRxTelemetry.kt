package id.ac.usu.resqmesh

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import org.json.JSONObject

// Optional sidecar: inbox durability and protocol decisions never depend on it.
object ResearchRxTelemetry {
    private const val PREFS = "resqmesh_research_phy"
    private class Store(context: Context) : SQLiteOpenHelper(context, "resqmesh_research_phy.db", null, 1) {
        override fun onCreate(db: SQLiteDatabase) {
            db.execSQL("CREATE TABLE samples (observation_id TEXT PRIMARY KEY, session_id TEXT NOT NULL, trial_id TEXT NOT NULL, event_json TEXT NOT NULL)")
        }
        override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) = Unit
    }
    @Volatile private var helper: Store? = null
    @Synchronized private fun db(context: Context): SQLiteDatabase {
        if (helper == null) helper = Store(context.applicationContext)
        return helper!!.writableDatabase
    }
    fun configure(context: Context, session: String, trial: String, node: String, mode: String, offset: Double?, until: Long) {
        context.getSharedPreferences(PREFS, 0).edit()
            .putString("session", session).putString("trial", trial).putString("node", node)
            .putString("mode", mode).putString("offset", offset?.toString()).putLong("until", until).commit()
    }
    internal fun eligible(session: String?, trial: String?, until: Long, now: Long, observation: String) =
        !session.isNullOrBlank() && !trial.isNullOrBlank() && until > now && observation.isNotBlank()

    fun record(context: Context, observation: String, at: Long, monotonic: Long, primary: Int?, secondary: Int?, legacy: Boolean?) {
        val prefs = context.getSharedPreferences(PREFS, 0)
        val session = prefs.getString("session", null)
        val trial = prefs.getString("trial", null)
        if (!eligible(session, trial, prefs.getLong("until", 0), System.currentTimeMillis(), observation)) return
        val offset = prefs.getString("offset", null)?.toDoubleOrNull()
        val event = JSONObject().apply {
            put("kind", "event"); put("event_type", "BLE_RX_PHY_OBSERVED")
            put("session_id", session); put("trial_id", trial); put("node_id", prefs.getString("node", null))
            put("mode", prefs.getString("mode", null)); put("observation_id", observation)
            put("timestamp_ms", at); put("elapsed_realtime_ms", monotonic)
            put("clock_sync_valid", offset != null); put("clock_offset_ms", offset ?: JSONObject.NULL)
            put("primary_phy", primary ?: JSONObject.NULL); put("secondary_phy", secondary ?: JSONObject.NULL)
            put("legacy", legacy ?: JSONObject.NULL); put("coding", "unknown")
        }
        db(context).insertWithOnConflict("samples", null, ContentValues().apply {
            put("observation_id", observation); put("session_id", session); put("trial_id", trial)
            put("event_json", event.toString())
        }, SQLiteDatabase.CONFLICT_IGNORE)
    }
    fun snapshot(context: Context, session: String, trial: String?): List<String> {
        val rows = mutableListOf<String>()
        val where = if (trial == null) "session_id = ?" else "session_id = ? AND trial_id = ?"
        val args = if (trial == null) arrayOf(session) else arrayOf(session, trial)
        db(context).query("samples", arrayOf("event_json"), where, args, null, null, "rowid ASC").use {
            while (it.moveToNext()) rows.add(it.getString(0))
        }
        return rows
    }
}
