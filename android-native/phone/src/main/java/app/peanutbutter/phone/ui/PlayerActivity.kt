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
import androidx.media3.common.MimeTypes
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.extractor.DefaultExtractorsFactory
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
    private var falseEofCount = 0
    private var stallArmed = false
    private var lastBufferPct = 0.0
    private var torrentComplete = false
    private var software = false
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

        player = buildPlayer(preferSoftware = false)
        findViewById<PlayerView>(R.id.player).player = player

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

    private fun buildPlayer(preferSoftware: Boolean): ExoPlayer {
        val mode = if (preferSoftware) {
            DefaultRenderersFactory.EXTENSION_RENDERER_MODE_PREFER
        } else {
            DefaultRenderersFactory.EXTENSION_RENDERER_MODE_ON
        }
        val renderers = DefaultRenderersFactory(this)
            .setEnableDecoderFallback(true)
            .setExtensionRendererMode(mode)
        val load = DefaultLoadControl.Builder()
            .setBufferDurationsMs(3_500, 14_000, 400, 1_800)
            .setPrioritizeTimeOverSizeThresholds(true)
            .build()
        val http = DefaultHttpDataSource.Factory()
            .setAllowCrossProtocolRedirects(true)
            .setConnectTimeoutMs(8_000)
            .setReadTimeoutMs(60_000)
            .setUserAgent("PeanutButterPhone/1.0")
        val extractors = DefaultExtractorsFactory()
            // Don't scan 0→resume on torrents — use container indexes + Range seeks.
            .setConstantBitrateSeekingEnabled(false)
        val mediaSources = DefaultMediaSourceFactory(this, extractors)
            .setDataSourceFactory(http)
        return ExoPlayer.Builder(this)
            .setRenderersFactory(renderers)
            .setLoadControl(load)
            .setMediaSourceFactory(mediaSources)
            .build()
            .also { exo ->
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
                                falseEofCount = 0
                                cancelBufferStallWatch()
                                statusView?.text = "Playing"
                                busy?.visibility = View.GONE
                            }
                            Player.STATE_ENDED -> handleEndReached()
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
                        val code = error.errorCode
                        val decoder = code == PlaybackException.ERROR_CODE_DECODER_INIT_FAILED ||
                            code == PlaybackException.ERROR_CODE_DECODER_QUERY_FAILED ||
                            code == PlaybackException.ERROR_CODE_DECODING_FAILED ||
                            code == PlaybackException.ERROR_CODE_DECODING_FORMAT_EXCEEDS_CAPABILITIES ||
                            code == PlaybackException.ERROR_CODE_DECODING_FORMAT_UNSUPPORTED
                        if (decoder && !software) {
                            Log.w(TAG, "decoder fail — retry with FFmpeg")
                            val url = exo.currentMediaItem?.localConfiguration?.uri?.toString()
                            val pos = lastGoodPosMs.coerceAtLeast(exo.currentPosition)
                            if (!url.isNullOrBlank()) {
                                rebuildWithSoftware(url, pos)
                                return
                            }
                        }
                        statusView?.text = error.message ?: "Playback error"
                        busy?.visibility = View.GONE
                    }
                })
            }
    }

    private fun rebuildWithSoftware(url: String, resumeMs: Long) {
        software = true
        findViewById<PlayerView>(R.id.player).player = null
        player?.release()
        player = buildPlayer(preferSoftware = true)
        findViewById<PlayerView>(R.id.player).player = player
        openUrl(url, resumeMs)
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
        val dur = exo.duration.takeIf { it > 0 } ?: return
        LocalTorrentEngine.seekTo(pos, dur, aggressive = false)
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
        LocalTorrentEngine.seekTo(recover, exo.duration.takeIf { it > 0 } ?: 0L, aggressive = false)
        runCatching {
            exo.seekTo(recover)
            exo.playWhenReady = true
            exo.play()
        }
        main.postDelayed({
            if (!stopped && player?.isPlaying != true) armBufferStallWatch()
        }, 6_000L)
    }

    private fun handleEndReached() {
        val exo = player ?: return
        val len = exo.duration.takeIf { it > 0 } ?: 0L
        val pos = lastGoodPosMs.coerceAtLeast(exo.currentPosition)
        val nearEnd = len <= 0 ||
            (len > 30_000 && pos >= (len * 0.88).toLong()) ||
            (len > 0 && len - pos <= 8_000)
        val downloadDone = torrentComplete || lastBufferPct >= 99.0
        if (localTorrent && streamOpened && !nearEnd && !downloadDone && falseEofCount < 8) {
            falseEofCount++
            val recover = lastGoodPosMs.coerceAtLeast(0L)
            Log.w(TAG, "false EOF — resume at $recover")
            statusView?.text = "Reconnecting…"
            LocalTorrentEngine.seekTo(recover, len, aggressive = false)
            main.postDelayed({
                if (stopped) return@postDelayed
                runCatching {
                    if (recover > 1_000) exo.seekTo(recover)
                    exo.playWhenReady = true
                    exo.play()
                }
            }, 600L)
            return
        }
        statusView?.text = "Ended"
        finish()
    }

    private fun startLocalStatusPolling() {
        statusJob?.cancel()
        statusJob = lifecycleScope.launch {
            while (isActive && !stopped) {
                val tick = withContext(Dispatchers.IO) { LocalTorrentEngine.currentStats() }
                if (tick != null) {
                    lastBufferPct = tick.bufferPct
                    torrentComplete = tick.torrentComplete
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
        lastBufferPct = session.bufferProgress * 100
        statusView?.text = when {
            session.isReady -> "Ready · buffering $pct% · ${"%.1f".format(session.downloadMbps)} MB/s"
            else -> "Finding peers…" + if (session.peers > 0) " · ${session.peers} peers" else ""
        }
    }

    private fun openUrl(url: String, resumeMs: Long = 0L) {
        val exo = player ?: return
        statusView?.text = "Opening…"
        val item = mediaItemFor(url)
        val start = resumeMs.coerceAtLeast(0L)
        if (start > 2_000) exo.setMediaItem(item, start) else exo.setMediaItem(item)
        exo.prepare()
        exo.playWhenReady = true
    }

    private fun mediaItemFor(url: String): MediaItem {
        val lower = url.substringBefore('?').lowercase()
        val mime = when {
            lower.endsWith(".mkv") -> MimeTypes.VIDEO_MATROSKA
            lower.endsWith(".webm") -> MimeTypes.VIDEO_WEBM
            lower.endsWith(".mp4") || lower.endsWith(".m4v") || lower.endsWith(".mov") -> MimeTypes.VIDEO_MP4
            lower.endsWith(".ts") || lower.endsWith(".m2ts") || lower.endsWith(".mts") -> MimeTypes.VIDEO_MP2T
            else -> null
        }
        val builder = MediaItem.Builder().setUri(url)
        if (mime != null) builder.setMimeType(mime)
        return builder.build()
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
