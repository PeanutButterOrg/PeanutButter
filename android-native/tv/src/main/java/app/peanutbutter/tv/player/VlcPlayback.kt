package app.peanutbutter.tv.player

import android.content.Context
import android.net.Uri
import android.view.SurfaceHolder
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
    private var holder: SurfaceHolder? = null
    private var software = false
    private var aspectMode = "fit"

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

    override fun attachDisplay(holder: SurfaceHolder?) {
        this.holder = holder
        val vout = mp?.vlcVout ?: return
        if (holder == null) {
            if (vout.areViewsAttached()) vout.detachViews()
            return
        }
        if (!vout.areViewsAttached()) {
            vout.setVideoSurface(holder.surface, holder)
            vout.attachViews()
        }
        val frame = holder.surfaceFrame
        vout.setWindowSize(frame.width().coerceAtLeast(1280), frame.height().coerceAtLeast(720))
    }

    override fun open(url: String, resumeMs: Long, preferSoftware: Boolean) {
        if (mp == null || preferSoftware != software) {
            val keep = holder
            releasePlayerOnly()
            software = preferSoftware
            build()
            attachDisplay(keep)
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

    override fun setAspectMode(mode: String) {
        aspectMode = mode
        applyAspect()
    }

    private fun applyAspect() {
        val player = mp ?: return
        val dm = appContext.resources.displayMetrics
        when (aspectMode) {
            "fill" -> {
                player.aspectRatio = null
                player.scale = 0f
            }
            "stretch" -> {
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
            "original" -> {
                val track = player.currentVideoTrack
                val dm = appContext.resources.displayMetrics
                player.aspectRatio = null
                player.scale = if (track != null && track.width > 0 && track.height > 0) {
                    minOf(
                        dm.widthPixels.toFloat() / track.width,
                        dm.heightPixels.toFloat() / track.height,
                    ).coerceAtMost(1f)
                } else {
                    1f
                }
            }
            else -> {
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
        mp = null
        runCatching { libVLC?.release() }
        libVLC = null
    }
}
