package app.peanutbutter.tv

import android.app.ActivityManager
import android.app.Application
import android.content.Context
import com.bumptech.glide.Glide
import com.bumptech.glide.GlideBuilder
import com.bumptech.glide.load.engine.cache.InternalCacheDiskCacheFactory
import com.bumptech.glide.load.engine.cache.LruResourceCache
import com.bumptech.glide.load.engine.cache.MemorySizeCalculator
import app.peanutbutter.core.ApiClient
import app.peanutbutter.core.AppExitCleanup
import app.peanutbutter.core.SessionStore

class TvApp : Application() {
    lateinit var session: SessionStore
        private set
    lateinit var api: ApiClient
        private set

    @Volatile
    var activeStreamSession: String? = null

    override fun onCreate() {
        super.onCreate()
        session = SessionStore(this)
        api = ApiClient(session)
        configureGlide()
        AppExitCleanup.install(this, shouldWipe = { session.clearCacheOnExit }) {
            val sid = activeStreamSession
            activeStreamSession = null
            if (!sid.isNullOrBlank()) {
                Thread {
                    runCatching { kotlinx.coroutines.runBlocking { api.stopStream(sid) } }
                }.start()
            }
        }
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
