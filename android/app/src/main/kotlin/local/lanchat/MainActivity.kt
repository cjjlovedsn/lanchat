package local.lanchat

import android.content.Context
import android.net.wifi.WifiManager
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        val wifi =
            applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        if (lock == null) {
            // Multicast lock: without it most Wi-Fi drivers filter out the
            // UDP multicast discovery packets.
            lock = wifi.createMulticastLock("lanchat_discovery").apply {
                setReferenceCounted(false)
                acquire()
            }
        }
        if (wifiLock == null) {
            // High-perf Wi-Fi lock: keeps power-save from throttling packet
            // reception while the screen is off / app is backgrounded.
            wifiLock = wifi.createWifiLock(
                WifiManager.WIFI_MODE_FULL_HIGH_PERF, "lanchat_wifi"
            ).apply {
                setReferenceCounted(false)
                acquire()
            }
        }
    }

    companion object {
        @Volatile
        private var lock: WifiManager.MulticastLock? = null

        @Volatile
        private var wifiLock: WifiManager.WifiLock? = null
    }
}
