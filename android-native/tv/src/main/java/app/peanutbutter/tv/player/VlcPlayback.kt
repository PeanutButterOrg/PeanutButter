package app.peanutbutter.tv.player

import android.content.Context
import android.net.Uri
import android.view.Surface
import android.view.TextureView
import android.view.View
import androidx.media3.ui.SubtitleView
import org.videolan.libvlc.LibVLC
import org.videolan.libvlc.Media
import org.videolan.libvlc.MediaPlayer
import java.io.File

/**
 * LibVLC backend: FFmpeg software codecs bundled with LibVLC, Android MediaCodec
 * when hardware decode is on, video on a Surface, audio on AudioTrack.
 * Embedded subtitles are drawn by VLC on the video surface.
 */
class VlcPlayback(
    context: Context,
    private val listener: PlaybackEngine.Listener,
) : PlaybackEngine {
    private val appContext = context.applicationContext
    private var libVLC: LibVLC? = null
    private var mp: MediaPlayer? = null
    private var texture: TextureView? = null
    private var surface: Surface? = null
    private var software = false
    private var aspectMode = "fit"
    private var frame: View? = null
    private var placedW = 0
    private var placedH = 0
    private var placedMode = ""
    private var lastViewW = 0
    private var lastViewH = 0

    override val length: Long
        get() = (mp?.length ?: 0L).coerceAtLeast(0L)

    override var time: Long
        get() = (mp?.time ?: 0L).coerceAtLeast(0L)
        set(value) {
            mp?.time = value.coerceAtLeast(0L)
        }

    override val isPlaying: Boolean
        get() = mp?.isPlaying == true

    override fun bindSubtitles(view: SubtitleView?) {
        view?.setCues(emptyList())
    }

    override fun attachTexture(view: TextureView?) {
        texture = view
        val vout = mp?.vlcVout
        val tex = view?.surfaceTexture
        if (view == null || tex == null) {
            if (vout != null && vout.areViewsAttached()) vout.detachViews()
            surface?.release()
            surface = null
            return
        }
        val next = Surface(tex)
        surface?.release()
        surface = next
        if (vout == null) return
        vout.setVideoSurface(next, null)
        if (!vout.areViewsAttached()) vout.attachViews()
        val w = view.width.takeIf { it > 0 } ?: appContext.resources.displayMetrics.widthPixels
        val h = view.height.takeIf { it > 0 } ?: appContext.resources.displayMetrics.heightPixels
        vout.setWindowSize(w, h)
    }

    override fun open(url: String, resumeMs: Long, preferSoftware: Boolean) {
        if (mp == null || preferSoftware != software) {
            val keep = texture
            releasePlayerOnly()
            software = preferSoftware
            build()
            attachTexture(keep)
        }
        val lib = libVLC ?: return
        val player = mp ?: return
        listener.onOpening()
        val media = Media(lib, Uri.parse(url))
        media.setHWDecoderEnabled(!preferSoftware, false)
        media.addOption(":network-caching=8000")
        media.addOption(":file-caching=3000")
        media.addOption(":http-reconnect")
        if (resumeMs > 2_000) media.addOption(":start-time=${resumeMs / 1000.0}")
        player.media = media
        media.release()
        player.play()
        applyAspect()
    }

    override fun play() {
        mp?.play()
    }

    override fun seekTo(positionMs: Long) {
        val player = mp ?: return
        player.time = positionMs.coerceAtLeast(0L)
        // Scrubbing must resume — VLC can sit paused after a time jump.
        player.play()
    }

    override fun pause() {
        mp?.pause()
    }

    override fun stop() {
        runCatching { mp?.stop() }
    }

    override fun listTextTracks(): List<Pair<String, String>> {
        val tracks = mp?.spuTracks ?: return emptyList()
        return tracks.map { it.id.toString() to (it.name?.takeIf { n -> n.isNotBlank() } ?: "Subtitle") }
    }

    override fun selectTextTrack(id: String?) {
        mp?.spuTrack = id?.toIntOrNull() ?: -1
    }

    fun attachFrame(layout: View?) {
        frame = layout
        val parent = layout?.parent as? View
        parent?.addOnLayoutChangeListener { _, left, top, right, bottom, _, _, _, _ ->
            val w = right - left
            val h = bottom - top
            if (w == lastViewW && h == lastViewH) return@addOnLayoutChangeListener
            lastViewW = w
            lastViewH = h
            placedW = 0
            placedH = 0
            applyAspect()
        }
        applyAspect()
    }

    override fun setAspectMode(mode: String) {
        aspectMode = mode
        placedW = 0
        placedH = 0
        applyAspect()
    }

    private fun videoSize(): Pair<Int, Int> {
        val track = mp?.currentVideoTrack ?: return 0 to 0
        if (track.width <= 0 || track.height <= 0) return 0 to 0
        val sar = if (track.sarNum > 0 && track.sarDen > 0) {
            track.sarNum.toFloat() / track.sarDen
        } else {
            1f
        }
        return (track.width * sar).toInt().coerceAtLeast(1) to track.height
    }

    private fun applyAspect() {
        val layout = frame
        val (videoW, videoH) = videoSize()
        if (layout != null) {
            val (viewW, viewH) = VideoAspect.viewport(layout)
            val box = VideoAspect.target(aspectMode, viewW, viewH, videoW, videoH)
            if (box.width != placedW || box.height != placedH || aspectMode != placedMode) {
                placedW = box.width
                placedH = box.height
                placedMode = aspectMode
                VideoAspect.place(layout, box)
            }
            mp?.vlcVout?.setWindowSize(box.width, box.height)
        }
        val player = mp ?: return
        when (aspectMode) {
            "stretch" -> {
                val dm = appContext.resources.displayMetrics
                player.scale = 0f
                player.aspectRatio = "${dm.widthPixels}:${dm.heightPixels}"
            }
            "16:9" -> {
                player.scale = 0f
                player.aspectRatio = "16:9"
            }
            "4:3" -> {
                player.scale = 0f
                player.aspectRatio = "4:3"
            }
            else -> {
                // Surface is already the right shape, so fill it without a second letterbox.
                player.aspectRatio = null
                player.scale = 0f
            }
        }
    }

    override fun addExternalSubtitle(file: File, label: String, mimeType: String) {
        // libvlc_media_slave_type_subtitle == 0
        mp?.addSlave(0, Uri.fromFile(file), true)
    }

    override fun release() {
        releasePlayerOnly()
    }

    private fun build() {
        val options = arrayListOf(
            "--network-caching=8000",
            "--file-caching=3000",
            "--http-reconnect",
            "--no-drop-late-frames",
            "--no-skip-frames",
        )
        val lib = LibVLC(appContext, options)
        val player = MediaPlayer(lib)
        libVLC = lib
        mp = player
        player.setEventListener { event ->
            when (event.type) {
                MediaPlayer.Event.Opening -> listener.onOpening()
                MediaPlayer.Event.Buffering ->
                    listener.onBuffering(event.buffering.toInt().coerceIn(0, 100))
                MediaPlayer.Event.Playing -> listener.onPlaying()
                MediaPlayer.Event.Paused -> listener.onPaused()
                MediaPlayer.Event.EncounteredError -> listener.onError()
                MediaPlayer.Event.EndReached -> listener.onEnded()
                MediaPlayer.Event.TimeChanged -> listener.onTime(event.timeChanged.coerceAtLeast(0L))
                MediaPlayer.Event.LengthChanged -> {
                    if (event.lengthChanged > 0) listener.onDuration(event.lengthChanged)
                }
                MediaPlayer.Event.Vout, MediaPlayer.Event.ESSelected -> {
                    placedW = 0
                    placedH = 0
                    applyAspect()
                }
                else -> Unit
            }
        }
    }

    private fun releasePlayerOnly() {
        runCatching {
            mp?.vlcVout?.detachViews()
            mp?.stop()
            mp?.release()
        }
        surface?.release()
        surface = null
        mp = null
        runCatching { libVLC?.release() }
        libVLC = null
    }
}
