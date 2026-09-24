package app.peanutbutter.peanutbutter

import android.app.Activity
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.Surface
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import org.videolan.libvlc.LibVLC
import org.videolan.libvlc.Media
import org.videolan.libvlc.MediaPlayer
import org.videolan.libvlc.interfaces.IMedia
import org.videolan.libvlc.interfaces.IVLCVout

/**
 * In-process libVLC that paints into a Flutter [TextureRegistry] surface.
 *
 * The Dart side displays [Texture(textureId: …)] under the normal player chrome
 * (seekbar, skip, next episode, audio/subs). Avoids SurfaceView (covers Flutter
 * on Realtek) and AndroidView PlatformViews (never attach on rtd285o).
 */
class NativeVlcPlayer(
    private val activity: Activity,
    messenger: BinaryMessenger,
    private val textures: TextureRegistry,
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler, IVLCVout.OnNewVideoLayoutListener {
    private val main = Handler(Looper.getMainLooper())
    private val methodChannel = MethodChannel(messenger, CHANNEL)
    private val eventChannel = EventChannel(messenger, EVENTS)

    private var textureEntry: TextureRegistry.SurfaceTextureEntry? = null
    private var surface: Surface? = null
    private var libVLC: LibVLC? = null
    private var mediaPlayer: MediaPlayer? = null
    private var eventSink: EventChannel.EventSink? = null
    private var videoWidth = 0
    private var videoHeight = 0

    init {
        methodChannel.setMethodCallHandler(this)
        eventChannel.setStreamHandler(this)
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> {
                val url = call.argument<String>("url")
                if (url.isNullOrBlank()) {
                    result.error("bad_args", "url required", null)
                    return
                }
                val startMs = (call.argument<Number>("startMs")?.toLong() ?: 0L).coerceAtLeast(0L)
                val rawHeaders = call.argument<Map<*, *>>("headers") ?: emptyMap<Any, Any>()
                val headers = linkedMapOf<String, String>()
                for ((k, v) in rawHeaders) {
                    if (k != null && v != null) {
                        headers[k.toString()] = v.toString()
                    }
                }
                val textureId = start(url, startMs, headers)
                if (textureId < 0) {
                    result.error("vlc_start", "Could not create VLC texture", null)
                } else {
                    result.success(mapOf("textureId" to textureId))
                }
            }
            "stop" -> {
                stop()
                result.success(true)
            }
            "dispose" -> {
                dispose()
                result.success(true)
            }
            "play" -> {
                mediaPlayer?.play()
                result.success(true)
            }
            "pause" -> {
                mediaPlayer?.pause()
                result.success(true)
            }
            "seek" -> {
                val ms = call.argument<Number>("ms")?.toLong() ?: 0L
                mediaPlayer?.time = ms.coerceAtLeast(0L)
                result.success(true)
            }
            "setSurfaceSize" -> {
                val w = call.argument<Number>("width")?.toInt() ?: 0
                val h = call.argument<Number>("height")?.toInt() ?: 0
                if (w > 0 && h > 0) {
                    textureEntry?.surfaceTexture()?.setDefaultBufferSize(w, h)
                    mediaPlayer?.vlcVout?.setWindowSize(w, h)
                }
                result.success(true)
            }
            "isPlaying" -> result.success(mediaPlayer?.isPlaying == true)
            "getAudioTracks" -> result.success(trackList(mediaPlayer?.audioTracks))
            "getSpuTracks" -> result.success(trackList(mediaPlayer?.spuTracks))
            "setAudioTrack" -> {
                val id = call.argument<Number>("id")?.toInt()
                if (id == null) {
                    result.error("bad_args", "id required", null)
                    return
                }
                mediaPlayer?.setAudioTrack(id)
                result.success(true)
            }
            "setSpuTrack" -> {
                val id = call.argument<Number>("id")?.toInt() ?: -1
                mediaPlayer?.setSpuTrack(id)
                result.success(true)
            }
            "addSubtitle" -> {
                val uri = call.argument<String>("uri")
                if (uri.isNullOrBlank()) {
                    result.error("bad_args", "uri required", null)
                    return
                }
                val player = mediaPlayer
                if (player == null) {
                    result.error("no_player", "VLC not started", null)
                    return
                }
                val ok = player.addSlave(IMedia.Slave.Type.Subtitle, Uri.parse(uri), true)
                result.success(ok)
            }
            "getPosition" -> {
                val player = mediaPlayer
                result.success(
                    mapOf(
                        "position" to (player?.time ?: 0L),
                        "duration" to (player?.length ?: 0L),
                        "playing" to (player?.isPlaying == true),
                        "width" to videoWidth,
                        "height" to videoHeight,
                    ),
                )
            }
            else -> result.notImplemented()
        }
    }

    private fun trackList(tracks: Array<MediaPlayer.TrackDescription>?): List<Map<String, Any>> {
        if (tracks == null) return emptyList()
        return tracks.map { t ->
            mapOf(
                "id" to t.id,
                "name" to (t.name ?: "Track ${t.id}"),
            )
        }
    }

    private fun start(url: String, startMs: Long, headers: Map<String, String>): Long {
        stop()
        emit(mapOf("event" to "opening"))
        preloadNativeLibs()

        val entry = textures.createSurfaceTexture()
        textureEntry = entry
        val st = entry.surfaceTexture()
        val dm = activity.resources.displayMetrics
        val bufW = dm.widthPixels.coerceAtLeast(1280)
        val bufH = dm.heightPixels.coerceAtLeast(720)
        st.setDefaultBufferSize(bufW, bufH)
        val surf = Surface(st)
        surface = surf

        // Software decode by default on Flutter Texture — HW MediaCodec often
        // paints green / desyncs on Realtek TV boxes. Soft is slower but viewable.
        val options = arrayListOf(
            "--network-caching=2500",
            "--file-caching=1500",
            "--live-caching=1500",
            "--clock-synchro=1",
            "--clock-jitter=0",
            "--audio-time-stretch",
            "--http-reconnect",
            "--no-drop-late-frames",
            "--no-skip-frames",
            "--avcodec-skiploopfilter=1",
            "--avcodec-hw=none",
        )
        val lib = LibVLC(activity, options)
        val player = MediaPlayer(lib)
        libVLC = lib
        mediaPlayer = player

        player.setEventListener { event ->
            when (event.type) {
                MediaPlayer.Event.Opening -> emit(mapOf("event" to "opening"))
                MediaPlayer.Event.Playing -> {
                    emit(
                        mapOf(
                            "event" to "playing",
                            "position" to player.time,
                            "duration" to player.length,
                            "width" to videoWidth,
                            "height" to videoHeight,
                        ),
                    )
                    emitTracks(player)
                }
                MediaPlayer.Event.Paused -> emit(
                    mapOf(
                        "event" to "paused",
                        "position" to player.time,
                        "duration" to player.length,
                    ),
                )
                MediaPlayer.Event.Stopped -> emit(mapOf("event" to "stopped"))
                MediaPlayer.Event.EndReached -> emit(
                    mapOf("event" to "ended", "position" to player.time),
                )
                MediaPlayer.Event.EncounteredError -> emit(
                    mapOf("event" to "error", "message" to "libVLC playback error"),
                )
                MediaPlayer.Event.Buffering -> emit(
                    mapOf(
                        "event" to "buffering",
                        "buffering" to event.buffering.toDouble(),
                        "position" to player.time,
                        "duration" to player.length,
                    ),
                )
                MediaPlayer.Event.TimeChanged -> emit(
                    mapOf(
                        "event" to "timeChanged",
                        "position" to player.time,
                        "duration" to player.length,
                        "playing" to player.isPlaying,
                    ),
                )
                MediaPlayer.Event.Vout -> {
                    emit(mapOf("event" to "vout", "count" to event.voutCount))
                    emitTracks(player)
                }
                else -> Unit
            }
        }

        val vout = player.vlcVout
        vout.setVideoSurface(surf, null)
        vout.attachViews(this)
        vout.setWindowSize(bufW, bufH)
        player.setVideoTrackEnabled(true)
        player.videoScale = MediaPlayer.ScaleType.SURFACE_FIT_SCREEN

        val media = Media(lib, Uri.parse(url))
        // Soft decode into Texture — HW often yields green frames on Realtek.
        media.setHWDecoderEnabled(false, false)
        for ((key, value) in headers) {
            media.addOption(":http-header=$key: $value")
        }
        media.addOption(":network-caching=2500")
        media.addOption(":clock-synchro=1")
        // Force seekable progressive HTTP so Range seeks work for torrents.
        media.addOption(":http-continuous=")
        media.addOption(":seekable=1")
        player.media = media
        media.release()
        player.play()
        if (startMs > 0) {
            main.postDelayed({
                if (mediaPlayer === player) player.time = startMs
            }, 800)
        }
        Log.i(TAG, "libVLC soft-decode texture=${entry.id()} url=${url.take(96)}")
        return entry.id()
    }

    override fun onNewVideoLayout(
        vlcVout: IVLCVout,
        width: Int,
        height: Int,
        visibleWidth: Int,
        visibleHeight: Int,
        sarNum: Int,
        sarDen: Int,
    ) {
        videoWidth = width
        videoHeight = height
        // Keep the SurfaceTexture buffer at display size so Flutter's Texture
        // widget (fullscreen) isn't left with a postage-stamp of pixels.
        emit(
            mapOf(
                "event" to "layout",
                "width" to width,
                "height" to height,
            ),
        )
    }

    private fun stop() {
        stopPlayerOnly()
        surface?.release()
        surface = null
        textureEntry?.release()
        textureEntry = null
        videoWidth = 0
        videoHeight = 0
        emit(mapOf("event" to "stopped"))
    }

    private fun stopPlayerOnly() {
        val player = mediaPlayer
        mediaPlayer = null
        if (player != null) {
            try {
                player.stop()
            } catch (_: Exception) {
            }
            try {
                player.vlcVout.detachViews()
            } catch (_: Exception) {
            }
            try {
                player.release()
            } catch (_: Exception) {
            }
        }
        val lib = libVLC
        libVLC = null
        if (lib != null) {
            try {
                lib.release()
            } catch (_: Exception) {
            }
        }
    }

    fun dispose() {
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        eventSink = null
        stop()
    }

    private fun emitTracks(player: MediaPlayer) {
        emit(
            mapOf(
                "event" to "tracks",
                "audio" to trackList(player.audioTracks),
                "spu" to trackList(player.spuTracks),
                "audioId" to player.audioTrack,
                "spuId" to player.spuTrack,
            ),
        )
    }

    private fun emit(payload: Map<String, Any?>) {
        main.post {
            try {
                eventSink?.success(payload)
            } catch (e: Exception) {
                Log.w(TAG, "event sink failed: $e")
            }
        }
    }

    companion object {
        private const val TAG = "PeanutButterVLC"
        const val CHANNEL = "app.peanutbutter/vlc"
        const val EVENTS = "app.peanutbutter/vlcEvents"

        @Volatile
        private var libsLoaded = false

        /**
         * libmla.so (bundled in jniLibs) needs libvlc + c++_shared. Load in order
         * before MediaPlayer opens codecs — crashes without MLA on many streams.
         */
        fun preloadNativeLibs() {
            if (libsLoaded) return
            synchronized(this) {
                if (libsLoaded) return
                try {
                    System.loadLibrary("c++_shared")
                } catch (e: Throwable) {
                    Log.w(TAG, "c++_shared preload: $e")
                }
                try {
                    System.loadLibrary("vlc")
                } catch (e: Throwable) {
                    Log.w(TAG, "libvlc preload: $e")
                }
                try {
                    System.loadLibrary("mla")
                    Log.i(TAG, "libmla.so loaded")
                } catch (e: Throwable) {
                    Log.e(TAG, "libmla preload failed — playback may crash: $e")
                }
                libsLoaded = true
            }
        }
    }
}