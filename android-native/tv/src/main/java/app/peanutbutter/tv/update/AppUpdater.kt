package app.peanutbutter.tv.update

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.os.Build
import android.util.Base64
import app.peanutbutter.core.ApiClient
import app.peanutbutter.tv.BuildConfig
import app.peanutbutter.core.SessionStore
import com.google.gson.JsonObject
import com.google.gson.JsonParser
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request
import org.bouncycastle.crypto.params.Ed25519PublicKeyParameters
import org.bouncycastle.crypto.signers.Ed25519Signer
import java.io.File
import java.security.MessageDigest
import kotlin.coroutines.coroutineContext

class UpdateException(message: String) : Exception(message)

data class AppUpdate(
    val version: String,
    val build: Long,
    val name: String,
    val size: Long,
    val sha256: String,
    val url: String,
)

/**
 * Self-update against the paired server's mirror of the signed GitHub release
 * (`GET /updates/latest?platform=android-tv`). Same trust model as the
 * desktop apps: only the Ed25519-signed manifest is believed, and the APK
 * must match its size + SHA-256 before it reaches Android's installer.
 */
object AppUpdater {
    /** Raw Ed25519 key matching packaging/update-signing-public.pem. */
    internal const val PUBLIC_KEY = "ZZiyOouovg/54bH4BjyDRk3gldZtS+oHJjjkUGo6e7c="
    /** "android-tv" or "android-tv-launcher": each flavor only installs its own APK. */
    private val PLATFORM = BuildConfig.UPDATE_PLATFORM
    private val SAFE_NAME = Regex("^[A-Za-z0-9_-][A-Za-z0-9._-]{0,126}$")
    const val ACTION_INSTALL_STATUS = "app.peanutbutter.tv.UPDATE_INSTALL_STATUS"

    private val http: OkHttpClient by lazy { ApiClient.defaultClient() }

    fun verifySignature(message: ByteArray, signatureB64: String): Boolean = try {
        verifyRaw(
            Base64.decode(PUBLIC_KEY, Base64.DEFAULT),
            message,
            Base64.decode(signatureB64.trim(), Base64.DEFAULT),
        )
    } catch (_: IllegalArgumentException) {
        false
    }

    /** Ed25519 check on decoded bytes (kept free of android.* for unit tests). */
    internal fun verifyRaw(publicKey: ByteArray, message: ByteArray, signature: ByteArray): Boolean = try {
        Ed25519Signer().run {
            init(false, Ed25519PublicKeyParameters(publicKey, 0))
            update(message, 0, message.size)
            verifySignature(signature)
        }
    } catch (_: Exception) {
        false
    }

    fun currentBuild(context: Context): Long {
        val info = context.packageManager.getPackageInfo(context.packageName, 0)
        return if (Build.VERSION.SDK_INT >= 28) info.longVersionCode
        else @Suppress("DEPRECATION") info.versionCode.toLong()
    }

    /**
     * A newer signed release for this TV, or null when up to date / not offered.
     * Asks for the universal APK (always published) and then picks the
     * per-CPU one from the signed manifest when it exists.
     */
    suspend fun check(context: Context, session: SessionStore): AppUpdate? = withContext(Dispatchers.IO) {
        val base = session.serverUrl.trim().trimEnd('/').removeSuffix("/graphql")
        if (base.isBlank()) return@withContext null
        val url = "$base/updates/latest".toHttpUrl().newBuilder()
            .addQueryParameter("platform", PLATFORM).build()
        val body = http.newCall(authed(Request.Builder().url(url), session).build()).execute().use { res ->
            if (res.code == 204 || res.code == 404) return@withContext null
            if (!res.isSuccessful) throw UpdateException("Update check failed (HTTP ${res.code}).")
            res.body?.string().orEmpty()
        }
        val data = JsonParser.parseString(body).asJsonObject
        val manifestText = data.str("manifest")
        if (!verifySignature(manifestText.toByteArray(Charsets.UTF_8), data.str("signature"))) {
            throw UpdateException("The server offered an update with an invalid signature.")
        }
        // Trust only the signed manifest, never the unsigned fields around it.
        val manifest = JsonParser.parseString(manifestText).asJsonObject
        val assets = manifest.getAsJsonObject("assets") ?: return@withContext null
        // Prefer the APK built for this CPU; the universal one fits every box.
        val asset = assetKeys().firstNotNullOfOrNull { key ->
            assets.get(key)?.takeIf { it.isJsonObject }?.asJsonObject
        } ?: return@withContext null
        val build = manifest.get("build")?.asLong ?: 0L
        if (build <= currentBuild(context)) return@withContext null
        val name = asset.str("name")
        val tag = manifest.str("tag")
        if (!SAFE_NAME.matches(name) || !SAFE_NAME.matches(tag)) {
            throw UpdateException("The update manifest has an invalid file name.")
        }
        AppUpdate(
            version = manifest.str("version").ifBlank { "?" },
            build = build,
            name = name,
            size = asset.get("size").asLong,
            sha256 = asset.str("sha256").lowercase(),
            // The server mirrors every asset of the release under its tag.
            url = "$base/updates/files/$tag/$name",
        )
    }

    private fun updatesDir(context: Context) = File(context.cacheDir, "updates")

    /** The verified APK for [update], kept so a second Install doesn't download it again. */
    private fun cachedApk(context: Context, update: AppUpdate) =
        File(updatesDir(context), "update-${update.build}-${update.sha256.take(16)}.apk")

    /** Drop downloaded updates (called once the app is up to date). */
    fun clearDownloads(context: Context) {
        updatesDir(context).listFiles()?.forEach { it.delete() }
    }

    private fun sha256Of(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buf = ByteArray(64 * 1024)
            while (true) {
                val n = input.read(buf)
                if (n < 0) break
                digest.update(buf, 0, n)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(java.util.Locale.US, it) }
    }

    /**
     * The update's APK, checked against the signed size + SHA-256. One that was
     * already downloaded and still verifies is reused (it used to be deleted
     * and fetched again on every Install press).
     */
    suspend fun download(
        context: Context,
        session: SessionStore,
        update: AppUpdate,
        onProgress: (Float) -> Unit,
    ): File = withContext(Dispatchers.IO) {
        val dir = updatesDir(context).apply { mkdirs() }
        val file = cachedApk(context, update)
        if (file.length() == update.size && sha256Of(file) == update.sha256) {
            onProgress(1f)
            return@withContext file
        }
        // Anything else here is an older or broken download.
        dir.listFiles()?.forEach { it.delete() }
        val part = File(dir, file.name + ".part")
        val digest = MessageDigest.getInstance("SHA-256")
        var got = 0L
        http.newCall(authed(Request.Builder().url(update.url), session).build()).execute().use { res ->
            if (!res.isSuccessful) throw UpdateException("Download failed (HTTP ${res.code}).")
            val input = res.body?.byteStream() ?: throw UpdateException("Empty download.")
            part.outputStream().use { out ->
                val buf = ByteArray(64 * 1024)
                while (true) {
                    coroutineContext.ensureActive()
                    val n = input.read(buf)
                    if (n < 0) break
                    out.write(buf, 0, n)
                    digest.update(buf, 0, n)
                    got += n
                    if (got > update.size) break
                    onProgress(got.toFloat() / update.size)
                }
            }
        }
        val hex = digest.digest().joinToString("") { "%02x".format(java.util.Locale.US, it) }
        if (got != update.size || hex != update.sha256) {
            part.delete()
            throw UpdateException("The downloaded update does not match the signed release.")
        }
        if (!part.renameTo(file)) throw UpdateException("Couldn't save the update.")
        file
    }

    /**
     * Stream the verified APK into a PackageInstaller session. Android then
     * shows its own "Update?" screen via [UpdateInstallReceiver].
     */
    suspend fun install(context: Context, apk: File) = withContext(Dispatchers.IO) {
        val installer = context.packageManager.packageInstaller
        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
            .apply { setAppPackageName(context.packageName) }
        val id = installer.createSession(params)
        installer.openSession(id).use { session ->
            apk.inputStream().use { input ->
                session.openWrite("base.apk", 0, apk.length()).use { out ->
                    input.copyTo(out, 64 * 1024)
                    session.fsync(out)
                }
            }
            val flags = PendingIntent.FLAG_UPDATE_CURRENT or
                (if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0)
            val callback = PendingIntent.getBroadcast(
                context,
                id,
                Intent(ACTION_INSTALL_STATUS).setPackage(context.packageName),
                flags,
            )
            session.commit(callback.intentSender)
        }
    }

    private fun assetKeys(): List<String> {
        val abi = Build.SUPPORTED_ABIS.firstOrNull()
        return listOfNotNull(
            abi?.takeIf { it == "arm64-v8a" || it == "armeabi-v7a" }?.let { "$PLATFORM-$it" },
            PLATFORM,
        )
    }

    private fun authed(builder: Request.Builder, session: SessionStore): Request.Builder {
        val token = session.apiToken
        return if (token.isBlank()) builder else builder.header("X-Api-Key", token)
    }

    private fun JsonObject.str(key: String): String =
        get(key)?.takeUnless { it.isJsonNull }?.asString.orEmpty()
}
