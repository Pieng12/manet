package id.ac.usu.resqmesh

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.NetworkInfo
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class ConnectivityReceiver : BroadcastReceiver() {
    private val tag = "ConnectivityReceiver"

    companion object {
        const val CONNECTIVITY_CHANNEL = "id.ac.usu.resqmesh/mesh"
        var flutterEngine: FlutterEngine? = null
        private var receiverInstance: ConnectivityReceiver? = null
        private var isRegistered = false

        fun register(context: Context) {
            if (isRegistered) return

            receiverInstance = ConnectivityReceiver()
            val filter = IntentFilter(ConnectivityManager.CONNECTIVITY_ACTION)
            try {
                context.registerReceiver(receiverInstance, filter)
                isRegistered = true
                Log.d("ConnectivityReceiver", "Connectivity receiver registered")
            } catch (e: Exception) {
                receiverInstance = null
                Log.e("ConnectivityReceiver", "Error registering receiver: ${e.message}", e)
            }
        }

        fun unregister(context: Context) {
            if (!isRegistered || receiverInstance == null) return

            try {
                context.unregisterReceiver(receiverInstance)
                Log.d("ConnectivityReceiver", "Connectivity receiver unregistered")
            } catch (e: Exception) {
                Log.e("ConnectivityReceiver", "Error unregistering receiver: ${e.message}", e)
            } finally {
                isRegistered = false
                receiverInstance = null
            }
        }
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ConnectivityManager.CONNECTIVITY_ACTION &&
            intent.action != "android.net.conn.CONNECTIVITY_CHANGE"
        ) {
            return
        }

        val connectivityManager =
            context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val isConnected = isNetworkAvailable(connectivityManager)
        Log.d(tag, "Network connectivity changed. Connected: $isConnected")

        if (isConnected) {
            Handler(Looper.getMainLooper()).postDelayed({
                triggerSyncInFlutter(context)
            }, 2000)
        }
    }

    private fun isNetworkAvailable(connectivityManager: ConnectivityManager): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val network = connectivityManager.activeNetwork ?: return false
            val capabilities =
                connectivityManager.getNetworkCapabilities(network) ?: return false
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) ||
                capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) ||
                capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)
        } else {
            @Suppress("DEPRECATION")
            val networkInfo: NetworkInfo? = connectivityManager.activeNetworkInfo
            networkInfo?.isConnected == true
        }
    }

    private fun triggerSyncInFlutter(context: Context) {
        try {
            val engine = flutterEngine
            if (engine != null && engine.dartExecutor.isExecutingDart) {
                val methodChannel =
                    MethodChannel(engine.dartExecutor.binaryMessenger, CONNECTIVITY_CHANNEL)
                methodChannel.invokeMethod("connectivityChanged", null)
                Log.d(tag, "Triggered sync via existing Flutter engine")
                return
            }

            if (!NativeBlePermissions.hasRequiredRuntimePermissions(context)) {
                Log.w(tag, "Permissions missing. Connectivity-triggered service start deferred.")
                return
            }

            val serviceIntent = Intent(context, MeshBackgroundService::class.java).apply {
                action = MeshBackgroundService.CONNECTIVITY_CHANGED_ACTION
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(serviceIntent)
            } else {
                context.startService(serviceIntent)
            }
        } catch (e: Exception) {
            Log.e(tag, "Error triggering sync: ${e.message}", e)
        }
    }
}
