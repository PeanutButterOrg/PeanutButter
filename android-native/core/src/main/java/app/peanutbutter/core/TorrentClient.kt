package app.peanutbutter.core

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Message
import android.os.Messenger
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeout
import java.util.concurrent.atomic.AtomicReference

/** Client for [TorrentService] running in `:torrent` process. */
object TorrentClient {
    private val main = Handler(Looper.getMainLooper())
    private val messengerRef = AtomicReference<Messenger?>(null)
    private val connRef = AtomicReference<ServiceConnection?>(null)
    @Volatile private var lastStats: LocalStreamStats? = null

    /** Optional UI refresh when a stats reply arrives from `:torrent`. */
    @Volatile var onStatsUpdated: ((LocalStreamStats) -> Unit)? = null

    fun currentStats(): LocalStreamStats? {
        // Request a refresh; return last known immediately.
        val m = messengerRef.get()
        if (m != null) {
            runCatching {
                val msg = Message.obtain(null, TorrentService.MSG_STATS)
                msg.replyTo = statsReply
                m.send(msg)
            }
        }
        return lastStats
    }

    private val statsReply = Messenger(Handler(Looper.getMainLooper()) { msg ->
        if (msg.what == TorrentService.MSG_STATS || msg.what == TorrentService.MSG_READY) {
            // READY handled elsewhere; STATS updates cache
        }
        if (msg.what == TorrentService.MSG_STATS) {
            val stats = msg.data.toStats()
            lastStats = stats
            onStatsUpdated?.invoke(stats)
        }
        true
    })

    suspend fun start(
        context: Context,
        magnet: String,
        season: Int? = null,
        episode: Int? = null,
        fileIndex: Int? = null,
        onStats: ((LocalStreamStats) -> Unit)? = null,
        timeoutMs: Long = 210_000L,
    ): LocalStreamHandle = withTimeout(timeoutMs) {
        // Replace active torrent but keep downloaded pieces unless app-exit wipe.
        stop(context, deleteFiles = false)
        suspendCancellableCoroutine { cont ->
            val app = context.applicationContext

            val reply = Messenger(Handler(Looper.getMainLooper()) { msg ->
                when (msg.what) {
                    TorrentService.MSG_STATS -> {
                        val s = msg.data.toStats()
                        lastStats = s
                        onStats?.invoke(s)
                        onStatsUpdated?.invoke(s)
                    }
                    TorrentService.MSG_READY -> {
                        if (!cont.isActive) return@Handler true
                        val d = msg.data
                        lastStats = LocalStreamStats(
                            bufferPct = 1.0,
                            downloadMbps = lastStats?.downloadMbps ?: 0.0,
                            seeders = lastStats?.seeders ?: 0,
                            peers = lastStats?.peers ?: 0,
                            ready = true,
                            torrentComplete = false,
                        )
                        cont.resume(
                            LocalStreamHandle(
                                sessionId = d.getString(TorrentService.KEY_SESSION).orEmpty(),
                                url = d.getString(TorrentService.KEY_URL).orEmpty(),
                                magnet = magnet,
                                fileIndex = d.getInt(TorrentService.KEY_FILE_INDEX, 0),
                            ),
                        )
                    }
                    TorrentService.MSG_ERROR -> {
                        if (!cont.isActive) return@Handler true
                        val err = msg.data.getString(TorrentService.KEY_ERROR) ?: "Torrent failed"
                        cont.resumeWithException(IllegalStateException(err))
                    }
                }
                true
            })

            val conn = object : ServiceConnection {
                override fun onServiceConnected(name: ComponentName?, service: IBinder?) {
                    val messenger = Messenger(service)
                    messengerRef.set(messenger)
                    AppLog.i("TorrentClient", "bound — sending START")
                    val msg = Message.obtain(null, TorrentService.MSG_START)
                    msg.replyTo = reply
                    msg.data = Bundle().apply {
                        putString(TorrentService.KEY_MAGNET, magnet)
                        putInt(TorrentService.KEY_SEASON, season ?: -1)
                        putInt(TorrentService.KEY_EPISODE, episode ?: -1)
                        putInt(TorrentService.KEY_FILE_INDEX, fileIndex ?: -1)
                    }
                    try {
                        messenger.send(msg)
                    } catch (t: Throwable) {
                        if (cont.isActive) cont.resumeWithException(t)
                    }
                }

                override fun onServiceDisconnected(name: ComponentName?) {
                    AppLog.e("TorrentClient", "service disconnected (native crash?)")
                    messengerRef.set(null)
                    if (cont.isActive) {
                        cont.resumeWithException(
                            IllegalStateException("Torrent engine crashed — try another source."),
                        )
                    }
                }
            }
            connRef.set(conn)

            cont.invokeOnCancellation {
                // Keep service bound after success; only tear down on cancel before ready.
                if (!cont.isCompleted) {
                    stop(app)
                }
            }

            val ok = app.bindService(
                Intent(app, TorrentService::class.java),
                conn,
                Context.BIND_AUTO_CREATE,
            )
            if (!ok) {
                cont.resumeWithException(IllegalStateException("Couldn’t start torrent service"))
            }
        }
    }

    fun stop(context: Context, deleteFiles: Boolean = false) {
        val app = context.applicationContext
        val m = messengerRef.getAndSet(null)
        runCatching {
            val msg = Message.obtain(null, TorrentService.MSG_STOP)
            msg.data = Bundle().apply {
                putBoolean(TorrentService.KEY_DELETE_FILES, deleteFiles)
            }
            m?.send(msg)
        }
        val c = connRef.getAndSet(null)
        if (c != null) runCatching { app.unbindService(c) }
        lastStats = null
        // Also stop in-process engine if any (UI process should be empty).
        runCatching { LocalTorrentEngine.stop(deleteFiles = deleteFiles) }
    }

    fun seekTo(positionMs: Long, durationMs: Long) {
        val m = messengerRef.get()
        if (m != null) {
            runCatching {
                val msg = Message.obtain(null, TorrentService.MSG_SEEK)
                msg.data = Bundle().apply {
                    putLong(TorrentService.KEY_POSITION_MS, positionMs)
                    putLong(TorrentService.KEY_DURATION_MS, durationMs)
                }
                m.send(msg)
            }
        } else {
            // In-process fallback (phone / tests).
            LocalTorrentEngine.seekTo(positionMs, durationMs)
        }
    }

    private fun Bundle.toStats() = LocalStreamStats(
        bufferPct = getDouble(TorrentService.KEY_BUFFER),
        downloadMbps = getDouble(TorrentService.KEY_MBPS),
        seeders = getInt(TorrentService.KEY_SEEDERS),
        peers = getInt(TorrentService.KEY_PEERS),
        ready = getBoolean(TorrentService.KEY_READY),
        torrentComplete = getBoolean(TorrentService.KEY_COMPLETE),
    )
}
