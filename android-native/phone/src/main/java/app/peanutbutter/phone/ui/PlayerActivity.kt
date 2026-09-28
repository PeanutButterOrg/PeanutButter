package app.peanutbutter.phone.ui

import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.View
import android.widget.ProgressBar
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.lifecycleScope
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.ui.PlayerView
import app.peanutbutter.core.LocalTorrentEngine
import app.peanutbutter.core.StreamSession
import app.peanutbutter.phone.R
import app.peanutbutter.phone.asPhone
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class PlayerActivity : AppCompatActivity() {
    private var player: ExoPlayer? = null
    private var sessionId: String? = null
    private var waitJob: Job? = null
    private var statusJob: Job? = null
    private var stopped = false
    private var localTorrent = false
    private var streamOpened = false
    private var lastGoodPosMs = 0L
    private var stallRecoverCount = 0
    private var stallArmed = false
    private var statusView: TextView? = null
    private var busy: ProgressBar? = null
    private val main = Handler(Looper.getMainLooper())
    private val bufferStallRecover = Runnable { recoverFromBufferStall() }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_player)
        val title = intent.getStringExtra(EXTRA_TITLE).orEmpty()
        val directUrl = intent.getStringExtra(EXTRA_URL).orEmpty()
        sessionId = intent.getStringExtra(EXTRA_SESSION)
        localTorrent = intent.getBooleanExtra(EXTRA_LOCAL, false) ||
            sessionId?.startsWith("local-") == true ||
            directUrl.contains("127.0.0.1")
        application.asPhone().activeStreamSession = sessionId
        findViewById<TextView>(R.id.title).text = title
        statusView = findViewById(R.id.status)
        busy = findViewById(R.id.busy)

        val load = DefaultLoadControl.Builder()
            .setBufferDurationsMs(15_000, 60_000, 1_200, 1_500)
            .build()
        val exo = ExoPlayer.Builder(this).setLoadControl(load).build()
        player = exo
        findViewById<PlayerView>(R.id.player).player = exo
        exo.addListener(object : Player.Listener {
            override fun onPlaybackStateChanged(playbackState: Int) {
                when (playbackState) {
                    Player.STATE_BUFFERING -> {
                        statusView?.text = "Buffering…"
                        busy?.visibility = View.VISIBLE
                        if (streamOpened && localTorrent) {
                            armBufferStallWatch()
                            nudgeTorrentAtPlayhead()
                        }
                    }
                    Player.STATE_READY -> {
                        streamOpened = true
                        stallRecoverCount = 0
                        cancelBufferStallWatch()
                        statusView?.text = "Playing"
                        busy?.visibility = View.GONE
                    }
                    Player.STATE_ENDED -> {
                        if (localTorrent && streamOpened) {
                            handleFalseEof()
                        } else {
                            statusView?.text = "Ended"
                        }
                    }
                    else -> Unit
                }
            }

            override fun onIsPlayingChanged(isPlaying: Boolean) {
                if (isPlaying) {
                    streamOpened = true
                    stallRecoverCount = 0
                    cancelBufferStallWatch()
                }
            }

            override fun onEvents(player: Player, events: Player.Events) {
                val pos = player.currentPosition.coerceAtLeast(0L)
                if (pos > lastGoodPosMs) lastGoodPosMs = pos
            }

            override fun onPlayerError(error: PlaybackException) {
                statusView?.text = error.message ?: "Playback error"
                busy?.visibility = View.GONE
            }
        })

        if (localTorrent && directUrl.isNotBlank()) {
            openUrl(directUrl)
            startLocalStatusPolling()
        } else if (!sessionId.isNullOrBlank() && !localTorrent) {
            statusView?.text = "Finding peers…"
            busy?.visibility = View.VISIBLE
            waitJob = lifecycleScope.launch { waitAndPlay(sessionId!!) }
        } else if (directUrl.isNotBlank()) {
            openUrl(application.asPhone().api.playableStreamUrl(directUrl))
        } else {
            statusView?.text = "No stream URL"
            busy?.visibility = View.GONE
        }
    }

    private fun armBufferStallWatch() {
        if (stopped || stallArmed) return
        stallArmed = true
        main.postDelayed(bufferStallRecover, 5_000L)
    }

    private fun cancelBufferStallWatch() {
        stallArmed = false
        main.removeCallbacks(bufferStallRecover)
    }

    private fun nudgeTorrentAtPlayhead() {
        val exo = player ?: return
        val pos = exo.currentPosition.coerceAtLeast(lastGoodPosMs)
        val dur = exo.duration.takeIf { it > 0 } ?: 0L
        LocalTorrentEngine.seekTo(pos, dur)
    }

    private fun recoverFromBufferStall() {
        if (stopped || !localTorrent) return
        val exo = player ?: return
        stallArmed = false
        if (exo.isPlaying) {
            cancelBufferStallWatch()
            return
        }
        if (stallRecoverCount >= 10) return
        stallRecoverCount++
        val pos = lastGoodPosMs.coerceAtLeast(exo.currentPosition).coerceAtLeast(0L)
        val recover = (pos - 2_500L).coerceAtLeast(0L)
        Log.w(TAG, "buffer stall #$stallRecoverCount — nudge to $recover")
        statusView?.text = "Catching up…"
        busy?.visibility = View.VISIBLE
        LocalTorrentEngine.seekTo(recover, exo.duration.takeIf { it > 0 } ?: 0L)
        runCatching {
            exo.seekTo(recover)
            exo.playWhenReady = true
            exo.play()
        }
        main.postDelayed({
            if (!stopped && player?.isPlaying != true) armBufferStallWatch()
        }, 6_000L)
    }

    private fun handleFalseEof() {
        val exo = player ?: return
        val len = exo.duration.takeIf { it > 0 } ?: 0L
        val pos = lastGoodPosMs.coerceAtLeast(exo.currentPosition)
        val nearEnd = len > 120_000 && pos >= (len * 0.90).toLong()
        if (nearEnd || stallRecoverCount >= 8) {
            statusView?.text = "Ended"
            return
        }
        stallRecoverCount++
        val recover = lastGoodPosMs.coerceAtLeast(0L)
        Log.w(TAG, "false EOF — resume at $recover")
        statusView?.text = "Reconnecting…"
        LocalTorrentEngine.seekTo(recover, len)
        main.postDelayed({
            if (stopped) return@postDelayed
            runCatching {
                if (recover > 1_000) exo.seekTo(recover)
                exo.playWhenReady = true
                exo.play()
            }
        }, 600L)
    }

    private fun startLocalStatusPolling() {
        statusJob?.cancel()
        statusJob = lifecycleScope.launch {
            while (isActive && !stopped) {
                val tick = withContext(Dispatchers.IO) { LocalTorrentEngine.currentStats() }
                if (tick != null) {
                    val pct = tick.bufferPct.toInt().coerceIn(0, 100)
                    statusView?.text = when {
                        tick.torrentComplete -> "Downloaded · $pct%"
                        tick.ready -> "Ready · $pct% · ${"%.1f".format(tick.downloadMbps)} MB/s"
                        else -> "Finding peers…" + if (tick.peers > 0) " · ${tick.peers} peers" else ""
                    }
                }
                delay(1_000L)
            }
        }
    }

    private suspend fun waitAndPlay(sessionId: String) {
        val api = application.asPhone().api
        try {
            val session = withContext(Dispatchers.IO) {
                api.waitUntilStreamReady(sessionId) { tick ->
                    runOnUiThread { showTorrentStatus(tick) }
                }
            }
            if (stopped) return
            if (session.isError) {
                statusView?.text = session.status
                busy?.visibility = View.GONE
                return
            }
            if (session.streamUrl.isBlank()) {
                statusView?.text = "Couldn't start stream — try another source"
                busy?.visibility = View.GONE
                return
            }
            openUrl(api.playableStreamUrl(session.streamUrl))
        } catch (e: Exception) {
            if (!stopped) {
                statusView?.text = e.message ?: "Stream failed"
                busy?.visibility = View.GONE
            }
        }
    }

    private fun showTorrentStatus(session: StreamSession) {
        val pct = (session.bufferProgress * 100).toInt().coerceIn(0, 100)
        statusView?.text = when {
            session.isReady -> "Ready · buffering $pct% · ${"%.1f".format(session.downloadMbps)} MB/s"
            else -> "Finding peers…" + if (session.peers > 0) " · ${session.peers} peers" else ""
        }
    }

    private fun openUrl(url: String) {
        val exo = player ?: return
        statusView?.text = "Opening…"
        exo.setMediaItem(MediaItem.fromUri(url))
        exo.prepare()
        exo.playWhenReady = true
    }

    override fun onStop() {
        player?.pause()
        super.onStop()
    }

    override fun onDestroy() {
        stopped = true
        cancelBufferStallWatch()
        waitJob?.cancel()
        statusJob?.cancel()
        if (localTorrent || sessionId?.startsWith("local-") == true) {
            // Keep on-device pieces — cleared only on app exit when the setting is on.
        } else if (!sessionId.isNullOrBlank()) {
            val api = application.asPhone().api
            lifecycleScope.launch(Dispatchers.IO) { runCatching { api.stopStream(sessionId!!) } }
        }
        application.asPhone().activeStreamSession = null
        player?.release()
        player = null
        super.onDestroy()
    }

    companion object {
        private const val TAG = "PhonePlayer"
        const val EXTRA_URL = "url"
        const val EXTRA_TITLE = "title"
        const val EXTRA_SESSION = "session"
        const val EXTRA_LOCAL = "local_torrent"
    }
}
