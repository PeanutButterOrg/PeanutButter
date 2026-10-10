package app.peanutbutter.tv

import android.app.ActivityManager
import android.app.Application
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import com.bumptech.glide.Glide
import com.bumptech.glide.GlideBuilder
import com.bumptech.glide.load.engine.cache.InternalCacheDiskCacheFactory
import com.bumptech.glide.load.engine.cache.LruResourceCache
import com.bumptech.glide.load.engine.cache.MemorySizeCalculator
import app.peanutbutter.core.ApiClient
import app.peanutbutter.core.AppExitCleanup
import app.peanutbutter.core.AppLog
import app.peanutbutter.core.AuthEvents
import app.peanutbutter.core.SessionStore
import app.peanutbutter.core.TorrentClient
import app.peanutbutter.tv.ui.PairingActivity

class TvApp : Application() {
    lateinit var session: SessionStore
        private set
    lateinit var api: ApiClient
        private set

    @Volatile
    var activeStreamSession: String? = null

    private val mainHandler = Handler(Looper.getMainLooper())

    override fun onCreate() {
        super.onCreate()
        session = SessionStore(this)
        api = ApiClient(session)
        AuthEvents.setUnpairedListener {
            mainHandler.post { openPairingScreen() }
        }
        configureGlide()
        // Torrents run in :torrent via TorrentService so a native crash can't kill UI.
        AppLog.init(this)
        AppLog.i("TvApp", "onCreate")
        val prev = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { t, e ->
            AppLog.e("Crash", "uncaught in ${t.name}", e)
            prev?.uncaughtException(t, e)
        }
        AppExitCleanup.install(this, shouldWipe = { session.clearCacheOnExit }) { deleteFiles ->
            activeStreamSession = null
            runCatching { TorrentClient.stop(this, deleteFiles = deleteFiles) }
        }
    }

    private fun openPairingScreen() {
        val intent = Intent(this, PairingActivity::class.java)
            .addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_CLEAR_TASK or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP,
            )
        startActivity(intent)
    }

    /** Shrink Glide memory for low-end TV boxes (2–3GB devices). */
    private fun configureGlide() {
        val calc = MemorySizeCalculator.Builder(this).build()
        val am = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val lowRam = am.isLowRamDevice || am.memoryClass <= 192
        val memBytes = if (lowRam) {
            (calc.memoryCacheSize * 0.45f).toLong().coerceAtLeast(8L * 1024 * 1024)
        } else {
            (calc.memoryCacheSize * 0.7f).toLong()
        }
        val diskBytes = if (lowRam) 48L * 1024 * 1024 else 120L * 1024 * 1024
        try {
            Glide.init(
                this,
                GlideBuilder()
                    .setMemoryCache(LruResourceCache(memBytes))
                    .setDiskCache(InternalCacheDiskCacheFactory(this, "pb_img", diskBytes)),
            )
        } catch (_: IllegalArgumentException) {
            // Already initialized — ignore
        }
    }
}

fun Application.asTv(): TvApp = this as TvApp
