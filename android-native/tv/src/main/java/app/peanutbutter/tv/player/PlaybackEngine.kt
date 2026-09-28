package app.peanutbutter.tv.player

import android.view.TextureView
import androidx.media3.ui.SubtitleView
import java.io.File

/** Shared controls for the ExoPlayer and LibVLC backends. */
interface PlaybackEngine {
    interface Listener {
        fun onOpening()
        fun onBuffering(percent: Int)
        fun onPlaying()
        fun onPaused()
        fun onError()
        fun onEnded()
        fun onTime(positionMs: Long)
        fun onDuration(durationMs: Long)
    }

    val length: Long
    var time: Long
    val isPlaying: Boolean

    fun bindSubtitles(view: SubtitleView?)
    fun attachTexture(view: TextureView?)
    fun open(url: String, resumeMs: Long, preferSoftware: Boolean)
    fun play()
    fun pause()
    fun stop()
    fun release()

    /**
     * Seek to [positionMs]. For progressive HTTP torrents, large jumps should
     * reopen the media item so Exo issues a fresh Range request.
     */
    fun seekTo(positionMs: Long) {
        time = positionMs
    }

    /** Embedded caption tracks. Id is engine-specific. */
    fun listTextTracks(): List<Pair<String, String>>

    /** `null` turns captions off. */
    fun selectTextTrack(id: String?)

    /** Side-load an SRT/VTT/ASS file and show it. */
    fun addExternalSubtitle(file: File, label: String, mimeType: String)

    /**
     * `fit`, `fill`, `stretch`, `16:9`, or `4:3`.
     * [videoRatio] is the decoded picture ratio, used by Fit and Fill.
     */
    fun setAspectMode(mode: String)
}
