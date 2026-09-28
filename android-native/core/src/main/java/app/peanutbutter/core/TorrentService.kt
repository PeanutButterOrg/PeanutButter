package app.peanutbutter.core

import android.app.Service
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Messenger
import android.os.Process
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

/**
 * Runs libtorrent in a separate process (`:torrent`) so a native crash
 * cannot kill the UI / PlayerActivity.
 */
class TorrentService : Service() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var job: Job? = null
    private val main = Handler(Looper.getMainLooper())

    private val handler = Handler(Looper.getMainLooper()) { msg ->
        when (msg.what) {
            MSG_START -> {
                val data = msg.data ?: return@Handler true
                val replyTo = msg.replyTo
                val magnet = data.getString(KEY_MAGNET).orEmpty()
                val season = data.getInt(KEY_SEASON, -1).takeIf { it > 0 }
                val episode = data.getInt(KEY_EPISODE, -1).takeIf { it > 0 }
                val fileIndex = data.getInt(KEY_FILE_INDEX, -1).takeIf { it >= 0 }
                AppLog.i(TAG, "MSG_START magnet=${magnet.take(48)}…")
                startTorrent(replyTo, magnet, season, episode, fileIndex)
                true
            }
            MSG_STOP -> {
                val delete = msg.data?.getBoolean(KEY_DELETE_FILES, false) == true
                AppLog.i(TAG, "MSG_STOP deleteFiles=$delete")
                job?.cancel()
                runCatching { LocalTorrentEngine.stop(deleteFiles = delete) }
                true
            }
            MSG_STATS -> {
                val replyTo = msg.replyTo ?: return@Handler true
                val stats = LocalTorrentEngine.currentStats()
                val b = Bundle().apply {
                    putDouble(KEY_BUFFER, stats?.bufferPct ?: 0.0)
                    putDouble(KEY_MBPS, stats?.downloadMbps ?: 0.0)
                    putInt(KEY_SEEDERS, stats?.seeders ?: 0)
                    putInt(KEY_PEERS, stats?.peers ?: 0)
                    putBoolean(KEY_READY, stats?.ready == true)
                    putBoolean(KEY_COMPLETE, stats?.torrentComplete == true)
                }
                reply(replyTo, MSG_STATS, b)
                true
            }
            MSG_SEEK -> {
                val pos = msg.data?.getLong(KEY_POSITION_MS, 0L) ?: 0L
                val dur = msg.data?.getLong(KEY_DURATION_MS, 0L) ?: 0L
                AppLog.i(TAG, "MSG_SEEK pos=$pos dur=$dur")
                runCatching { LocalTorrentEngine.seekTo(pos, dur) }
                true
            }
            else -> false
        }
    }

    private val messenger = Messenger(handler)

    override fun onCreate() {
        super.onCreate()
        AppLog.init(this)
        AppLog.i(TAG, "onCreate pid=${Process.myPid()}")
        LocalTorrentEngine.ensureInit(this)
    }

    override fun onBind(intent: Intent?): IBinder = messenger.binder

    override fun onDestroy() {
        AppLog.i(TAG, "onDestroy")
        job?.cancel()
        scope.cancel()
        // Never wipe files here — UI process decides via MSG_STOP / AppExitCleanup.
        // Abrupt kills keep pieces on disk so clear-cache-off survives reboots.
        runCatching { LocalTorrentEngine.stop(deleteFiles = false) }
        super.onDestroy()
    }

    private fun startTorrent(
        replyTo: Messenger?,
        magnet: String,
        season: Int?,
        episode: Int?,
        fileIndex: Int?,
    ) {
        job?.cancel()
        if (magnet.isBlank()) {
            reply(replyTo, MSG_ERROR, Bundle().apply { putString(KEY_ERROR, "Missing magnet") })
            return
        }
        job = scope.launch {
            try {
                AppLog.i(TAG, "LocalTorrentEngine.start…")
                val handle = LocalTorrentEngine.start(
                    context = this@TorrentService,
                    magnet = magnet,
                    season = season,
                    episode = episode,
                    fileIndex = fileIndex,
                    onStats = { stats ->
                        val b = Bundle().apply {
                            putDouble(KEY_BUFFER, stats.bufferPct)
                            putDouble(KEY_MBPS, stats.downloadMbps)
                            putInt(KEY_SEEDERS, stats.seeders)
                            putInt(KEY_PEERS, stats.peers)
                            putBoolean(KEY_READY, stats.ready)
                            putBoolean(KEY_COMPLETE, stats.torrentComplete)
                        }
                        reply(replyTo, MSG_STATS, b)
                    },
                )
                AppLog.i(TAG, "ready url=${handle.url}")
                val b = Bundle().apply {
                    putString(KEY_URL, handle.url)
                    putString(KEY_SESSION, handle.sessionId)
                    putInt(KEY_FILE_INDEX, handle.fileIndex)
                }
                reply(replyTo, MSG_READY, b)
            } catch (t: Throwable) {
                AppLog.e(TAG, "start failed", t)
                reply(
                    replyTo,
                    MSG_ERROR,
                    Bundle().apply {
                        putString(KEY_ERROR, t.message ?: "Torrent failed")
                    },
                )
            }
        }
    }

    private fun reply(to: Messenger?, what: Int, data: Bundle) {
        if (to == null) return
        main.post {
            try {
                val msg = android.os.Message.obtain(null, what)
                msg.data = data
                to.send(msg)
            } catch (t: Throwable) {
                AppLog.e(TAG, "reply failed", t)
            }
        }
    }

    companion object {
        private const val TAG = "TorrentService"
        const val MSG_START = 1
        const val MSG_STOP = 2
        const val MSG_STATS = 3
        const val MSG_SEEK = 4
        const val MSG_READY = 10
        const val MSG_ERROR = 11

        const val KEY_MAGNET = "magnet"
        const val KEY_SEASON = "season"
        const val KEY_EPISODE = "episode"
        const val KEY_FILE_INDEX = "file_index"
        const val KEY_URL = "url"
        const val KEY_SESSION = "session"
        const val KEY_ERROR = "error"
        const val KEY_BUFFER = "buffer"
        const val KEY_MBPS = "mbps"
        const val KEY_SEEDERS = "seeders"
        const val KEY_PEERS = "peers"
        const val KEY_READY = "ready"
        const val KEY_COMPLETE = "complete"
        const val KEY_POSITION_MS = "position_ms"
        const val KEY_DURATION_MS = "duration_ms"
        const val KEY_DELETE_FILES = "delete_files"
    }
}
