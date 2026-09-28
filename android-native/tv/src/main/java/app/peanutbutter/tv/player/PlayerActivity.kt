package app.peanutbutter.tv.player

import android.app.AlertDialog
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.graphics.SurfaceTexture
import android.view.KeyEvent
import android.view.TextureView
import android.view.View
import android.widget.FrameLayout
import android.widget.ImageButton
import android.widget.ProgressBar
import android.widget.SeekBar
import android.widget.TextView
import android.widget.Toast
import androidx.core.view.isVisible
import androidx.fragment.app.FragmentActivity
import androidx.lifecycle.lifecycleScope
import app.peanutbutter.core.AppLog
import app.peanutbutter.core.LocalStreamStats
import app.peanutbutter.core.MediaSegment
import app.peanutbutter.core.SessionStore
import app.peanutbutter.core.StreamQuality
import app.peanutbutter.core.TitleItem
import app.peanutbutter.core.StreamSession
import app.peanutbutter.core.TorrentClient
import app.peanutbutter.tv.PbGlide
import app.peanutbutter.tv.R
import app.peanutbutter.tv.asTv
import app.peanutbutter.tv.ui.showRoundDialog
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * ExoPlayer / Media3 torrent player (Jellyfin Android TV approach):
 * MediaCodec hardware decode, FFmpeg when that fails, Surface video.
 * Debounced seek retargets the swarm; false-EOF recovery stays.
 */
class PlayerActivity : FragmentActivity(), TextureView.SurfaceTextureListener {
    private val main = Handler(Looper.getMainLooper())
    private var player: PlaybackEngine? = null
    private var surfaceReady = false
    private var pendingUrl: String? = null
    private var mediaAttached = false
    private var streamOpened = false
    private var sessionId: String? = null
    private var titleId: String? = null
    private var episodeId: String? = null
    private var lastSavedPosMs = -1L
    private var kind: String? = null
    private var seasonNum: Int? = null
    private var episodeNum: Int? = null
    private var resumeMs: Long = 0
    private var waitJob: Job? = null
    private var statusPollJob: Job? = null
    private var stopped = false
    private var chromeVisible = true
    private var isStream = false
    private var localTorrent = false
    private var magnet: String? = null
    private var fileIndex: Int? = null

    private var titleView: TextView? = null
    private var statusView: TextView? = null
    private var busy: ProgressBar? = null
    private var topProgress: ProgressBar? = null
    private var chromeTop: View? = null
    private var chromeBottom: View? = null
    private var posterHud: View? = null
    private var seek: SeekBar? = null
    private var timePos: TextView? = null
    private var timeDur: TextView? = null
    private var btnPlay: ImageButton? = null
    private var btnRew: ImageButton? = null
    private var btnFf: ImageButton? = null
    private var overlayActions: View? = null
    private var btnSkip: TextView? = null
    private var btnNext: TextView? = null
    private var btnSubs: TextView? = null
    private var btnAspect: TextView? = null
    private var leaveDialog: AlertDialog? = null

    private var segments: List<MediaSegment> = emptyList()
    private var activeSegment: MediaSegment? = null
    private var playNextVisible = false
    private var segmentsLoaded = false
    private var segmentDurationMs = -1
    private var nextEpisode: NextEpisode? = null
    private var nextLoaded = false
    private var nextBusy = false

    /** User is scrubbing — don't overwrite seek from playback ticks. */
    private var userSeeking = false
    private var seekTargetMs: Long = -1
    private var lastGoodPosMs: Long = 0
    private var seekToken = 0
    private var falseEofCount = 0
    private var stallRecoverCount = 0
    private var bufferingSinceMs = 0L
    private var lastTorrentNudgeMs = 0L
    private var lastSession: StreamSession? = null
    private var hwDecode = true

    private val hideChrome = Runnable { setChrome(false) }
    private val commitSeek = Runnable { commitPendingSeek() }
    /** Progressive torrents stall at the download edge until a Range re-request. */
    private val bufferStallRecover = Runnable { recoverFromBufferStall() }
    private val tickProgress = object : Runnable {
        override fun run() {
            updateProgressUi()
            updateSkipNext()
            main.postDelayed(this, 400L)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_player)
        titleView = findViewById(R.id.title)
        statusView = findViewById(R.id.status)
        busy = findViewById(R.id.busy)
        topProgress = findViewById(R.id.top_progress)
        chromeTop = findViewById(R.id.chrome_top)
        chromeBottom = findViewById(R.id.chrome_bottom)
        posterHud = findViewById(R.id.poster_hud)
        seek = findViewById(R.id.seek)
        timePos = findViewById(R.id.time_pos)
        timeDur = findViewById(R.id.time_dur)
        btnPlay = findViewById(R.id.btn_play)
        btnRew = findViewById(R.id.btn_rew)
        btnFf = findViewById(R.id.btn_ff)
        overlayActions = findViewById(R.id.overlay_actions)
        btnSkip = findViewById(R.id.btn_skip)
        btnNext = findViewById(R.id.btn_next)
        overlayActions?.bringToFront()
        btnSubs = findViewById(R.id.btn_subs)
        btnAspect = findViewById(R.id.btn_aspect)

        val surface = findViewById<TextureView>(R.id.surface)
        surface.surfaceTextureListener = this
        // Do NOT create VLC/Exo yet — BeyondTV is armeabi-v7a / low RAM.
        // Loading VLC + libtorrent together OOMs the player activity.
        surfaceReady = surface.isAvailable

        val title = intent.getStringExtra(EXTRA_TITLE).orEmpty()
        val rawUrl = intent.getStringExtra(EXTRA_URL)?.takeIf { it.isNotBlank() }
        sessionId = intent.getStringExtra(EXTRA_SESSION)
        titleId = intent.getStringExtra(EXTRA_TITLE_ID)
        episodeId = intent.getStringExtra(EXTRA_EPISODE_ID)?.takeIf { it.isNotBlank() }
        kind = intent.getStringExtra(EXTRA_KIND)
        seasonNum = intent.getIntExtra(EXTRA_SEASON, -1).takeIf { it > 0 }
        episodeNum = intent.getIntExtra(EXTRA_EPISODE, -1).takeIf { it > 0 }
        resumeMs = intent.getLongExtra(EXTRA_RESUME_MS, 0L).coerceAtLeast(0)
        magnet = intent.getStringExtra(EXTRA_MAGNET)
        fileIndex = intent.getIntExtra(EXTRA_FILE_INDEX, -1).takeIf { it >= 0 }
        localTorrent = intent.getBooleanExtra(EXTRA_LOCAL, false) ||
            sessionId?.startsWith("local-") == true ||
            rawUrl?.contains("127.0.0.1") == true
        isStream = !sessionId.isNullOrBlank() || localTorrent
        application.asTv().activeStreamSession = sessionId
        titleView?.text = title
        statusView?.text = getString(R.string.finding_peers)
        busy?.isVisible = true
        topProgress?.isVisible = true
        topProgress?.progress = 0
        topProgress?.secondaryProgress = 0

        pendingUrl = if (localTorrent) {
            rawUrl
        } else {
            rawUrl?.let { application.asTv().api.playableStreamUrl(it) }
                ?.takeIf { it.isNotBlank() && it != "null" }
        }
        AppLog.i(TAG, "onCreate session=$sessionId local=$localTorrent magnet=${magnet?.take(40)} pending=${pendingUrl?.take(80)}")
        Log.i(TAG, "onCreate session=$sessionId local=$localTorrent resume=$resumeMs pending=${pendingUrl?.take(100)}")
        // Only attach when we already have a URL (library files / resumed local).
        if (surfaceReady && !pendingUrl.isNullOrBlank()) attachAndPlay()

        val art = intent.getStringExtra(EXTRA_BACKDROP)?.takeIf { it.isNotBlank() }
            ?: intent.getStringExtra(EXTRA_POSTER)
        if (!art.isNullOrBlank()) {
            posterHud?.isVisible = true
            PbGlide.backdrop(findViewById(R.id.poster_art), art)
        }

        btnRew?.setOnClickListener { seekBy(-10_000); showChrome() }
        btnFf?.setOnClickListener { seekBy(10_000); showChrome() }
        btnPlay?.setOnClickListener { togglePlay() }
        btnSkip?.setOnClickListener { skipActiveSegment() }
        btnNext?.setOnClickListener { playNextEpisode() }
        btnSubs?.setOnClickListener { openSubtitles() }
        btnAspect?.setOnClickListener { openAspect() }

        listOfNotNull(btnRew, btnPlay, btnFf, btnAspect, btnSubs, seek, btnSkip, btnNext).forEach {
            it.isFocusable = true
            it.isFocusableInTouchMode = true
        }

        seek?.max = SEEK_MAX
        seek?.keyProgressIncrement = (SEEK_MAX / 50).coerceAtLeast(1) // ~2% per D-pad
        seek?.setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
            override fun onProgressChanged(sb: SeekBar?, progress: Int, fromUser: Boolean) {
                if (!fromUser) return
                val mp = player ?: return
                val len = mp.length.coerceAtLeast(0)
                if (len <= 0) return
                val target = (progress.toDouble() / SEEK_MAX * len).toLong()
                // Ignore a single spurious jump-to-zero while mid-playback (common on TV
                // focus/key events). Real scrub-to-start needs several left ticks.
                if (target < 2_000L && lastGoodPosMs > 15_000L && progress <= SEEK_MAX / 40) {
                    val nearStartSteps = progress
                    if (nearStartSteps == 0 && seekTargetMs < 0) return
                }
                seekTargetMs = target
                userSeeking = true
                timePos?.text = formatMs(target)
                statusView?.text = "Seeking ${formatMs(target)}…"
                // Debounce — UI only on each tick; commit once settling.
                main.removeCallbacks(commitSeek)
                seekToken++
                val token = seekToken
                main.postDelayed({
                    if (token != seekToken) return@postDelayed
                    commitPendingSeek()
                }, 700L)
            }

            override fun onStartTrackingTouch(sb: SeekBar?) {
                userSeeking = true
                showChrome()
                main.removeCallbacks(commitSeek)
            }

            override fun onStopTrackingTouch(sb: SeekBar?) {
                // Keep userSeeking true until commit finishes — otherwise the progress
                // ticker overwrites the thumb before we apply the scrub.
                if (seekTargetMs >= 0) {
                    seekToken++
                    val token = seekToken
                    main.removeCallbacks(commitSeek)
                    main.postDelayed({
                        if (token != seekToken) return@postDelayed
                        commitPendingSeek()
                    }, 80L)
                } else {
                    userSeeking = false
                }
                scheduleHideChrome()
            }
        })

        val sid = sessionId
        if (localTorrent) {
            val mag = magnet
            if (!mag.isNullOrBlank() && pendingUrl.isNullOrBlank()) {
                // Flutter parity: start on-device torrent inside the player.
                waitJob = lifecycleScope.launch { startLocalTorrentAndPlay(mag) }
            } else if (!pendingUrl.isNullOrBlank()) {
                attachAndPlay()
                startLocalStatusPolling()
            } else {
                statusView?.text = getString(R.string.stream_start_failed)
                busy?.isVisible = false
            }
        } else if (!sid.isNullOrBlank()) {
            waitJob = lifecycleScope.launch { waitAndPlay(sid) }
        } else if (!pendingUrl.isNullOrBlank()) {
            attachAndPlay()
        } else {
            statusView?.text = getString(R.string.stream_start_failed)
            busy?.isVisible = false
            topProgress?.isVisible = false
        }
        showChrome()
    }

    private suspend fun startLocalTorrentAndPlay(magnetUri: String) {
        AppLog.i(TAG, "startLocalTorrent season=$seasonNum episode=$episodeNum")
        statusView?.text = getString(R.string.finding_peers)
        busy?.isVisible = true
        try {
            // Prefer Exo on low-RAM boxes when starting a torrent — VLC .so is huge.
            val started = withContext(Dispatchers.IO) {
                TorrentClient.start(
                    context = this@PlayerActivity,
                    magnet = magnetUri,
                    season = seasonNum,
                    episode = episodeNum,
                    fileIndex = fileIndex,
                    onStats = { stats ->
                        if (!stopped) main.post { showLocalTorrentStatus(stats) }
                    },
                )
            }
            if (stopped) return
            sessionId = started.sessionId
            application.asTv().activeStreamSession = started.sessionId
            fileIndex = started.fileIndex
            pendingUrl = started.url
            AppLog.i(TAG, "local torrent ready url=${started.url}")
            mediaAttached = false
            streamOpened = false
            // Create player engine only now that libtorrent is up and URL exists.
            main.post {
                if (stopped) return@post
                ensurePlayer(forceExo = true)
                attachAndPlay()
            }
            startLocalStatusPolling()
        } catch (t: Throwable) {
            AppLog.e(TAG, "startLocalTorrent failed", t)
            if (!stopped) {
                statusView?.text = t.message?.takeIf { it.isNotBlank() }
                    ?: getString(R.string.stream_start_failed)
                busy?.isVisible = false
                topProgress?.isVisible = false
            }
        }
    }

    private fun startLocalStatusPolling() {
        statusPollJob?.cancel()
        statusPollJob = lifecycleScope.launch {
            while (isActive && !stopped) {
                val tick = withContext(Dispatchers.IO) { TorrentClient.currentStats() }
                if (tick != null && !stopped) {
                    main.post { showLocalTorrentStatus(tick) }
                    // Open when fully buffered even if first attach failed.
                    if (!mediaAttached && !pendingUrl.isNullOrBlank() &&
                        (tick.ready || tick.torrentComplete || tick.bufferPct >= 1.0)
                    ) {
                        main.post { attachAndPlay() }
                    }
                }
                delay(1_000L)
            }
        }
    }

    private fun showLocalTorrentStatus(stats: LocalStreamStats) {
        val session = StreamSession(
            id = sessionId.orEmpty(),
            title = titleView?.text?.toString().orEmpty(),
            progress = (stats.bufferPct / 100.0).coerceIn(0.0, 1.0),
            bufferProgress = (stats.bufferPct / 100.0).coerceIn(0.0, 1.0),
            downloadMbps = stats.downloadMbps,
            seeders = stats.seeders,
            peers = stats.peers,
            resumePosition = resumeMs.toInt(),
            status = if (stats.ready || stats.torrentComplete) "ready" else "buffering",
            streamUrl = pendingUrl.orEmpty(),
        )
        showTorrentStatus(session)
    }

    private suspend fun waitAndPlay(sessionId: String) {
        val api = application.asTv().api
        try {
            val session = withContext(Dispatchers.IO) {
                api.waitUntilStreamReady(sessionId, timeoutMs = 180_000L) { tick ->
                    main.post { showTorrentStatus(tick) }
                }
            }
            if (stopped) return
            Log.i(
                TAG,
                "wait done status=${session.status} ready=${session.isReady} " +
                    "buf=${session.bufferProgress} url=${session.streamUrl.take(100)}",
            )
            if (session.isError) {
                statusView?.text = session.status.ifBlank { getString(R.string.playback_error) }
                busy?.isVisible = false
                return
            }
            val url = session.streamUrl.ifBlank {
                withContext(Dispatchers.IO) { api.streamStatus(sessionId) }.streamUrl
            }.ifBlank {
                statusView?.text = getString(R.string.stream_start_failed)
                busy?.isVisible = false
                return
            }
            if (session.resumePosition > 0 && resumeMs <= 0) {
                resumeMs = session.resumePosition.toLong()
            }
            pendingUrl = api.playableStreamUrl(url)
            mediaAttached = false
            streamOpened = false
            Log.i(TAG, "stream playable url=${pendingUrl?.take(140)}")
            main.post { attachAndPlay() }
            startStatusPolling(sessionId)
        } catch (e: Exception) {
            Log.e(TAG, "waitAndPlay failed", e)
            if (!stopped) {
                statusView?.text = e.message ?: getString(R.string.playback_error)
                busy?.isVisible = false
            }
        }
    }

    private fun startStatusPolling(sessionId: String) {
        statusPollJob?.cancel()
        statusPollJob = lifecycleScope.launch {
            val api = application.asTv().api
            while (isActive && !stopped) {
                try {
                    val tick = withContext(Dispatchers.IO) { api.streamStatus(sessionId) }
                    if (stopped) return@launch
                    main.post { showTorrentStatus(tick) }
                    // If URL appeared later / changed host, adopt it once before open
                    if (!mediaAttached && tick.streamUrl.isNotBlank()) {
                        val next = api.playableStreamUrl(tick.streamUrl)
                        if (next != pendingUrl) {
                            pendingUrl = next
                            main.post { attachAndPlay() }
                        }
                    }
                } catch (e: Exception) {
                    Log.w(TAG, "status poll failed", e)
                }
                delay(1_000L)
            }
        }
    }

    private fun showTorrentStatus(session: StreamSession) {
        lastSession = session
        // Prefer buffer %, but ignore bogus "complete" (1.0 with no real bytes).
        val rawFrac = when {
            session.bufferProgress in 0.001..0.999 -> session.bufferProgress
            session.bufferProgress >= 0.999 && session.progress >= 0.999 -> 1.0
            session.progress in 0.001..0.999 -> session.progress
            else -> 0.0
        }
        val rawPct = rawFrac * 100
        // Don't claim 100% while the swarm is still transferring (desktop parity).
        val bufPct = when {
            rawPct >= 99.5 && session.downloadMbps >= 0.05 -> 99
            rawPct >= 99.5 && session.progress < 0.999 -> 0 // not actually done
            else -> rawPct.toInt().coerceIn(0, 100)
        }
        val speed = when {
            session.downloadMbps >= 1 -> String.format("%.1f MB/s", session.downloadMbps)
            session.downloadMbps > 0 -> String.format("%.0f KB/s", session.downloadMbps * 1024)
            else -> null
        }
        topProgress?.isVisible = true
        topProgress?.progress = bufPct
        // Secondary = overall piece progress when available
        val piecePct = (session.progress * 100).toInt().coerceIn(0, 99).let { p ->
            if (session.progress >= 0.995 && session.downloadMbps < 0.05) 100 else p
        }
        topProgress?.secondaryProgress = piecePct.coerceAtLeast(bufPct)

        // Mirror buffer onto the seek secondary so scrubbing shows downloaded span
        if (streamOpened) {
            seek?.secondaryProgress = (bufPct / 100.0 * SEEK_MAX).toInt().coerceIn(0, SEEK_MAX)
        }

        val line = buildString {
            when {
                session.isError -> append(session.status)
                !session.isReady -> {
                    append(getString(R.string.finding_peers))
                    append("  ·  $bufPct%")
                }
                !streamOpened -> append(getString(R.string.buffering_pct, bufPct, session.downloadMbps))
                session.downloadMbps > 0.05 || bufPct < 99 -> {
                    append(getString(R.string.buffering_pct, bufPct, session.downloadMbps))
                }
                else -> append("Playing")
            }
            speed?.takeIf { session.isReady && streamOpened && session.downloadMbps > 0.05 }
                ?.let { /* already in buffering_pct */ }
            if (!session.isReady) {
                speed?.let { append("  ·  $it") }
                if (session.seeders > 0) append("  ·  ${session.seeders} seeds")
                else if (session.peers > 0) append("  ·  ${session.peers} peers")
            }
        }
        // Don't clobber "Seeking…" / skip UI while scrubbing
        if (!userSeeking && seekTargetMs < 0) {
            statusView?.text = line
        }
        busy?.isVisible = (!session.isReady || !streamOpened) && !userSeeking
    }

    override fun onSurfaceTextureAvailable(surface: SurfaceTexture, width: Int, height: Int) {
        surfaceReady = true
        // Defer VLC/Exo until we have a URL — see ensurePlayer in attachAndPlay.
        if (!pendingUrl.isNullOrBlank()) {
            ensurePlayer()
            player?.attachTexture(findViewById(R.id.surface))
            player?.setAspectMode(application.asTv().session.aspectRatio)
            attachAndPlay()
        }
    }

    override fun onSurfaceTextureSizeChanged(surface: SurfaceTexture, width: Int, height: Int) = Unit

    override fun onSurfaceTextureDestroyed(surface: SurfaceTexture): Boolean {
        surfaceReady = false
        player?.attachTexture(null)
        return true
    }

    override fun onSurfaceTextureUpdated(surface: SurfaceTexture) = Unit

    private fun ensurePlayer(forceExo: Boolean = false) {
        if (player != null) return
        val engine = if (forceExo) {
            SessionStore.PLAYER_EXO
        } else {
            application.asTv().session.playbackEngine
        }
        AppLog.i(TAG, "ensurePlayer engine=$engine")
        player = if (engine == SessionStore.PLAYER_VLC) {
            VlcPlayback(this, playbackListener())
        } else {
            TvPlayback(this, playbackListener())
        }
        player?.bindSubtitles(findViewById(R.id.subtitles))
        val frame = findViewById<androidx.media3.ui.AspectRatioFrameLayout>(R.id.video_frame)
        (player as? TvPlayback)?.attachFrame(frame)
        (player as? VlcPlayback)?.attachFrame(frame)
        player?.setAspectMode(application.asTv().session.aspectRatio)
    }

    private fun playbackListener() = object : PlaybackEngine.Listener {
            override fun onOpening() {
                main.post {
                    statusView?.text = "Opening…"
                    Log.i(TAG, "ExoPlayer opening")
                }
            }

            override fun onBuffering(percent: Int) {
                main.post {
                    if (!userSeeking && percent < 100) {
                        statusView?.text = "Buffering $percent%"
                        topProgress?.isVisible = true
                        topProgress?.progress = percent
                    }
                    busy?.isVisible = percent < 100 && (!streamOpened || userSeeking)
                    if (isStream && streamOpened && !userSeeking && percent < 100) {
                        armBufferStallWatch()
                        nudgeTorrentAtPlayhead()
                    }
                }
            }

            override fun onPlaying() {
                val mp = player ?: return
                main.post {
                    Log.i(TAG, "ExoPlayer playing pos=${mp.time} len=${mp.length}")
                    streamOpened = true
                    falseEofCount = 0
                    stallRecoverCount = 0
                    cancelBufferStallWatch()
                    busy?.isVisible = false
                    topProgress?.isVisible = false
                    posterHud?.isVisible = false
                    btnAspect?.isVisible = true
                    btnSubs?.isVisible = true
                    chromeBottom?.isVisible = true
                    btnPlay?.setImageResource(R.drawable.ic_pause)
                    if (btnPlay?.hasFocus() != true && !userSeeking) {
                        btnPlay?.requestFocus()
                    }
                    scheduleHideChrome()
                    main.removeCallbacks(tickProgress)
                    main.post(tickProgress)
                    maybeLoadSegments()
                }
            }

            override fun onPaused() {
                main.post {
                    if (!userSeeking) statusView?.text = "Paused"
                    btnPlay?.setImageResource(R.drawable.ic_play_arrow)
                    showChrome()
                }
            }

            override fun onError() {
                main.post {
                    Log.e(TAG, "ExoPlayer error url=$pendingUrl hw=$hwDecode")
                    if (hwDecode) {
                        hwDecode = false
                        mediaAttached = false
                        statusView?.text = "Retrying with FFmpeg…"
                        attachAndPlay()
                    } else {
                        statusView?.text = getString(R.string.playback_error)
                        busy?.isVisible = false
                        mediaAttached = false
                        showChrome()
                    }
                }
            }

            override fun onEnded() {
                main.post { handleEndReached() }
            }

            override fun onTime(positionMs: Long) {
                if (positionMs > lastGoodPosMs) lastGoodPosMs = positionMs
            }

            override fun onDuration(durationMs: Long) {
                if (durationMs > 0) main.post { timeDur?.text = formatMs(durationMs) }
            }
    }

    private fun handleEndReached() {
        val mp = player ?: return
        val len = mp.length
        val pos = lastGoodPosMs.coerceAtLeast(mp.time)
        val nearEnd = len > 120_000 && pos >= (len * 0.90).toLong()
        if (isStream && !nearEnd && falseEofCount < 8) {
            falseEofCount++
            val recover = lastGoodPosMs.coerceAtLeast(0)
            Log.w(TAG, "false EOF #$falseEofCount — resume at $recover (len=$len)")
            statusView?.text = "Reconnecting…"
            busy?.isVisible = true
            if (localTorrent) {
                TorrentClient.seekTo(recover, len.coerceAtLeast(0))
            }
            main.postDelayed({
                if (stopped) return@postDelayed
                runCatching {
                    if (recover > 1_000) mp.time = recover
                    mp.play()
                }
            }, 600L)
            return
        }
        statusView?.text = "Ended"
        showPlayNext(nextEpisode != null)
        saveWatchProgress(force = true, complete = true)
    }

    private fun armBufferStallWatch() {
        if (!isStream || userSeeking || stopped) return
        if (bufferingSinceMs != 0L) return // already armed; don't reset on % ticks
        bufferingSinceMs = System.currentTimeMillis()
        main.removeCallbacks(bufferStallRecover)
        // After ~5s of underrun, force a tiny seek-back so Exo/VLC opens a fresh
        // HTTP Range against newly arrived pieces (manual seek already unsticks this).
        main.postDelayed(bufferStallRecover, 5_000L)
    }

    private fun cancelBufferStallWatch() {
        bufferingSinceMs = 0L
        main.removeCallbacks(bufferStallRecover)
    }

    private fun nudgeTorrentAtPlayhead() {
        if (!localTorrent) return
        val now = System.currentTimeMillis()
        if (now - lastTorrentNudgeMs < 2_000L) return
        lastTorrentNudgeMs = now
        val mp = player ?: return
        val pos = mp.time.coerceAtLeast(lastGoodPosMs)
        val dur = mp.length.coerceAtLeast(0L)
        TorrentClient.seekTo(pos, dur)
    }

    private fun recoverFromBufferStall() {
        if (stopped || !isStream || userSeeking) return
        val mp = player ?: return
        if (mp.isPlaying) {
            cancelBufferStallWatch()
            return
        }
        if (stallRecoverCount >= 10) {
            Log.w(TAG, "buffer stall recover gave up after $stallRecoverCount tries")
            return
        }
        stallRecoverCount++
        val pos = lastGoodPosMs.coerceAtLeast(mp.time).coerceAtLeast(0L)
        // Seek back ~2.5s so the demuxer re-requests bytes that should already be on disk.
        val recover = (pos - 2_500L).coerceAtLeast(0L)
        Log.w(TAG, "buffer stall #$stallRecoverCount — nudge to $recover (was $pos)")
        statusView?.text = "Catching up…"
        busy?.isVisible = true
        if (localTorrent) {
            TorrentClient.seekTo(recover, mp.length.coerceAtLeast(0L))
        }
        runCatching {
            mp.time = recover
            mp.play()
        }
        // Allow re-arm after this attempt finishes or fails again.
        bufferingSinceMs = 0L
        main.removeCallbacks(bufferStallRecover)
        main.postDelayed({
            if (stopped || userSeeking) return@postDelayed
            if (player?.isPlaying != true) armBufferStallWatch()
        }, 6_000L)
    }

    private fun attachAndPlay() {
        val url = pendingUrl?.takeIf { it.isNotBlank() } ?: return
        if (mediaAttached) {
            if (surfaceReady) {
                player?.attachTexture(findViewById(R.id.surface))
            }
            return
        }
        if (!surfaceReady) {
            Log.i(TAG, "attachAndPlay waiting for surface")
            return
        }
        ensurePlayer()
        val mp = player ?: return
        try {
            Log.i(TAG, "attachAndPlay hw=$hwDecode $url")
            mp.attachTexture(findViewById(R.id.surface))
            val start = resumeMs
            resumeMs = 0
            mediaAttached = true
            mp.open(url, start, preferSoftware = !hwDecode)
            statusView?.text = getString(R.string.starting_stream)
        } catch (e: Exception) {
            Log.e(TAG, "attachAndPlay failed", e)
            statusView?.text = e.message ?: getString(R.string.playback_error)
            busy?.isVisible = false
            mediaAttached = false
        }
    }

    private fun queueSeek(targetMs: Long, settleMs: Long) {
        seekTargetMs = targetMs.coerceAtLeast(0)
        userSeeking = true
        seekToken++
        val token = seekToken
        statusView?.text = "Seeking ${formatMs(seekTargetMs)}…"
        busy?.isVisible = true
        // Don't pause progressive streams while settling — pause+seek often snaps to t=0.
        if (!isStream) {
            runCatching { player?.pause() }
        }
        main.removeCallbacks(commitSeek)
        main.postDelayed({
            if (token != seekToken) return@postDelayed
            commitPendingSeek()
        }, settleMs)
    }

    private fun commitPendingSeek() {
        val mp = player ?: return
        val target = seekTargetMs
        if (target < 0) {
            userSeeking = false
            return
        }
        val token = seekToken
        Log.i(TAG, "commitSeek $target len=${mp.length}")
        try {
            if (localTorrent) {
                TorrentClient.seekTo(target, mp.length.coerceAtLeast(0))
            }
            mp.seekTo(target)
            lastGoodPosMs = target
            mp.play()
            btnPlay?.setImageResource(R.drawable.ic_pause)
        } catch (e: Exception) {
            Log.e(TAG, "seek failed", e)
        }
        // Keep "seeking" flag briefly so ticks don't yank the thumb back
        main.postDelayed({
            if (token == seekToken) {
                userSeeking = false
                seekTargetMs = -1
                busy?.isVisible = false
            }
        }, 1_200L)
        showChrome()
    }

    private fun maybeLoadSegments() {
        val tid = titleId ?: return
        val dur = player?.length?.toInt()?.coerceAtLeast(0) ?: 0
        val haveDuration = dur > 30_000
        if (segmentsLoaded) {
            val durationChanged = haveDuration &&
                (segmentDurationMs <= 0 || kotlin.math.abs(dur - segmentDurationMs) >= 5_000)
            if (!durationChanged) return
        }
        segmentsLoaded = true
        segmentDurationMs = if (haveDuration) dur else 0
        val isSeries = kind.equals("SERIES", true) || kind.equals("ANIME", true) || kind.equals("TV", true)
        lifecycleScope.launch {
            try {
                val segs = withContext(Dispatchers.IO) {
                    application.asTv().api.mediaSegments(
                        titleId = tid,
                        season = seasonNum ?: if (isSeries) 1 else null,
                        episode = episodeNum ?: if (isSeries) 1 else null,
                        durationMs = if (haveDuration) dur else null,
                    )
                }
                segments = segs
                if (segs.isEmpty() && !haveDuration) segmentsLoaded = false
            } catch (e: Exception) {
                Log.w(TAG, "mediaSegments failed", e)
                if (!haveDuration) segmentsLoaded = false
            }
        }
    }

    private fun loadNextEpisode() {
        if (nextLoaded || nextEpisode != null) return
        val tid = titleId ?: return
        val season = seasonNum ?: return
        val episode = episodeNum ?: return
        if (season < 1 || episode < 1) return
        nextLoaded = true
        lifecycleScope.launch {
            try {
                val item = withContext(Dispatchers.IO) { application.asTv().api.title(tid) }
                nextEpisode = findNextEpisode(item, season, episode)
            } catch (e: Exception) {
                nextLoaded = false
                Log.w(TAG, "next episode lookup failed", e)
            }
        }
    }

    private fun findNextEpisode(item: TitleItem, season: Int, episode: Int): NextEpisode? {
        val seasons = item.seasons.filter { it.seasonNumber > 0 }.sortedBy { it.seasonNumber }
        val current = seasons.firstOrNull { it.seasonNumber == season }
        val later = current?.episodes
            ?.filter { it.episodeNumber > episode }
            ?.minByOrNull { it.episodeNumber }
        if (later != null) {
            return NextEpisode(season, later.episodeNumber, later.id, item.title, item.kind, item.posterUrl, item.backdropUrl)
        }
        for (s in seasons) {
            if (s.seasonNumber <= season) continue
            val first = s.episodes.filter { it.episodeNumber > 0 }.minByOrNull { it.episodeNumber } ?: continue
            return NextEpisode(s.seasonNumber, first.episodeNumber, first.id, item.title, item.kind, item.posterUrl, item.backdropUrl)
        }
        return null
    }

    private fun updateSkipNext() {
        if (!streamOpened) return
        maybeLoadSegments()
        loadNextEpisode()
        val mp = player ?: return
        val pos = mp.time.toInt()
        val dur = mp.length.toInt()
        val opening = segments.firstOrNull {
            (it.kind.equals("INTRO", true) || it.kind.equals("RECAP", true)) && it.contains(pos, dur)
        }
        activeSegment = opening
        val showSkip = opening != null
        val wasSkip = btnSkip?.isVisible == true
        btnSkip?.isVisible = showSkip
        if (showSkip) {
            btnSkip?.text = opening?.label?.ifBlank { null } ?: getString(R.string.skip_intro)
            raiseSkipButtons()
            if (!wasSkip) btnSkip?.requestFocus()
        }
        val nearEnd = dur > 60_000 && (pos >= dur - 45_000 || pos.toDouble() / dur >= 0.97)
        val inCredits = segments.any { it.kind.equals("CREDITS", true) && it.contains(pos, dur) }
        showPlayNext(!showSkip && (nearEnd || inCredits) && nextEpisode != null)
    }

    private fun showPlayNext(show: Boolean) {
        if (!show) {
            playNextVisible = false
            btnNext?.isVisible = false
            return
        }
        val was = playNextVisible
        playNextVisible = true
        btnNext?.isVisible = true
        raiseSkipButtons()
        if (!was) {
            showChrome()
            btnNext?.requestFocus()
        }
    }

    private fun raiseSkipButtons() {
        overlayActions?.bringToFront()
    }

    private fun placeSkipButtons(chromeUp: Boolean) {
        val overlay = overlayActions ?: return
        val lp = overlay.layoutParams as? FrameLayout.LayoutParams ?: return
        val d = resources.displayMetrics.density
        lp.gravity = android.view.Gravity.BOTTOM or android.view.Gravity.START
        lp.bottomMargin = ((if (chromeUp) 200 else 48) * d).toInt()
        lp.marginStart = (48 * d).toInt()
        overlay.layoutParams = lp
        overlay.bringToFront()
    }

    private fun playNextEpisode() {
        val next = nextEpisode ?: return
        val tid = titleId ?: return
        if (nextBusy) return
        nextBusy = true
        btnNext?.isEnabled = false
        statusView?.text = getString(R.string.looking_up_sources)
        showChrome()
        lifecycleScope.launch {
            try {
                saveWatchProgress(force = true)
                val api = application.asTv().api
                val label = String.format("%s S%02dE%02d", next.catalogTitle, next.season, next.episode)
                val raw = api.lookupSources(label, next.kind, tid, next.season, next.episode)
                val source = StreamQuality.rankSources(raw, application.asTv().session.preferredQuality).firstOrNull()
                if (source == null) {
                    Toast.makeText(this@PlayerActivity, R.string.no_sources, Toast.LENGTH_LONG).show()
                    return@launch
                }
                val startedSession = "local-${System.currentTimeMillis()}"
                startActivity(
                    Intent(this@PlayerActivity, PlayerActivity::class.java)
                        .putExtra(EXTRA_TITLE, label)
                        .putExtra(EXTRA_SESSION, startedSession)
                        .putExtra(EXTRA_URL, "")
                        .putExtra(EXTRA_MAGNET, source.magnet)
                        .putExtra(EXTRA_LOCAL, true)
                        .putExtra(EXTRA_POSTER, next.posterUrl)
                        .putExtra(EXTRA_BACKDROP, next.backdropUrl)
                        .putExtra(EXTRA_TITLE_ID, tid)
                        .putExtra(EXTRA_EPISODE_ID, next.episodeId)
                        .putExtra(EXTRA_KIND, next.kind)
                        .putExtra(EXTRA_SEASON, next.season)
                        .putExtra(EXTRA_EPISODE, next.episode)
                        .putExtra(EXTRA_RESUME_MS, 0L),
                )
                finish()
            } catch (e: Exception) {
                Log.e(TAG, "play next failed", e)
                Toast.makeText(this@PlayerActivity, e.message, Toast.LENGTH_LONG).show()
            } finally {
                nextBusy = false
                btnNext?.isEnabled = true
            }
        }
    }

    private fun skipActiveSegment() {
        val seg = activeSegment ?: return
        val mp = player ?: return
        val dur = mp.length.toInt()
        queueSeek(seg.skipTargetMs(dur).toLong(), settleMs = 100L)
        activeSegment = null
        btnSkip?.isVisible = false
        showChrome()
    }

    private fun togglePlay() {
        val mp = player ?: return
        if (mp.isPlaying) mp.pause() else mp.play()
        showChrome()
    }

    private fun seekBy(deltaMs: Long) {
        val mp = player ?: return
        val len = mp.length.coerceAtLeast(0)
        val base = when {
            seekTargetMs >= 0 -> seekTargetMs
            lastGoodPosMs > 0 -> lastGoodPosMs
            else -> mp.time.coerceAtLeast(0)
        }
        var target = base + deltaMs
        if (target < 0) target = 0
        if (len > 0 && target > len) target = len
        // Optimistic UI
        if (len > 0) {
            seek?.progress = ((target.toDouble() / len) * SEEK_MAX).toInt().coerceIn(0, SEEK_MAX)
        }
        timePos?.text = formatMs(target)
        queueSeek(target, settleMs = if (isStream) 700L else 50L)
        showChrome()
    }

    private fun updateProgressUi() {
        val mp = player ?: return
        if (userSeeking) return
        val len = mp.length
        val pos = mp.time
        if (pos > lastGoodPosMs) lastGoodPosMs = pos
        if (len > 0) {
            seek?.progress = ((pos.toDouble() / len) * SEEK_MAX).toInt().coerceIn(0, SEEK_MAX)
            timeDur?.text = formatMs(len)
        } else {
            timeDur?.text = "--:--"
        }
        timePos?.text = formatMs(pos)
        saveWatchProgress()
    }

    /** Write resume position so the home Continue watching row can list this title. */
    private fun saveWatchProgress(force: Boolean = false, complete: Boolean = false) {
        val id = titleId?.takeIf { it.isNotBlank() } ?: return
        val mp = player
        val pos = when {
            mp != null && mp.time > 0L -> mp.time
            else -> lastGoodPosMs
        }
        if (!complete && pos < 2_000L) return
        if (!force && lastSavedPosMs >= 0L && kotlin.math.abs(pos - lastSavedPosMs) < 12_000L) return
        val dur = mp?.length?.takeIf { it > 0L }
        lastSavedPosMs = pos
        val ep = episodeId
        val api = application.asTv().api
        val write = suspend {
            api.updateProgress(
                titleId = id,
                episodeId = ep,
                positionMs = pos,
                durationMs = dur,
                complete = complete,
            )
        }
        if (force) {
            Thread {
                runCatching { kotlinx.coroutines.runBlocking { write() } }
            }.start()
        } else {
            lifecycleScope.launch(Dispatchers.IO) {
                runCatching { write() }
            }
        }
    }

    private fun formatMs(ms: Long): String {
        val total = (ms / 1000).toInt().coerceAtLeast(0)
        val h = total / 3600
        val m = (total % 3600) / 60
        val s = total % 60
        return if (h > 0) String.format("%d:%02d:%02d", h, m, s)
        else String.format("%d:%02d", m, s)
    }

    private fun showChrome() {
        chromeVisible = true
        chromeTop?.animate()?.alpha(1f)?.setDuration(200)?.start()
        if (streamOpened) chromeBottom?.isVisible = true
        chromeBottom?.animate()?.alpha(1f)?.setDuration(200)?.start()
        placeSkipButtons(true)
        scheduleHideChrome()
    }

    private fun setChrome(visible: Boolean) {
        chromeVisible = visible
        if (!visible && streamOpened && !userSeeking) {
            chromeTop?.animate()?.alpha(0f)?.setDuration(280)?.start()
            chromeBottom?.animate()?.alpha(0f)?.setDuration(280)?.start()
            placeSkipButtons(false)
        }
    }

    private fun scheduleHideChrome() {
        main.removeCallbacks(hideChrome)
        if (streamOpened && !userSeeking) main.postDelayed(hideChrome, 8_000L)
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (!streamOpened && event.keyCode != KeyEvent.KEYCODE_BACK) return true
        return super.dispatchKeyEvent(event)
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean {
        if (!streamOpened) {
            if (keyCode == KeyEvent.KEYCODE_BACK) {
                confirmLeave()
                return true
            }
            return true
        }
        val focus = currentFocus
        val onControl = focus === btnPlay || focus === btnRew || focus === btnFf ||
            focus === btnAspect || focus === btnSubs ||
            focus === seek || focus === btnSkip || focus === btnNext

        if (onControl && keyCode in listOf(
                KeyEvent.KEYCODE_DPAD_LEFT, KeyEvent.KEYCODE_DPAD_RIGHT,
                KeyEvent.KEYCODE_DPAD_UP, KeyEvent.KEYCODE_DPAD_DOWN,
                KeyEvent.KEYCODE_DPAD_CENTER, KeyEvent.KEYCODE_ENTER,
            )
        ) {
            showChrome()
            return super.onKeyDown(keyCode, event)
        }

        showChrome()
        when (keyCode) {
            KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE -> {
                togglePlay()
                return true
            }
            KeyEvent.KEYCODE_MEDIA_FAST_FORWARD -> {
                seekBy(10_000)
                return true
            }
            KeyEvent.KEYCODE_MEDIA_REWIND -> {
                seekBy(-10_000)
                return true
            }
            KeyEvent.KEYCODE_DPAD_CENTER, KeyEvent.KEYCODE_ENTER -> {
                if (!chromeVisible || chromeBottom?.alpha == 0f) {
                    showChrome()
                    btnPlay?.requestFocus()
                    return true
                }
                togglePlay()
                return true
            }
            KeyEvent.KEYCODE_DPAD_RIGHT -> {
                seekBy(10_000)
                return true
            }
            KeyEvent.KEYCODE_DPAD_LEFT -> {
                seekBy(-10_000)
                return true
            }
            KeyEvent.KEYCODE_BACK -> {
                confirmLeave()
                return true
            }
        }
        return super.onKeyDown(keyCode, event)
    }

    private fun confirmLeave() {
        if (leaveDialog?.isShowing == true) {
            leaveDialog?.dismiss()
            return
        }
        leaveDialog = showRoundDialog(
            activity = this,
            title = R.string.leave_player_title,
            message = R.string.leave_player_message,
            negative = R.string.keep_watching,
            positive = R.string.leave_player,
            onPositive = { finish() },
        )
    }

    private fun openAspect() {
        showChrome()
        val options = listOf(
            SessionStore.ASPECT_FIT to R.string.aspect_fit,
            SessionStore.ASPECT_ORIGINAL to R.string.aspect_original,
            SessionStore.ASPECT_FILL to R.string.aspect_fill,
            SessionStore.ASPECT_STRETCH to R.string.aspect_stretch,
            SessionStore.ASPECT_16_9 to R.string.aspect_16_9,
            SessionStore.ASPECT_4_3 to R.string.aspect_4_3,
        )
        val current = application.asTv().session.aspectRatio
        val labels = options.map { getString(it.second) }.toTypedArray()
        AlertDialog.Builder(this)
            .setTitle(R.string.aspect_title)
            .setSingleChoiceItems(labels, options.indexOfFirst { it.first == current }.coerceAtLeast(0)) { dialog, which ->
                val mode = options[which].first
                application.asTv().session.aspectRatio = mode
                player?.setAspectMode(mode)
                dialog.dismiss()
            }
            .setNegativeButton(android.R.string.cancel, null)
            .show()
    }

    private fun openSubtitles() {
        showChrome()
        val app = application.asTv()
        SubtitlePicker(
            activity = this,
            player = { player },
            api = app.api,
            titleId = { titleId },
            season = { seasonNum },
            episode = { episodeNum },
            languages = { app.session.preferredLanguages },
        ).show()
    }

    override fun onPause() {
        saveWatchProgress(force = true)
        super.onPause()
    }

    override fun onDestroy() {
        leaveDialog?.dismiss()
        leaveDialog = null
        stopped = true
        waitJob?.cancel()
        statusPollJob?.cancel()
        main.removeCallbacks(hideChrome)
        main.removeCallbacks(tickProgress)
        main.removeCallbacks(commitSeek)
        main.removeCallbacks(bufferStallRecover)
        val sid = sessionId
        if (localTorrent || sid?.startsWith("local-") == true) {
            // Leave the torrent service running and keep pieces on disk.
            // Wipe only happens on app exit when clear-cache-on-exit is enabled.
        } else if (!sid.isNullOrBlank()) {
            val api = application.asTv().api
            Thread {
                runCatching { kotlinx.coroutines.runBlocking { api.stopStream(sid) } }
            }.start()
        }
        application.asTv().activeStreamSession = null
        runCatching {
            player?.stop()
            player?.release()
        }
        player = null
        super.onDestroy()
    }

    private data class NextEpisode(
        val season: Int,
        val episode: Int,
        val episodeId: String,
        val catalogTitle: String,
        val kind: String,
        val posterUrl: String?,
        val backdropUrl: String?,
    )

    companion object {
        private const val TAG = "PlayerActivity"
        private const val SEEK_MAX = 1000
        const val EXTRA_URL = "url"
        const val EXTRA_TITLE = "title"
        const val EXTRA_SESSION = "session"
        const val EXTRA_POSTER = "poster"
        const val EXTRA_BACKDROP = "backdrop"
        const val EXTRA_TITLE_ID = "title_id"
        const val EXTRA_EPISODE_ID = "episode_id"
        const val EXTRA_KIND = "kind"
        const val EXTRA_SEASON = "season"
        const val EXTRA_EPISODE = "episode"
        const val EXTRA_RESUME_MS = "resume_ms"
        const val EXTRA_LOCAL = "local_torrent"
        const val EXTRA_MAGNET = "magnet"
        const val EXTRA_FILE_INDEX = "file_index"
    }
}
