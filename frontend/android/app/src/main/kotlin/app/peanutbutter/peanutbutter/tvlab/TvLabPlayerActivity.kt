package app.peanutbutter.peanutbutter.tvlab

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.Gravity
import android.view.KeyEvent
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.ProgressBar
import android.widget.TextView
import android.widget.Toast
import android.app.Activity
import org.videolan.libvlc.LibVLC
import org.videolan.libvlc.Media
import org.videolan.libvlc.MediaPlayer

/**
 * Phase‑0 Android TV lab: LibVLC → real [SurfaceView] (no Flutter Texture).
 * Launch from Flutter TV Lab or:
 *   adb shell am start -n app.peanutbutter.peanutbutter/.tvlab.TvLabPlayerActivity \
 *     --es url 'https://…' --es title 'Test'
 */
class TvLabPlayerActivity : Activity(), SurfaceHolder.Callback {
    private val main = Handler(Looper.getMainLooper())
    private var libVLC: LibVLC? = null
    private var player: MediaPlayer? = null
    private var surfaceView: SurfaceView? = null
    private var statusView: TextView? = null
    private var progress: ProgressBar? = null
    private var titleView: TextView? = null
    private var pendingUrl: String? = null
    private var surfaceReady = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val url = intent.getStringExtra(EXTRA_URL).orEmpty()
        val title = intent.getStringExtra(EXTRA_TITLE).orEmpty().ifBlank { "TV Lab Player" }
        if (url.isBlank()) {
            Toast.makeText(this, "No URL", Toast.LENGTH_LONG).show()
            finish()
            return
        }
        pendingUrl = url

        val root = FrameLayout(this).apply {
            setBackgroundColor(0xFF000000.toInt())
            layoutParams = ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
            )
        }

        val surface = SurfaceView(this).also { surfaceView = it }
        surface.holder.addCallback(this)
        root.addView(
            surface,
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
            ),
        )

        val titleTv = TextView(this).apply {
            text = title
            setTextColor(0xFFFFFFFF.toInt())
            textSize = 22f
            setPadding(48, 48, 48, 24)
            setShadowLayer(8f, 0f, 0f, 0xFF000000.toInt())
        }.also { titleView = it }
        root.addView(
            titleTv,
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
                Gravity.TOP,
            ),
        )

        val status = TextView(this).apply {
            text = "Opening…"
            setTextColor(0xCCFFFFFF.toInt())
            textSize = 16f
            setPadding(48, 0, 48, 48)
        }.also { statusView = it }
        root.addView(
            status,
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
                Gravity.BOTTOM,
            ),
        )

        val bar = ProgressBar(this).apply {
            isIndeterminate = true
            visibility = View.VISIBLE
        }.also { progress = it }
        root.addView(
            bar,
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
                Gravity.CENTER,
            ),
        )

        setContentView(root)
        statusView?.text = "Surface ready soon · Soft decode · D-pad: OK play/pause · ←/→ ±10s · Back exit"
    }

    override fun surfaceCreated(holder: SurfaceHolder) {
        surfaceReady = true
        ensurePlayer()
        attachAndPlay()
    }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
        player?.vlcVout?.setWindowSize(width, height)
    }

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        surfaceReady = false
        try {
            player?.vlcVout?.detachViews()
        } catch (_: Exception) {
        }
    }

    private fun ensurePlayer() {
        if (libVLC != null) return
        // Soft decode — same defaults we want to validate on Realtek.
        val options = arrayListOf(
            "--network-caching=2500",
            "--file-caching=1500",
            "--clock-synchro=1",
            "--avcodec-hw=none",
            "--http-reconnect",
        )
        val lib = LibVLC(this, options)
        val mp = MediaPlayer(lib)
        libVLC = lib
        player = mp
        mp.setEventListener { event ->
            when (event.type) {
                MediaPlayer.Event.Opening -> setStatus("Opening…")
                MediaPlayer.Event.Buffering -> {
                    val b = event.buffering
                    setStatus("Buffering ${b.toInt()}%")
                    progress?.visibility = if (b in 0f..99.5f) View.VISIBLE else View.GONE
                }
                MediaPlayer.Event.Playing -> {
                    setStatus("Playing · SurfaceView OK")
                    progress?.visibility = View.GONE
                    titleView?.animate()?.alpha(0f)?.setDuration(1200)?.start()
                }
                MediaPlayer.Event.Paused -> {
                    setStatus("Paused")
                    titleView?.animate()?.alpha(1f)?.setDuration(200)?.start()
                }
                MediaPlayer.Event.EncounteredError -> setStatus("ERROR — decode/playback failed")
                MediaPlayer.Event.EndReached -> setStatus("Ended")
                else -> Unit
            }
        }
    }

    private fun attachAndPlay() {
        val url = pendingUrl ?: return
        val mp = player ?: return
        val surface = surfaceView ?: return
        if (!surfaceReady) return
        try {
            val vout = mp.vlcVout
            vout.setVideoView(surface)
            vout.attachViews()
            vout.setWindowSize(surface.width.coerceAtLeast(1280), surface.height.coerceAtLeast(720))
            val media = Media(libVLC, Uri.parse(url))
            media.setHWDecoderEnabled(false, false)
            media.addOption(":network-caching=2500")
            mp.media = media
            media.release()
            mp.play()
            Log.i(TAG, "lab play $url")
        } catch (e: Exception) {
            Log.e(TAG, "attachAndPlay failed", e)
            setStatus("Failed: ${e.message}")
        }
    }

    private fun setStatus(msg: String) {
        main.post { statusView?.text = msg }
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean {
        val mp = player
        when (keyCode) {
            KeyEvent.KEYCODE_DPAD_CENTER, KeyEvent.KEYCODE_ENTER, KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE -> {
                if (mp == null) return true
                if (mp.isPlaying) mp.pause() else mp.play()
                return true
            }
            KeyEvent.KEYCODE_MEDIA_PLAY -> {
                mp?.play()
                return true
            }
            KeyEvent.KEYCODE_MEDIA_PAUSE -> {
                mp?.pause()
                return true
            }
            KeyEvent.KEYCODE_DPAD_RIGHT, KeyEvent.KEYCODE_MEDIA_FAST_FORWARD -> {
                if (mp != null) mp.time = (mp.time + 10_000).coerceAtLeast(0)
                return true
            }
            KeyEvent.KEYCODE_DPAD_LEFT, KeyEvent.KEYCODE_MEDIA_REWIND -> {
                if (mp != null) mp.time = (mp.time - 10_000).coerceAtLeast(0)
                return true
            }
            KeyEvent.KEYCODE_BACK -> {
                finish()
                return true
            }
        }
        return super.onKeyDown(keyCode, event)
    }

    override fun onStop() {
        player?.pause()
        super.onStop()
    }

    override fun onDestroy() {
        try {
            player?.stop()
            player?.vlcVout?.detachViews()
            player?.release()
        } catch (_: Exception) {
        }
        player = null
        try {
            libVLC?.release()
        } catch (_: Exception) {
        }
        libVLC = null
        super.onDestroy()
    }

    companion object {
        private const val TAG = "TvLabPlayer"
        const val EXTRA_URL = "url"
        const val EXTRA_TITLE = "title"

        fun intent(context: Context, url: String, title: String): Intent {
            return Intent(context, TvLabPlayerActivity::class.java).apply {
                putExtra(EXTRA_URL, url)
                putExtra(EXTRA_TITLE, title)
            }
        }
    }
}
