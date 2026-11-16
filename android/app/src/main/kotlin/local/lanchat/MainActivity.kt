package local.lanchat

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Environment
import android.provider.Settings
import android.provider.OpenableColumns
import java.io.File
import java.util.UUID
import android.content.pm.PackageManager
import androidx.core.content.FileProvider
import java.security.MessageDigest
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
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "lanchat/updater")
            .setMethodCallHandler { call, result ->
                if (call.method != "install") { result.notImplemented(); return@setMethodCallHandler }
                val path = call.argument<String>("path")
                if (path == null) { result.error("invalid", "缺少更新包", null); return@setMethodCallHandler }
                Thread {
                    try {
                        val flags = if (Build.VERSION.SDK_INT >= 28) PackageManager.GET_SIGNING_CERTIFICATES else PackageManager.GET_SIGNATURES
                        val archive = packageManager.getPackageArchiveInfo(path, flags)
                            ?: throw IllegalArgumentException("无法读取 APK")
                        val installed = packageManager.getPackageInfo(packageName, flags)
                        if (archive.packageName != packageName) throw IllegalArgumentException("更新包不属于 LanChat")
                        fun certificates(info: android.content.pm.PackageInfo): Set<String> {
                            val signatures = if (Build.VERSION.SDK_INT >= 28) info.signingInfo?.apkContentsSigners else info.signatures
                            return signatures?.map { signature ->
                                MessageDigest.getInstance("SHA-256").digest(signature.toByteArray()).joinToString("") { "%02x".format(it) }
                            }?.toSet() ?: emptySet()
                        }
                        val current = certificates(installed)
                        if (current.isEmpty() || certificates(archive) != current) {
                            runOnUiThread { result.error("SIGNATURE_MISMATCH", "安装包签名与当前应用不同", null) }
                            return@Thread
                        }
                        val oldCode = if (Build.VERSION.SDK_INT >= 28) installed.longVersionCode else installed.versionCode.toLong()
                        val newCode = if (Build.VERSION.SDK_INT >= 28) archive.longVersionCode else archive.versionCode.toLong()
                        if (newCode <= oldCode) throw IllegalArgumentException("更新包版本不高于当前版本")
                        if (Build.VERSION.SDK_INT >= 26 && !packageManager.canRequestPackageInstalls()) {
                            runOnUiThread {
                                try {
                                    startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName")))
                                    result.success("permission")
                                } catch (e: Exception) { result.error("install", e.message, null) }
                            }
                            return@Thread
                        }
                        val directory = File(cacheDir, "updates").apply { mkdirs() }
                        val apk = File(directory, "lanchat-update.apk")
                        File(path).copyTo(apk, overwrite = true)
                        val uri = FileProvider.getUriForFile(this, "$packageName.updates", apk)
                        runOnUiThread {
                            try {
                                startActivity(Intent(Intent.ACTION_VIEW).setDataAndType(uri, "application/vnd.android.package-archive")
                                    .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION))
                                result.success("launched")
                            } catch (e: Exception) { result.error("install", e.message, null) }
                        }
                    } catch (e: Exception) {
                        runOnUiThread { result.error("install", e.message ?: "无法启动安装器", null) }
                    }
                }.start()
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "lanchat/clipboard")
            .setMethodCallHandler { call, result ->
                if (call.method != "import") { result.notImplemented(); return@setMethodCallHandler }
                val paths = call.arguments as? List<*>
                if (paths == null) { result.error("invalid", "Missing clipboard files", null); return@setMethodCallHandler }
                Thread {
                    try {
                        val copied = paths.map { value ->
                            val uri = Uri.parse(value as String)
                            var name = "粘贴的文件"
                            contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
                                if (cursor.moveToFirst()) name = cursor.getString(0) ?: name
                            }
                            val directory = File(cacheDir, "clipboard-" + UUID.randomUUID()).apply { mkdirs() }
                            val file = File(directory, File(name).name)
                            val input = contentResolver.openInputStream(uri) ?: throw java.io.IOException("Cannot read clipboard")
                            input.use { source -> file.outputStream().use { target -> source.copyTo(target) } }
                            file.absolutePath
                        }
                        runOnUiThread { result.success(copied) }
                    } catch (e: Exception) {
                        runOnUiThread { result.error("clipboard", "Cannot read clipboard files", null) }
                    }
                }.start()
            }
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
