package local.lanchat

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Environment
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        val wifi =
            applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        // Both locks are best-effort: a ROM that refuses them must not crash
        // startup — discovery still works without them, just less reliably.
        if (lock == null) {
            // Multicast lock: without it most Wi-Fi drivers filter out the
            // UDP multicast discovery packets.
            try {
                lock = wifi.createMulticastLock("lanchat_discovery").apply {
                    setReferenceCounted(false)
                    acquire()
                }
            } catch (e: Exception) {
                lock = null
            }
        }
        if (wifiLock == null) {
            // High-perf Wi-Fi lock: keeps power-save from throttling packet
            // reception while the screen is off / app is backgrounded.
            try {
                wifiLock = wifi.createWifiLock(
                    WifiManager.WIFI_MODE_FULL_HIGH_PERF, "lanchat_wifi"
                ).apply {
                    setReferenceCounted(false)
                    acquire()
                }
            } catch (e: Exception) {
                wifiLock = null
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "lanchat/storage")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isGranted" -> result.success(isStorageGranted())
                    "request" -> {
                        try {
                            startActivity(Intent(
                                Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                                Uri.parse("package:$packageName")
                            ))
                            result.success(true)
                        } catch (e: android.content.ActivityNotFoundException) {
                            // older devices without the all-files screen
                            try {
                                startActivity(Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION))
                                result.success(true)
                            } catch (e2: Exception) {
                                result.success(false)
                            }
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun isStorageGranted(): Boolean =
        Build.VERSION.SDK_INT < 30 || Environment.isExternalStorageManager()

    companion object {
        @Volatile
        private var lock: WifiManager.MulticastLock? = null

        @Volatile
        private var wifiLock: WifiManager.WifiLock? = null
    }
}
