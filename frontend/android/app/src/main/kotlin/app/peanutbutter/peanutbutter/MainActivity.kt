package app.peanutbutter.peanutbutter

import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.net.Uri
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Hosts native libVLC (SurfaceView behind Flutter) plus optional ACTION_VIEW
 * hand-off for the external-player backend.
 */
class MainActivity : FlutterActivity() {
    private var nativeVlc: NativeVlcPlayer? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Pull in libmla.so early so LibVLC codec modules resolve on Realtek TV.
        NativeVlcPlayer.preloadNativeLibs()

        nativeVlc = NativeVlcPlayer(
            this,
            flutterEngine.dartExecutor.binaryMessenger,
            flutterEngine.renderer,
        )

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "app.peanutbutter/device",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "deviceProfile" -> result.success(
                    mapOf(
                        "emulator" to isEmulator(),
                        "leanback" to isLeanback(),
                        "hardware" to Build.HARDWARE,
                        "model" to Build.MODEL,
                        "product" to Build.PRODUCT,
                        "abis" to Build.SUPPORTED_ABIS.toList(),
                    ),
                )
                else -> result.notImplemented()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "app.peanutbutter/playback",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "openExternal" -> {
                    val url = call.argument<String>("url")
                    val title = call.argument<String>("title") ?: "PeanutButter"
                    val mime = call.argument<String>("mimeType") ?: "video/*"
                    if (url.isNullOrBlank()) {
                        result.error("bad_args", "url required", null)
                        return@setMethodCallHandler
                    }
                    result.success(openExternal(url, title, mime))
                }
                "hasExternalPlayers" -> result.success(hasExternalPlayers())
                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        nativeVlc?.dispose()
        nativeVlc = null
        super.onDestroy()
    }

    private fun openExternal(url: String, title: String, mime: String): Boolean {
        val uri = Uri.parse(url)
        val view = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, mime)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            putExtra(Intent.EXTRA_TITLE, title)
            putExtra("title", title)
            putExtra("http-headers", arrayOf("X-Api-Key: ${uri.getQueryParameter("key") ?: ""}"))
        }
        return try {
            if (view.resolveActivity(packageManager) == null) {
                startActivity(Intent.createChooser(view, "Play with"))
                true
            } else {
                startActivity(view)
                true
            }
        } catch (_: ActivityNotFoundException) {
            false
        } catch (_: SecurityException) {
            false
        }
    }

    private fun hasExternalPlayers(): Boolean {
        val probe = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(Uri.parse("http://127.0.0.1/probe.mkv"), "video/*")
        }
        return probe.resolveActivity(packageManager) != null
    }

    private fun isLeanback(): Boolean {
        val pm = packageManager
        if (pm.hasSystemFeature(PackageManager.FEATURE_LEANBACK)) return true
        if (pm.hasSystemFeature("android.software.leanback")) return true
        val uiMode = resources.configuration.uiMode and Configuration.UI_MODE_TYPE_MASK
        return uiMode == Configuration.UI_MODE_TYPE_TELEVISION
    }

    private fun isEmulator(): Boolean {
        val fingerprint = Build.FINGERPRINT
        val model = Build.MODEL
        val product = Build.PRODUCT
        val hardware = Build.HARDWARE
        return fingerprint.startsWith("generic")
            || fingerprint.startsWith("unknown")
            || model.contains("google_sdk", ignoreCase = true)
            || model.contains("Emulator", ignoreCase = true)
            || model.contains("Android SDK", ignoreCase = true)
            || model.contains("sdk_google_atv", ignoreCase = true)
            || product.contains("sdk", ignoreCase = true)
            || product.contains("vbox", ignoreCase = true)
            || hardware.contains("goldfish", ignoreCase = true)
            || hardware.contains("ranchu", ignoreCase = true)
            || (Build.BRAND.startsWith("generic") && Build.DEVICE.startsWith("generic"))
    }
}
