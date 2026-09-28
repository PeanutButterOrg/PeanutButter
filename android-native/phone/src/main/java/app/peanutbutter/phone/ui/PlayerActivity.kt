package app.peanutbutter.phone.ui

import android.os.Bundle
import android.view.View
import android.widget.ProgressBar
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.lifecycleScope
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.ui.PlayerView
import app.peanutbutter.core.StreamSession
import app.peanutbutter.phone.R
import app.peanutbutter.phone.asPhone
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class PlayerActivity : AppCompatActivity() {
    private var player: ExoPlayer? = null
    private var sessionId: String? = null
    private var waitJob: Job? = null
    private var stopped = false
    private var statusView: TextView? = null
    private var busy: ProgressBar? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_player)
        val title = intent.getStringExtra(EXTRA_TITLE).orEmpty()
        val directUrl = intent.getStringExtra(EXTRA_URL).orEmpty()
        sessionId = intent.getStringExtra(EXTRA_SESSION)
        application.asPhone().activeStreamSession = sessionId
        findViewById<TextView>(R.id.title).text = title
        statusView = findViewById(R.id.status)
        busy = findViewById(R.id.busy)

        val exo = ExoPlayer.Builder(this).build()
        player = exo
        findViewById<PlayerView>(R.id.player).player = exo
        exo.addListener(object : Player.Listener {
            override fun onPlaybackStateChanged(playbackState: Int) {
                when (playbackState) {
                    Player.STATE_BUFFERING -> {
                        statusView?.text = "Buffering…"
                        busy?.visibility = View.VISIBLE
                    }
                    Player.STATE_READY -> {
                        statusView?.text = "Playing"
                        busy?.visibility = View.GONE
                    }
                    Player.STATE_ENDED -> statusView?.text = "Ended"
                    else -> Unit
                }
            }

            override fun onPlayerError(error: PlaybackException) {
                statusView?.text = error.message ?: "Playback error"
                busy?.visibility = View.GONE
            }
        })

        val sid = sessionId
        if (!sid.isNullOrBlank()) {
            statusView?.text = "Finding peers…"
            busy?.visibility = View.VISIBLE
            waitJob = lifecycleScope.launch { waitAndPlay(sid) }
        } else if (directUrl.isNotBlank()) {
            openUrl(application.asPhone().api.playableStreamUrl(directUrl))
        } else {
            statusView?.text = "No stream URL"
            busy?.visibility = View.GONE
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
            if (!session.isReady) {
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
            session.isReady -> "Ready · buffering $pct% · ${"%.1f".format(session.downloadMbps)} Mb/s"
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
        waitJob?.cancel()
        val sid = sessionId
        if (!sid.isNullOrBlank()) {
            val api = application.asPhone().api
            lifecycleScope.launch(Dispatchers.IO) { runCatching { api.stopStream(sid) } }
        }
        application.asPhone().activeStreamSession = null
        player?.release()
        player = null
        super.onDestroy()
    }

    companion object {
        const val EXTRA_URL = "url"
        const val EXTRA_TITLE = "title"
        const val EXTRA_SESSION = "session"
    }
}
