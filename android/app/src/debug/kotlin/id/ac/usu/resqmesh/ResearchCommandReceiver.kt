package id.ac.usu.resqmesh

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log
import org.json.JSONObject

class ResearchCommandReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val command = intent.getStringExtra("command")?.trim().orEmpty()
        val json = JSONObject()
        intent.extras?.keySet()?.forEach { key ->
            if (key != "command") json.put(key, intent.extras?.get(key))
        }
        json.put("command", command)
        val serviceIntent = Intent(context, MeshBackgroundService::class.java).apply {
            action = MeshBackgroundService.RESEARCH_COMMAND_ACTION
            putExtra("research_command_json", json.toString())
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            context.startForegroundService(serviceIntent)
        } else {
            context.startService(serviceIntent)
        }
        val response = JSONObject()
            .put("accepted", command.isNotEmpty())
            .put("command", command)
            .put("command_id", json.optString("command_id"))
        val line = "RESQMESH_CMD_RESULT $response"
        resultData = line
        Log.i("ResQMeshCommand", line)
    }
}
