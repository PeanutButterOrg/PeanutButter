package app.peanutbutter.tv.player

import android.content.Context
import android.net.Uri
import android.view.TextureView
import android.view.View
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.TrackSelectionOverride
import androidx.media3.common.text.CueGroup
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.ui.AspectRatioFrameLayout
import androidx.media3.ui.SubtitleView
import java.io.File

/**
 * Jellyfin-style Android TV playback:
 * Media3 ExoPlayer, MediaCodec first, FFmpeg (bundled) when hardware decode fails,
 * Surface video, AudioTrack audio, container subtitles on [SubtitleView].
 */
class TvPlayback(
    context: Context,
    private val listener: PlaybackEngine.Listener,
) : PlaybackEngine {

    private val appContext = context.applicationContext
    private var exo: ExoPlayer = buildPlayer(preferSoftware = false)
    private var software = false
    private var textureView: TextureView? = null
    private var subtitles: SubtitleView? = null
    private var frame: AspectRatioFrameLayout? = null
    private var aspectMode = "fit"
    private var videoWidth = 0
    private var videoHeight = 0
    private var placedW = 0
    private var placedH = 0
    private var placedMode = ""
    private var lastViewW = 0
    private var lastViewH = 0

    override val length: Long
        get() {
            val d = exo.duration
            return if (d == C.TIME_UNSET || d < 0) 0L else d
        }

    override var time: Long
        get() = exo.currentPosition.coerceAtLeast(0L)
        set(value) {
            seekTo(value)
        }

    override val isPlaying: Boolean
        get() = exo.isPlaying

    override fun seekTo(positionMs: Long) {
        val target = positionMs.coerceAtLeast(0L)
        val cur = exo.currentPosition.coerceAtLeast(0L)
        val jump = kotlin.math.abs(target - cur)
        val uri = exo.currentMediaItem?.localConfiguration?.uri
        // Large scrub on a growing HTTP torrent: pause+seekTo often snaps to 0.
        // Re-open the same URL at the new position so Exo issues a fresh Range.
        if (jump > 12_000L && uri != null) {
            val play = exo.playWhenReady || exo.isPlaying
            exo.setMediaItem(MediaItem.fromUri(uri), target)
            exo.prepare()
            exo.playWhenReady = play
            if (play) exo.play()
        } else {
            exo.seekTo(target)
        }
    }

    fun attachFrame(layout: AspectRatioFrameLayout?) {
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

    private fun applyAspect() {
        val layout = frame ?: return
        val (viewW, viewH) = VideoAspect.viewport(layout)
        val box = VideoAspect.target(aspectMode, viewW, viewH, videoWidth, videoHeight)
        if (box.width == placedW && box.height == placedH && aspectMode == placedMode) return
        placedW = box.width
        placedH = box.height
        placedMode = aspectMode
        VideoAspect.place(layout, box)
        subtitles?.let { VideoAspect.place(it, box) }
        layout.setAspectRatio(box.width.toFloat() / box.height)
        layout.resizeMode = AspectRatioFrameLayout.RESIZE_MODE_FILL
        val scaling = if (aspectMode == "fill") {
            C.VIDEO_SCALING_MODE_SCALE_TO_FIT_WITH_CROPPING
        } else {
            C.VIDEO_SCALING_MODE_SCALE_TO_FIT
        }
        runCatching { exo.videoScalingMode = scaling }
    }

    override fun bindSubtitles(view: SubtitleView?) {
        subtitles = view
        view?.setApplyEmbeddedStyles(true)
        view?.setBottomPaddingFraction(0.08f)
    }

    override fun attachTexture(view: TextureView?) {
        textureView = view
        exo.setVideoTextureView(view)
    }

    override fun open(url: String, resumeMs: Long, preferSoftware: Boolean) {
        if (preferSoftware != software) {
            val keep = textureView
            releasePlayerOnly()
            software = preferSoftware
            exo = buildPlayer(preferSoftware)
            exo.setVideoTextureView(keep)
        }
        listener.onOpening()
        val item = MediaItem.fromUri(url)
        val start = resumeMs.coerceAtLeast(0L)
        if (start > 2_000) exo.setMediaItem(item, start) else exo.setMediaItem(item)
        exo.prepare()
        exo.playWhenReady = true
    }

    override fun play() {
        exo.playWhenReady = true
        exo.play()
    }

    override fun pause() {
        exo.pause()
    }

    override fun stop() {
        exo.stop()
    }

    override fun listTextTracks(): List<Pair<String, String>> {
        val out = ArrayList<Pair<String, String>>()
        val groups = exo.currentTracks.groups
        for (gi in groups.indices) {
            val group = groups[gi]
            if (group.type != C.TRACK_TYPE_TEXT) continue
            for (ti in 0 until group.length) {
                val fmt = group.getTrackFormat(ti)
                val label = fmt.label?.takeIf { it.isNotBlank() }
                    ?: fmt.language?.takeIf { it.isNotBlank() }
                    ?: "Subtitle"
                out += "$gi:$ti" to label
            }
        }
        return out
    }

    override fun selectTextTrack(id: String?) {
        val builder = exo.trackSelectionParameters.buildUpon()
            .clearOverridesOfType(C.TRACK_TYPE_TEXT)
        if (id == null) {
            exo.trackSelectionParameters = builder
                .setTrackTypeDisabled(C.TRACK_TYPE_TEXT, true)
                .build()
            subtitles?.setCues(emptyList())
            return
        }
        val parts = id.split(':')
        val gi = parts.getOrNull(0)?.toIntOrNull() ?: return
        val ti = parts.getOrNull(1)?.toIntOrNull() ?: return
        val group = exo.currentTracks.groups.getOrNull(gi) ?: return
        if (group.type != C.TRACK_TYPE_TEXT || ti !in 0 until group.length) return
        exo.trackSelectionParameters = builder
            .setTrackTypeDisabled(C.TRACK_TYPE_TEXT, false)
            .setOverrideForType(TrackSelectionOverride(group.mediaTrackGroup, listOf(ti)))
            .build()
    }

    override fun addExternalSubtitle(file: File, label: String, mimeType: String) {
        val item = exo.currentMediaItem ?: return
        val mime = mimeType.ifBlank { MimeTypes.APPLICATION_SUBRIP }
        val conf = MediaItem.SubtitleConfiguration.Builder(Uri.fromFile(file))
            .setMimeType(mime)
            .setLabel(label)
            .setSelectionFlags(C.SELECTION_FLAG_DEFAULT)
            .build()
        val existing = item.localConfiguration?.subtitleConfigurations.orEmpty()
        val next = item.buildUpon().setSubtitleConfigurations(existing + conf).build()
        val pos = exo.currentPosition.coerceAtLeast(0L)
        val play = exo.playWhenReady
        exo.setMediaItem(next, pos)
        exo.prepare()
        exo.playWhenReady = play
        exo.trackSelectionParameters = exo.trackSelectionParameters.buildUpon()
            .setTrackTypeDisabled(C.TRACK_TYPE_TEXT, false)
            .build()
    }

    override fun release() {
        subtitles = null
        releasePlayerOnly()
    }

    private fun releasePlayerOnly() {
        runCatching {
            exo.setVideoTextureView(null)
            exo.release()
        }
    }

    private fun buildPlayer(preferSoftware: Boolean): ExoPlayer {
        val mode = if (preferSoftware) {
            DefaultRenderersFactory.EXTENSION_RENDERER_MODE_PREFER
        } else {
            // MediaCodec first. FFmpeg renderers run when the hardware decoder cannot.
            DefaultRenderersFactory.EXTENSION_RENDERER_MODE_ON
        }
        val renderers = DefaultRenderersFactory(appContext)
            .setEnableDecoderFallback(true)
            .setExtensionRendererMode(mode)
        val load = DefaultLoadControl.Builder()
            // After an underrun, resume with a smaller requirement so playback
            // restarts as soon as the next torrent pieces arrive.
            .setBufferDurationsMs(
                /* minBufferMs */ 15_000,
                /* maxBufferMs */ 60_000,
                /* bufferForPlaybackMs */ 1_200,
                /* bufferForPlaybackAfterRebufferMs */ 1_500,
            )
            .build()
        return ExoPlayer.Builder(appContext)
            .setRenderersFactory(renderers)
            .setLoadControl(load)
            .build()
            .also { player ->
                player.addListener(object : Player.Listener {
                    override fun onPlaybackStateChanged(playbackState: Int) {
                        when (playbackState) {
                            Player.STATE_BUFFERING ->
                                listener.onBuffering(player.bufferedPercentage.coerceIn(0, 100))
                            Player.STATE_READY -> {
                                val dur = player.duration
                                if (dur != C.TIME_UNSET && dur > 0) listener.onDuration(dur)
                                if (player.isPlaying) listener.onPlaying()
                            }
                            Player.STATE_ENDED -> listener.onEnded()
                            else -> Unit
                        }
                    }

                    override fun onIsPlayingChanged(isPlaying: Boolean) {
                        if (isPlaying) listener.onPlaying()
                        else if (player.playbackState == Player.STATE_READY) listener.onPaused()
                    }

                    override fun onPlayerError(error: PlaybackException) {
                        listener.onError()
                    }

                    override fun onVideoSizeChanged(videoSize: androidx.media3.common.VideoSize) {
                        if (videoSize.width <= 0 || videoSize.height <= 0) return
                        val swap = videoSize.unappliedRotationDegrees == 90 ||
                            videoSize.unappliedRotationDegrees == 270
                        val codedW = if (swap) videoSize.height else videoSize.width
                        val codedH = if (swap) videoSize.width else videoSize.height
                        val pixel = videoSize.pixelWidthHeightRatio.takeIf { it > 0f } ?: 1f
                        videoWidth = (codedW * pixel).toInt().coerceAtLeast(1)
                        videoHeight = codedH.coerceAtLeast(1)
                        placedW = 0
                        placedH = 0
                        applyAspect()
                    }

                    override fun onCues(cueGroup: CueGroup) {
                        subtitles?.setCues(cueGroup.cues)
                    }

                    override fun onEvents(player: Player, events: Player.Events) {
                        if (events.contains(Player.EVENT_POSITION_DISCONTINUITY) ||
                            events.contains(Player.EVENT_IS_PLAYING_CHANGED)
                        ) {
                            listener.onTime(player.currentPosition.coerceAtLeast(0L))
                        }
                    }
                })
            }
    }
}
