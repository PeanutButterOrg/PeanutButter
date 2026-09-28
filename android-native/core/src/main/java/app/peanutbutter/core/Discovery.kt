package app.peanutbutter.core

import android.content.Context
import android.net.wifi.WifiManager
import android.os.Build
import android.provider.Settings
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONObject
import java.net.Inet4Address
import java.net.NetworkInterface
import java.util.Collections
import java.util.Locale
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

data class DiscoveredServer(
    val baseUrl: String,
    val label: String,
    val product: String? = null,
    val version: String? = null,
)

/**
 * Mirrors Flutter [Discovery.resolveReachableBase] / [Discovery.discover]:
 * - Prefer explicit base (saved prefs / typed URL)
 * - Probe PeanutButter `/health` (JSON with `status`)
 * - Emulator: `10.0.2.2` → host loopback
 * - LAN scan of common API ports
 */
object Discovery {
    private val client = OkHttpClient.Builder()
        .connectTimeout(900, TimeUnit.MILLISECONDS)
        .readTimeout(1200, TimeUnit.MILLISECONDS)
        .callTimeout(2, TimeUnit.SECONDS)
        .build()

    /** Host-published PeanutButter API (docker maps 3001→8080). */
    private val ports = intArrayOf(3001, 8080, 3000, 5173)

    fun deviceName(context: Context): String {
        val name = runCatching {
            if (Build.VERSION.SDK_INT >= 25) {
                Settings.Global.getString(context.contentResolver, Settings.Global.DEVICE_NAME)
            } else {
                null
            }
        }.getOrNull()
        return name?.takeIf { it.isNotBlank() }
            ?: Build.MODEL?.takeIf { it.isNotBlank() }
            ?: "Android TV"
    }

    fun localIpv4s(): List<String> {
        val out = LinkedHashSet<String>()
        runCatching {
            val ifaces = Collections.list(NetworkInterface.getNetworkInterfaces())
            for (ni in ifaces) {
                if (!ni.isUp || ni.isLoopback) continue
                for (addr in Collections.list(ni.inetAddresses)) {
                    if (addr is Inet4Address && !addr.isLoopbackAddress) {
                        out += addr.hostAddress ?: continue
                    }
                }
            }
        }
        return out.toList()
    }

    fun wifiIpv4(context: Context): String? {
        return runCatching {
            val wm = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            @Suppress("DEPRECATION")
            val ip = wm.connectionInfo?.ipAddress ?: return null
            if (ip == 0) return null
            String.format(
                Locale.US,
                "%d.%d.%d.%d",
                ip and 0xff,
                ip shr 8 and 0xff,
                ip shr 16 and 0xff,
                ip shr 24 and 0xff,
            )
        }.getOrNull()
    }

    fun normalizeBase(raw: String): String {
        var s = raw.trim()
        if (s.isEmpty()) return s
        if (!s.startsWith("http://") && !s.startsWith("https://")) {
            s = "http://$s"
        }
        while (s.endsWith("/")) s = s.dropLast(1)
        return s
    }

    /**
     * True only for PeanutButter health payloads (not random LMS/HTML on :8080).
     */
    suspend fun isPeanutButter(base: String): Boolean = withContext(Dispatchers.IO) {
        val root = normalizeBase(base)
        if (root.isEmpty()) return@withContext false
        val req = Request.Builder().url("$root/health").get().header("Accept", "application/json").build()
        runCatching {
            client.newCall(req).execute().use { resp ->
                if (!resp.isSuccessful) return@use false
                val body = resp.body?.string().orEmpty()
                if (body.isBlank() || body.trimStart().startsWith("<")) return@use false
                val json = JSONObject(body)
                json.has("status")
            }
        }.getOrDefault(false)
    }

    suspend fun healthInfo(base: String): Pair<String?, String?>? = withContext(Dispatchers.IO) {
        val root = normalizeBase(base)
        if (root.isEmpty()) return@withContext null
        val req = Request.Builder().url("$root/health").get().header("Accept", "application/json").build()
        runCatching {
            client.newCall(req).execute().use { resp ->
                if (!resp.isSuccessful) return@use null
                val body = resp.body?.string().orEmpty()
                if (body.isBlank() || body.trimStart().startsWith("<")) return@use null
                val json = JSONObject(body)
                if (!json.has("status")) return@use null
                json.optString("product").ifBlank { null } to json.optString("version").ifBlank { null }
            }
        }.getOrNull()
    }

    /**
     * Resolve a typed/saved base to a reachable PeanutButter URL.
     * Tries as-is, then host with alternate ports, then emulator host gateway.
     */
    suspend fun resolveReachableBase(preferred: String?): String? {
        val preferredNorm = preferred?.let { normalizeBase(it) }?.takeIf { it.isNotBlank() }
        val candidates = LinkedHashSet<String>()
        if (preferredNorm != null) {
            candidates += preferredNorm
            val host = preferredNorm.removePrefix("http://").removePrefix("https://").substringBefore('/')
            val hostOnly = host.substringBefore(':')
            for (p in ports) candidates += "http://$hostOnly:$p"
        }
        // Android emulator → host machine loopback
        for (p in ports) candidates += "http://10.0.2.2:$p"
        // Localhost variants (rare on device, useful if reverse-proxied)
        for (p in ports) {
            candidates += "http://127.0.0.1:$p"
            candidates += "http://localhost:$p"
        }
        for (c in candidates) {
            if (isPeanutButter(c)) return c
        }
        return null
    }

    /** Compatibility: return base URLs only (used by older pairing screens). */
    suspend fun findServers(context: Context? = null, preferred: String? = null): List<String> {
        // Prefer resolveReachableBase for emulator/host first — fast path.
        resolveReachableBase(preferred)?.let { return listOf(it) }
        if (context == null) return emptyList()
        return discover(context, preferred).map { it.baseUrl }
    }

    suspend fun discover(
        context: Context,
        preferred: String? = null,
        cancel: AtomicBoolean = AtomicBoolean(false),
    ): List<DiscoveredServer> = withContext(Dispatchers.IO) {
        val found = LinkedHashMap<String, DiscoveredServer>()

        suspend fun tryBase(base: String, label: String) {
            if (cancel.get()) return
            val root = normalizeBase(base)
            if (root.isEmpty() || found.containsKey(root)) return
            val info = healthInfo(root) ?: return
            found[root] = DiscoveredServer(
                baseUrl = root,
                label = label,
                product = info.first,
                version = info.second,
            )
        }

        // 1) Preferred / saved
        preferred?.let { tryBase(it, "Saved") }

        // 2) Emulator host + localhost
        for (p in ports) {
            tryBase("http://10.0.2.2:$p", "Host (emulator)")
            tryBase("http://127.0.0.1:$p", "Localhost")
        }

        // 3) This device + /24 neighbours on first two octets of wifi/local IP
        val seeds = LinkedHashSet<String>()
        wifiIpv4(context)?.let { seeds += it }
        seeds.addAll(localIpv4s())
        for (ip in seeds) {
            for (p in ports) tryBase("http://$ip:$p", "This device")
            val parts = ip.split('.')
            if (parts.size == 4) {
                val prefix = "${parts[0]}.${parts[1]}.${parts[2]}"
                // Scan a tight window first (gateway + common), then broader /24 sample
                val targets = LinkedHashSet<Int>()
                targets += 1
                targets += parts[3].toIntOrNull() ?: 0
                for (i in 2..40) targets += i
                for (i in 100..120) targets += i
                coroutineScope {
                    targets.map { last ->
                        async {
                            if (cancel.get()) return@async
                            for (p in ports) {
                                if (cancel.get()) return@async
                                tryBase("http://$prefix.$last:$p", "$prefix.$last")
                            }
                        }
                    }.awaitAll()
                }
            }
        }
        found.values.toList()
    }
}
