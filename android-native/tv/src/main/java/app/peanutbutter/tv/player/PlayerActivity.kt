package app.peanutbutter.tv.player

import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.KeyEvent
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.widget.Toast
import androidx.activity.OnBackPressedCallback
import androidx.compose.ui.platform.ComposeView
import androidx.fragment.app.FragmentActivity
import androidx.lifecycle.lifecycleScope
import app.peanutbutter.core.AppLog
import app.peanutbutter.core.LocalStreamStats
import app.peanutbutter.core.MediaSegment
import app.peanutbutter.core.SessionStore
import app.peanutbutter.core.StreamDownloads
import app.peanutbutter.core.TitleItem
import app.peanutbutter.core.StreamSession
import app.peanutbutter.core.TorrentClient
import app.peanutbutter.core.TorrentFilePicker
import app.peanutbutter.tv.R
import app.peanutbutter.tv.asTv
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * ExoPlayer / Media3 torrent player (Jellyfin Android TV approach):
 * MediaCodec hardware decode, FFmpeg when that fails, SurfaceView video.
 * Debounced seek retargets the swarm; false-EOF recovery stays.
 */
class PlayerActivity : FragmentActivity(), SurfaceHolder.Callback {
    private val main = Handler(Looper.getMainLooper())
    private var player: PlaybackEngine? = null
    private var surfaceReady = false
    private var pendingUrl: String? = null
    private var mediaAttached = false
    private var streamOpened = false
    /** Wall-clock when media was last attached — recover stuck pre-play. */
    private var mediaAttachAtMs = 0L
    private var prePlayRecoveries = 0
    private var sessionId: String? = null
    private var titleId: String? = null
    private var episodeId: String? = null
    private var lastSavedPosMs = -1L
    private var markedComplete = false
    private var kind: String? = null
    private var seasonNum: Int? = null
    private var episodeNum: Int? = null
    private var resumeMs: Long = 0
    /** Position the current media was opened at; a reopen before playback starts reuses it. */
    private var openStartMs: Long = 0
    /** Opened part-way in: "Continue from … / Start over" asked once, before playing. */
    private var resumeAsked = false
    private var askingResume = false
    /** This video's subtitle delay (Size and Background are kept in [SubtitleLook]). */
    private var subDelayMs = 0L
    private var waitJob: Job? = null
    private var statusPollJob: Job? = null
    private var stopped = false
    /** Set when "Play next" launched a new player that now owns the torrent. */
    private var handedOffToNext = false
    private var chromeVisible = true
    private var isStream = false
    private var localTorrent = false
    private var magnet: String? = null
    /** Direct link from a Stremio add-on (no torrent, no server session). */
    private var directUrl: String? = null
    private var directHeaders: Map<String, String> = emptyMap()
    private var fileIndex: Int? = null
    /** The episode number the release uses, when the catalog numbers it differently. */
    private var fileEpisode: Int? = null

    /** Everything drawn over the video ([PlayerOverlay]). */
    private val ui = PlayerUi()
    /** The label the player was opened with ("Show S01E02"); saved with the resume point. */
    private var fullTitle = ""
    /** Status line: the pre-play banner, and the stats chip once playing. */
    private var statusText: String
        get() = ui.status
        set(value) {
            ui.status = value
            ui.stats = if (isStream) value else null
        }

    private var segments: List<MediaSegment> = emptyList()
    private var activeSegment: MediaSegment? = null
    /** Just skipped: until the seek lands the position is still inside it, which
     *  brought Skip back for a few seconds. Cleared once playback leaves it. */
    private var skippedSegment: MediaSegment? = null
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
    private var softErrorCount = 0
    private var lastSoftErrorMs = 0L
    private var bufferingSinceMs = 0L
    /** Position when the retry counters last reset; they only reset on real progress. */
    private var recoveryAnchorMs = 0L
    private var nextRetryAtMs = 0L
    private var segmentsRetryAtMs = 0L
    private var endCountdownLeft = 0
    private var lastTorrentNudgeMs = 0L
    private var lastKnownDurationMs: Long = 0
    private var lastSession: StreamSession? = null
    private var hwDecode = true
    /** Once the torrent has been playable, never fall back to "Finding peers…". */
    private var torrentReadyLatched = false
    private var exoBuffering = false
    /** True while user/OS has playback paused — drives chrome without Aspect/CC. */
    private var userPaused = false
    private var torrentStartedWithResume = false
    private var torrentStartFailed = false
    private var pausedSentToEngine = false
    /** How long the controls stay up after the last action. */
    private var hideDelayMs = CHROME_HIDE_MS
    /** Share of the file downloaded without gaps from the playhead. */
    private var torrentDownloadedTo = 0.0

    private val hideChrome = Runnable { setChrome(false) }
    /** Short rebuffers shouldn't flash a spinner. */
    private val showRebufferSpinner = Runnable { if (streamOpened) ui.spinner = true }
    private val endCountdown = object : Runnable {
        override fun run() {
            if (stopped) return
            endCountdownLeft--
            if (endCountdownLeft <= 0) {
                if (!isFinishing) finish()
                return
            }
            ui.nextTitle = getString(R.string.play_next_countdown, endCountdownLeft)
            main.postDelayed(this, 1_000L)
        }
    }
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
        // Keep watching if the catalog API pairing is revoked mid-stream.
        app.peanutbutter.core.AuthEvents.onPlaybackStarted()
        setContentView(R.layout.activity_player)
        ui.leaveTitle = getString(R.string.leave_player_title)
        ui.leaveMessage = getString(R.string.leave_player_message)
        ui.leaveStay = getString(R.string.keep_watching)
        ui.leaveGo = getString(R.string.leave_player)
        ui.onLeave = { finish() }
        ui.nextTitle = getString(R.string.play_next)
        findViewById<ComposeView>(R.id.player_ui).setContent { PlayerOverlay(ui) }

        // Cover first — avoid black frame while torrent/player wake up.
        ui.preparing = true
        ui.art = intent.getStringExtra(EXTRA_BACKDROP)?.takeIf { it.isNotBlank() }
            ?: intent.getStringExtra(EXTRA_POSTER)
        applyBufferingChrome()

        val surface = findViewById<SurfaceView>(R.id.surface)
        surface.holder.addCallback(this)
        // Do NOT create VLC/Exo yet — BeyondTV is armeabi-v7a / low RAM.
        // Loading VLC + libtorrent together OOMs the player activity.
        surfaceReady = surface.holder.surface?.isValid == true

        val title = intent.getStringExtra(EXTRA_TITLE).orEmpty()
        val rawUrl = intent.getStringExtra(EXTRA_URL)?.takeIf { it.isNotBlank() }
        sessionId = intent.getStringExtra(EXTRA_SESSION)
        titleId = intent.getStringExtra(EXTRA_TITLE_ID)
        episodeId = intent.getStringExtra(EXTRA_EPISODE_ID)?.takeIf { it.isNotBlank() }
        kind = intent.getStringExtra(EXTRA_KIND)
        seasonNum = intent.getIntExtra(EXTRA_SEASON, -1).takeIf { it > 0 }
        episodeNum = intent.getIntExtra(EXTRA_EPISODE, -1).takeIf { it > 0 }
        resumeMs = intent.getLongExtra(EXTRA_RESUME_MS, 0L).coerceAtLeast(0)
        lastKnownDurationMs = intent.getLongExtra(EXTRA_DURATION_MS, 0L).coerceAtLeast(0)
        magnet = intent.getStringExtra(EXTRA_MAGNET)
        if (intent.getBooleanExtra(EXTRA_DIRECT, false)) {
            directUrl = rawUrl
            val names = intent.getStringArrayExtra(EXTRA_HEADER_NAMES).orEmpty()
            val values = intent.getStringArrayExtra(EXTRA_HEADER_VALUES).orEmpty()
            directHeaders = names.zip(values).toMap()
        }
        fileIndex = intent.getIntExtra(EXTRA_FILE_INDEX, -1).takeIf { it >= 0 }
        fileEpisode = intent.getIntExtra(EXTRA_FILE_EPISODE, -1).takeIf { it > 0 }
        localTorrent = intent.getBooleanExtra(EXTRA_LOCAL, false) ||
            sessionId?.startsWith("local-") == true ||
            rawUrl?.contains("127.0.0.1") == true
        isStream = !sessionId.isNullOrBlank() || localTorrent
        // 10-bit / HEVC Blu-rays often green-screen on this TV's MediaCodec —
        // start with FFmpeg software decode for those labels.
        val hint = listOfNotNull(title, magnet).joinToString(" ").lowercase()
        if (hint.contains("10bit") || hint.contains("10-bit") ||
            hint.contains("hevc") || hint.contains("x265") || hint.contains("h265")
        ) {
            hwDecode = false
            AppLog.i(TAG, "prefer software decode (hevc/10bit hint)")
        }
        application.asTv().activeStreamSession = sessionId
        setTitleText(title)
        statusText = getString(R.string.finding_peers)
        // Pre-play HUD: center spinner + top buffer bar while finding peers / buffering.
        ui.spinner = true
        ui.bufferPct = null

        pendingUrl = if (localTorrent || directUrl != null) {
            // Direct links go to their own host: never append this device's key.
            rawUrl
        } else {
            rawUrl?.let { application.asTv().api.playableStreamUrl(it) }
                ?.takeIf { it.isNotBlank() && it != "null" }
        }
        AppLog.i(TAG, "onCreate session=$sessionId local=$localTorrent magnet=${magnet?.take(40)} pending=${app.peanutbutter.core.AppLog.safeUrl(pendingUrl).take(80)}")
        Log.i(TAG, "onCreate session=$sessionId local=$localTorrent resume=$resumeMs pending=${app.peanutbutter.core.AppLog.safeUrl(pendingUrl).take(100)}")
        // Only attach when we already have a URL (library files / resumed local).
        if (surfaceReady && !pendingUrl.isNullOrBlank()) attachAndPlay()

        // API 34+ routes Back through OnBackPressedDispatcher (not only onKeyDown).
        // Without this callback the activity finishes and skips the exit dialog.
        onBackPressedDispatcher.addCallback(this, object : OnBackPressedCallback(true) {
            override fun handleOnBackPressed() {
                handleBackPress()
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
                statusText = getString(R.string.stream_start_failed)
                ui.spinner = false
            }
        } else if (!pendingUrl.isNullOrBlank()) {
            attachAndPlay()
        } else {
            statusText = getString(R.string.stream_start_failed)
            ui.spinner = false
        }
        showChrome()
    }

    private suspend fun startLocalTorrentAndPlay(magnetUri: String) {
        AppLog.i(TAG, "startLocalTorrent season=$seasonNum episode=$episodeNum fileEpisode=$fileEpisode")
        statusText = getString(R.string.finding_peers)
        ui.spinner = true
        // Build Exo while the swarm fills so attach isn't delayed after 100%.
        ensurePlayer(forceExo = true)
        try {
            val started = withContext(Dispatchers.IO) {
                TorrentClient.start(
                    context = this@PlayerActivity,
                    magnet = magnetUri,
                    season = seasonNum,
                    // Picks the file: the release's number when it differs.
                    episode = fileEpisode ?: episodeNum,
                    fileIndex = fileIndex,
                    resumeMs = resumeMs,
                    durationMs = lastKnownDurationMs,
                    onStats = { stats ->
                        if (!stopped && !torrentStartFailed) main.post { showLocalTorrentStatus(stats) }
                    },
                )
            }
            torrentStartedWithResume = resumeMs > 2_000L
            if (stopped) return
            sessionId = started.sessionId
            application.asTv().activeStreamSession = started.sessionId
            fileIndex = started.fileIndex
            pendingUrl = started.url
            torrentReadyLatched = true
            AppLog.i(TAG, "local torrent ready url=${started.url}")
            mediaAttached = false
            streamOpened = false
            // Already on Main (lifecycleScope) — open Exo immediately, no extra post hop.
            statusText = getString(R.string.starting_stream)
            ensurePlayer(forceExo = true)
            attachAndPlay()
            startLocalStatusPolling()
        } catch (t: Throwable) {
            AppLog.e(TAG, "startLocalTorrent failed", t)
            torrentStartFailed = true // late stats must not repaint over the error
            if (!stopped) {
                statusText = t.message?.takeIf { it.isNotBlank() }
                    ?: getString(R.string.stream_start_failed)
                ui.spinner = false
            }
        }
    }

    private fun startLocalStatusPolling() {
        TorrentClient.onStatsUpdated = { stats ->
            if (!stopped) main.post { handleLocalStatsTick(stats) }
        }
        statusPollJob?.cancel()
        statusPollJob = lifecycleScope.launch {
            while (isActive && !stopped) {
                val tick = withContext(Dispatchers.IO) { TorrentClient.currentStats() }
                if (tick != null && !stopped) {
                    main.post { handleLocalStatsTick(tick) }
                }
                delay(1_000L)
            }
        }
    }

    private fun handleLocalStatsTick(tick: LocalStreamStats) {
        torrentDownloadedTo = tick.downloadedTo
        showLocalTorrentStatus(tick)
        // URL ready / file complete but Exo never reached onPlaying — keep
        // attaching and recover stuck pre-play (common when download hits 100%
        // while the demuxer is still opening).
        if (!streamOpened && !pendingUrl.isNullOrBlank() &&
            (tick.ready || tick.torrentComplete || tick.bufferPct >= 99.0)
        ) {
            attachAndPlay()
        }
    }

    private fun showLocalTorrentStatus(stats: LocalStreamStats) {
        if (stats.ready || stats.torrentComplete) {
            torrentReadyLatched = true
        }
        val ready = torrentReadyLatched || !pendingUrl.isNullOrBlank() ||
            stats.ready || stats.torrentComplete
        val fileFrac = if (stats.torrentComplete) 1.0 else 0.0
        // Report true torrent readiness (0–1). Display mapping lives in displayBufferPct.
        val torrentFrac = (stats.bufferPct / 100.0).coerceIn(0.0, 1.0)
        val session = StreamSession(
            id = sessionId.orEmpty(),
            title = fullTitle,
            progress = fileFrac,
            bufferProgress = torrentFrac,
            downloadMbps = stats.downloadMbps,
            seeders = stats.seeders,
            peers = stats.peers,
            resumePosition = resumeMs.toInt(),
            status = if (ready) "ready" else "starting",
            streamUrl = pendingUrl.orEmpty().ifBlank { if (ready) "pending" else "" },
        )
        showTorrentStatus(session)
    }

    /**
     * Buffer % for the HUD.
     * Pre-play: show real torrent readiness (don't lie at 100% just because a
     * URL exists — that stuck the UI at "100% buffering" with no frames).
     * After open: Exo's bufferedPercent for underrun.
     */
    private fun displayBufferPct(torrentFrac: Double, exoPercent: Int = -1): Int {
        if (streamOpened) {
            val exo = when {
                exoPercent in 0..100 -> exoPercent
                else -> player?.bufferedPercent?.coerceIn(0, 100) ?: 100
            }
            return if (exo >= 99) 100 else exo.coerceIn(0, 100)
        }
        // Allow 100 once the engine latched ready / URL — don't pin at 99 forever.
        val pct = (torrentFrac.coerceIn(0.0, 1.0) * 100.0).toInt().coerceIn(0, 100)
        return if (torrentReadyLatched || !pendingUrl.isNullOrBlank()) {
            pct.coerceAtLeast(1)
        } else {
            pct.coerceIn(0, 99)
        }
    }

    private fun showTorrentStatus(session: StreamSession) {
        lastSession = session
        if (session.isReady || session.streamUrl.isNotBlank()) {
            torrentReadyLatched = true
        }
        // bufferProgress from torrent is capped ≤0.92; blend Exo while opening.
        val bufPct = displayBufferPct(session.bufferProgress)
        // Pre-play only: never re-open the top buffer bar after playback starts
        // (status polls + brief Exo BUFFERING were flashing it randomly).
        if (!streamOpened) {
            ui.bufferPct = bufPct.coerceIn(0, 100)
            applyBufferingChrome()
        }

        val hasSwarm = session.peers > 0 || session.seeders > 0 || session.downloadMbps > 0.01
        val ready = torrentReadyLatched || session.isReady || !pendingUrl.isNullOrBlank()

        // While playing, only update the status line if chrome is already up —
        // never force the buffering banner back on.
        if (streamOpened && !userSeeking && !chromeVisible && !userPaused) return

        // Match 6ee3433: keep Buffering X% · speed · peers until Exo is actually
        // playing — do not swap to a bare "Starting stream" once the URL exists.
        val line = when {
            session.isError -> session.status
            userPaused -> pausedLine(session.downloadMbps, session.peers)
            streamOpened && exoBuffering && chromeVisible ->
                underrunBufferLine(session.downloadMbps)
            streamOpened && session.downloadMbps < 0.05 && !exoBuffering ->
                "Playing"
            streamOpened && session.downloadMbps >= 0.05 ->
                playingLine(session.downloadMbps, session.peers)
            !streamOpened && (ready || hasSwarm || bufPct > 0) ->
                prePlayBufferLine(
                    pct = bufPct.coerceAtLeast(1).coerceIn(0, 99),
                    downloadMbps = session.downloadMbps,
                    peers = session.peers,
                )
            !streamOpened -> getString(R.string.finding_peers)
            else -> "Playing"
        }
        applyStatusLine(line)
        // Spinner while waiting for first playable data — never on user pause.
        if (!streamOpened) ui.spinner = !userSeeking && !userPaused
        if (userPaused || streamOpened) {
            ui.preparing = false
        }
    }

    private fun applyStatusLine(line: String) {
        if (userSeeking || seekTargetMs >= 0) return
        statusText = line
    }

    /** Buffering X% · download · peers — never upload, never duplicate 0.0 KB/s. */
    private fun prePlayBufferLine(pct: Int, downloadMbps: Double, peers: Int = 0): String {
        val shown = pct.coerceIn(0, 100)
        return buildString {
            if (downloadMbps >= 0.05) {
                append(getString(R.string.buffering_pct_speed, shown.coerceAtLeast(1), downloadMbps))
            } else {
                append(getString(R.string.buffering_pct, shown.coerceAtLeast(1)))
            }
            if (peers > 0) append("  ·  $peers peers")
        }
    }

    /**
     * "Playing · 1.2 MB/s · 48 peers · 35 s buffered". The old line showed the
     * player's buffer as a share of the whole film, which read "0% buffered".
     */
    private fun playingLine(downloadMbps: Double, peers: Int): String {
        val mp = player
        val aheadS = if (mp != null) ((mp.bufferedPositionMs - mp.time) / 1000L).coerceAtLeast(0L) else 0L
        return buildString {
            append("Playing")
            if (downloadMbps >= 0.05) append(String.format(java.util.Locale.US, "  ·  %.1f MB/s", downloadMbps))
            if (peers > 0) append("  ·  $peers peers")
            if (aheadS > 0) append("  ·  ${aheadS}s buffered")
        }
    }

    /** It keeps downloading while paused; show that it does. */
    private fun pausedLine(downloadMbps: Double, peers: Int): String = buildString {
        append("Paused")
        if (downloadMbps >= 0.05) append(String.format(java.util.Locale.US, "  ·  %.1f MB/s", downloadMbps))
        if (peers > 0) append("  ·  $peers peers")
    }

    private fun underrunBufferLine(downloadMbps: Double): String =
        if (downloadMbps >= 0.05) {
            String.format(java.util.Locale.US, "Buffering… · %.1f MB/s", downloadMbps)
        } else {
            "Buffering…"
        }

    private fun torrentStatusLine(bufferPct: Int, downloadMbps: Double, peers: Int = 0): String {
        val pct = bufferPct.coerceIn(0, 100)
        return when {
            streamOpened && exoBuffering -> underrunBufferLine(downloadMbps)
            streamOpened && downloadMbps >= 0.05 ->
                playingLine(downloadMbps, peers)
            else ->
                prePlayBufferLine(pct.coerceAtLeast(1), downloadMbps, peers)
        }
    }

    override fun surfaceCreated(holder: SurfaceHolder) {
        surfaceReady = true
        if (!pendingUrl.isNullOrBlank()) {
            ensurePlayer()
            player?.attachSurface(findViewById(R.id.surface))
            player?.setAspectMode(application.asTv().session.aspectRatio)
            attachAndPlay()
        }
    }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) = Unit

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        surfaceReady = false
        player?.attachSurface(null)
    }

    private fun ensurePlayer(forceExo: Boolean = false) {
        if (player != null) return
        val engine = if (forceExo) {
            SessionStore.PLAYER_EXO
        } else {
            application.asTv().session.playbackEngine
        }
        AppLog.i(TAG, "ensurePlayer engine=$engine hwDecode=$hwDecode")
        player = if (engine == SessionStore.PLAYER_VLC) {
            VlcPlayback(this, playbackListener())
        } else {
            TvPlayback(this, playbackListener())
        }
        player?.bindSubtitles(findViewById(R.id.subtitles))
        SubtitleLook.apply(this, player)
        if (subDelayMs != 0L) player?.setSubtitleDelay(subDelayMs)
        val frame = findViewById<androidx.media3.ui.AspectRatioFrameLayout>(R.id.video_frame)
        (player as? TvPlayback)?.attachFrame(frame)
        (player as? VlcPlayback)?.attachFrame(frame)
        player?.setAspectMode(application.asTv().session.aspectRatio)
    }

    private fun playbackListener() = object : PlaybackEngine.Listener {
            override fun onOpening() {
                main.post {
                    statusText = "Opening…"
                    Log.i(TAG, "ExoPlayer opening")
                }
            }

            override fun onBuffering(percent: Int) {
                main.post {
                    // Match 6ee3433: keep torrent HUD % while attaching. Using Exo's
                    // percent here reset the bar to 0% and looked stuck at "Starting…".
                    exoBuffering = percent < 100
                    if (!streamOpened) {
                        val tick = lastSession
                        val mbps = tick?.downloadMbps ?: 0.0
                        val torrentFrac = tick?.bufferProgress ?: 0.0
                        val fileDone = (tick?.progress ?: 0.0) >= 0.99
                        val buf = displayBufferPct(torrentFrac, exoPercent = percent)
                        if (!userSeeking) {
                            applyStatusLine(
                                torrentStatusLine(buf, mbps, tick?.peers ?: 0),
                            )
                            ui.bufferPct = buf
                        }
                        ui.spinner = true
                        applyBufferingChrome()
                        // File already on disk / torrent ready but demuxer idle —
                        // nudge play so we don't sit at Buffering 100% forever.
                        if (mediaAttached &&
                            (fileDone || torrentReadyLatched || buf >= 99) &&
                            !userPaused
                        ) {
                            runCatching { player?.play() }
                        }
                    } else {
                        if (chromeVisible && !userSeeking && !userPaused && percent < 100) {
                            val mbps = lastSession?.downloadMbps ?: 0.0
                            applyStatusLine(underrunBufferLine(mbps))
                        }
                    }
                    if (isStream && !userSeeking && percent < 100) {
                        nudgeTorrentAtPlayhead()
                        if (streamOpened && lastGoodPosMs > 5_000L) {
                            armBufferStallWatch()
                        }
                    }
                }
            }

            override fun onPlaying() {
                val mp = player ?: return
                main.post {
                    Log.i(TAG, "ExoPlayer playing pos=${mp.time} len=${mp.length}")
                    val firstOpen = !streamOpened
                    streamOpened = true
                    // An episode started from the top counts right away, so the series
                    // moves on to it without waiting for the first periodic save.
                    if (firstOpen && episodeId != null && openStartMs <= 2_000L) {
                        saveWatchProgress(force = true, episodeStarted = true)
                    }
                    exoBuffering = false
                    userPaused = false
                    torrentReadyLatched = true
                    cancelEndCountdown()
                    prePlayRecoveries = 0
                    mediaAttachAtMs = 0L
                    cancelBufferStallWatch()
                    ui.bufferPct = 100
                    ui.preparing = false
                    renderTransport()
                    if (firstOpen) {
                        // Clean start: hide transport; Skip/Next may appear on their own layer.
                        // Only here: this also fires after every pause, seek and rebuffer,
                        // where it closed the controls and took focus from the user.
                        ui.spinner = false
                        chromeVisible = false
                        applyPlayingChrome(showTransport = false)
                        ui.focused = null
                        main.removeCallbacks(tickProgress)
                        main.post(tickProgress)
                    } else {
                        scheduleHideChrome()
                    }
                    maybeLoadSegments()
                }
            }

            override fun onPaused() {
                main.post {
                    userPaused = true
                    exoBuffering = false
                    if (!userSeeking) statusText = "Paused"
                    renderTransport()
                    // User pause ≠ underrun buffering — show full transport chrome.
                    applyPlayingChrome(showTransport = true)
                    showChrome()
                    if (ui.focused == null) ui.focused = Ctl.PLAY
                }
            }

            override fun onStateChanged() {
                main.post { renderTransport() }
            }

            override fun onError(isDecoderError: Boolean) {
                main.post {
                    Log.e(TAG, "player error url=${app.peanutbutter.core.AppLog.safeUrl(pendingUrl)} hw=$hwDecode decoder=$isDecoderError")
                    AppLog.e(TAG, "player error hw=$hwDecode decoder=$isDecoderError")
                    if (isDecoderError && hwDecode) {
                        hwDecode = false
                        mediaAttached = false
                        statusText = "Retrying with FFmpeg…"
                        attachAndPlay()
                        return@post
                    }
                    // Soft IO / underrun — recover in place without rebuilding media.
                    val canSoft = mediaAttached || streamOpened || isStream
                    if (canSoft && softErrorCount < 8) {
                        val now = System.currentTimeMillis()
                        val gap = if (streamOpened || lastGoodPosMs > 2_000L) 3_000L else 5_000L
                        if (now - lastSoftErrorMs < gap) return@post
                        lastSoftErrorMs = now
                        softErrorCount++
                        val recover = lastGoodPosMs.coerceAtLeast(0L)
                        val mbps = lastSession?.downloadMbps ?: 0.0
                        statusText = if (mbps > 0.05) {
                            String.format(java.util.Locale.US, "Buffering… · %.1f MB/s", mbps)
                        } else {
                            "Buffering…"
                        }
                        ui.spinner = true
                        if (localTorrent) {
                            TorrentClient.retargetPlayhead(
                                recover,
                                player?.length?.takeIf { it > 0 } ?: lastKnownDurationMs,
                            )
                        }
                        // While downloading, just wait + retarget — don't reopen/seek yet.
                        val delayMs = when {
                            !streamOpened && mbps >= 0.15 -> 4_000L
                            !streamOpened -> 2_500L
                            mbps >= 0.25 -> 2_000L
                            else -> 800L
                        }
                        main.postDelayed({
                            if (stopped) return@postDelayed
                            runCatching {
                                val mp = player ?: return@runCatching
                                if (!streamOpened && softErrorCount >= 3 && !pendingUrl.isNullOrBlank()) {
                                    mediaAttached = false
                                    attachAndPlay()
                                } else {
                                    // prepare() resumes from the same position. Seeking back
                                    // here replayed the same seconds on every error.
                                    mp.play()
                                }
                            }
                        }, delayMs)
                        return@post
                    }
                    statusText = getString(R.string.playback_error)
                    ui.spinner = false
                    showChrome()
                    renderTransport()
                    ui.focused = Ctl.PLAY
                }
            }

            override fun onEnded() {
                main.post { handleEndReached() }
            }

            override fun onTime(positionMs: Long) {
                if (positionMs > lastGoodPosMs) lastGoodPosMs = positionMs
            }

            override fun onDuration(durationMs: Long) {
                if (durationMs > 0) {
                    lastKnownDurationMs = durationMs
                    main.post { ui.durMs = durationMs }
                }
            }
    }

    private fun handleEndReached() {
        val mp = player ?: return
        val len = mp.length
        val pos = lastGoodPosMs.coerceAtLeast(mp.time)
        val nearEnd = len <= 0 ||
            (len > 30_000 && pos >= (len * 0.88).toLong()) ||
            (len > 0 && len - pos <= 8_000)
        val downloadDone = lastSession?.let { session ->
            // Only trust full-file completion — buffer% caps at 90 while streaming.
            session.progress >= 0.995 && session.bufferProgress >= 0.995 &&
                session.downloadMbps < 0.02
        } == true && (lastKnownDurationMs <= 0 || lastGoodPosMs >= lastKnownDurationMs * 0.85)
        // Only treat as false EOF while the torrent is still downloading mid-file.
        if (isStream && !nearEnd && !downloadDone && falseEofCount < 20) {
            falseEofCount++
            val recover = lastGoodPosMs.coerceAtLeast(0)
            Log.w(TAG, "false EOF #$falseEofCount — resume at $recover (len=$len)")
            statusText = "Reconnecting…"
            ui.spinner = true
            if (localTorrent) {
                TorrentClient.retargetPlayhead(recover, len.coerceAtLeast(0))
            }
            main.postDelayed({
                if (stopped) return@postDelayed
                runCatching {
                    if (recover > 1_000) mp.seekTo(recover)
                    mp.play()
                }
            }, (600L * falseEofCount).coerceAtMost(5_000L)) // let the pieces arrive
            return
        }
        if (isStream && !nearEnd && !downloadDone) {
            // Still mid-file after many reconnects: never close the movie on a
            // false end. Keep the player open so OK / Play retries from here.
            Log.w(TAG, "false EOF limit reached at $pos (len=$len) — staying open")
            statusText = getString(R.string.playback_error)
            ui.spinner = false
            saveWatchProgress(force = true)
            showChrome()
            return
        }
        statusText = "Ended"
        saveWatchProgress(force = true, complete = true)
        if (stopped || isFinishing) return
        // Same as desktop / phone: offer the next episode for 30 s, then leave.
        if (nextEpisode != null) {
            endCountdownLeft = END_COUNTDOWN_S
            ui.nextTitle = getString(R.string.play_next_countdown, endCountdownLeft)
            showPlayNext(true)
            ui.focused = Ctl.NEXT
            main.removeCallbacks(endCountdown)
            main.postDelayed(endCountdown, 1_000L)
            return
        }
        finish()
    }

    private fun cancelEndCountdown() {
        if (endCountdownLeft <= 0) return
        endCountdownLeft = 0
        main.removeCallbacks(endCountdown)
        ui.nextTitle = getString(R.string.play_next)
    }

    /**
     * Play / pause icon, paused flag and rebuffer spinner, all from the player's
     * own state. Icons used to be set by hand in a few callbacks and drifted.
     */
    private fun renderTransport() {
        val mp = player ?: return
        val showPlay = !mp.wantsToPlay || mp.needsRestart
        ui.showPlayIcon = showPlay
        if (!streamOpened) return
        userPaused = !mp.wantsToPlay
        if (localTorrent && userPaused != pausedSentToEngine) {
            pausedSentToEngine = userPaused
            TorrentClient.setPaused(userPaused)
        }
        main.removeCallbacks(showRebufferSpinner)
        if (mp.isBuffering && (mp.wantsToPlay || userSeeking)) {
            main.postDelayed(showRebufferSpinner, REBUFFER_SPINNER_DELAY_MS)
        } else {
            ui.spinner = false
        }
        scheduleHideChrome()
    }

    private fun armBufferStallWatch() {
        if (!isStream || userSeeking || stopped) return
        if (lastGoodPosMs < 5_000L) return
        if (bufferingSinceMs != 0L) return // already armed; don't reset on % ticks
        bufferingSinceMs = System.currentTimeMillis()
        main.removeCallbacks(bufferStallRecover)
        main.postDelayed(bufferStallRecover, BUFFER_STALL_CHECK_MS)
    }

    private fun cancelBufferStallWatch() {
        bufferingSinceMs = 0L
        main.removeCallbacks(bufferStallRecover)
    }

    private fun nudgeTorrentAtPlayhead() {
        if (!localTorrent) return
        val now = System.currentTimeMillis()
        // Don't thrash the swarm — soft retarget at most every 4s.
        if (now - lastTorrentNudgeMs < 4_000L) return
        val mp = player ?: return
        val pos = mp.time.coerceAtLeast(lastGoodPosMs)
        val dur = mp.length.takeIf { it > 0 }
            ?: lastKnownDurationMs.takeIf { it > 0 }
            ?: return
        lastTorrentNudgeMs = now
        TorrentClient.retargetPlayhead(pos, dur)
    }

    /**
     * Still buffering after a long wait. Never seek back: replaying the last
     * second on every stall was the "stops and plays again from the same point"
     * loop, and each resume reset its limit. Point the swarm at the playhead and
     * wait; only with no data at all, reopen at the same position a couple of times.
     */
    private fun recoverFromBufferStall() {
        bufferingSinceMs = 0L
        if (stopped || !isStream || userSeeking) return
        val mp = player ?: return
        if (mp.isPlaying || !mp.wantsToPlay) return
        nudgeTorrentAtPlayhead()
        val mbps = lastSession?.downloadMbps ?: 0.0
        if (mbps < 0.05 && stallRecoverCount < MAX_STALL_REOPENS) {
            stallRecoverCount++
            Log.w(TAG, "no data while stalled — reopen #$stallRecoverCount at $lastGoodPosMs")
            mediaAttached = false
            runCatching { mp.stop() }
            attachAndPlay()
        }
        armBufferStallWatch()
    }

    private fun attachAndPlay() {
        val url = pendingUrl?.takeIf { it.isNotBlank() } ?: return
        if (askingResume) return
        if (!resumeAsked && !mediaAttached && resumeMs > 2_000L) {
            resumeAsked = true
            askResume()
            return
        }
        if (mediaAttached) {
            if (surfaceReady) {
                player?.attachSurface(findViewById(R.id.surface))
            }
            if (!streamOpened && !userPaused) {
                runCatching { player?.play() }
                val stuckMs =
                    if (mediaAttachAtMs > 0) System.currentTimeMillis() - mediaAttachAtMs else 0L
                // Torrent may already be 100% while Exo never leaves BUFFERING —
                // force a clean reopen a few times instead of spinning forever.
                // 6 s was shorter than a normal container probe (MKV cues / MP4
                // moov live at the END of the file and must come from the swarm),
                // so healthy streams were torn down and restarted up to 4 times
                // and sometimes never started. Give the first open real time.
                if (stuckMs > PRE_PLAY_REOPEN_MS && prePlayRecoveries < 3) {
                    prePlayRecoveries++
                    Log.w(TAG, "pre-play stuck ${stuckMs}ms — reopening (#$prePlayRecoveries)")
                    AppLog.i(TAG, "pre-play reopen #$prePlayRecoveries after ${stuckMs}ms")
                    mediaAttached = false
                    mediaAttachAtMs = 0L
                    runCatching { player?.stop() }
                    // Fall through to open again.
                } else {
                    return
                }
            } else {
                return
            }
        }
        if (!surfaceReady) {
            Log.i(TAG, "attachAndPlay waiting for surface")
            return
        }
        ensurePlayer()
        val mp = player ?: return
        try {
            Log.i(TAG, "attachAndPlay hw=$hwDecode ${app.peanutbutter.core.AppLog.safeUrl(url)}")
            mp.attachSurface(findViewById(R.id.surface))
            // A reopen (stuck start, decoder fallback) must keep the resume point:
            // it used to restart the movie from 0:00.
            val start = when {
                resumeMs > 0 -> resumeMs
                lastGoodPosMs > 2_000L -> lastGoodPosMs
                else -> openStartMs
            }
            resumeMs = 0
            openStartMs = start
            // If torrent start() already targeted resumeMs, do not soft-seek again
            // with a guessed duration (that yanked playhead 205→55 in logs).
            if (localTorrent && start > 2_000L && !torrentStartedWithResume && lastKnownDurationMs > 0) {
                TorrentClient.retargetPlayhead(start, lastKnownDurationMs)
            }
            mediaAttached = true
            mediaAttachAtMs = System.currentTimeMillis()
            mp.open(url, start, preferSoftware = !hwDecode, headers = if (url == directUrl) directHeaders else emptyMap())
            runCatching { mp.play() }
            statusText = getString(R.string.starting_stream)
            // Watchdog: if onPlaying never fires, reopen from the next stats tick.
            main.postDelayed({
                if (stopped || streamOpened || userPaused) return@postDelayed
                if (mediaAttached && !pendingUrl.isNullOrBlank()) {
                    Log.w(TAG, "pre-play watchdog — nudge attachAndPlay")
                    attachAndPlay()
                }
            }, PRE_PLAY_REOPEN_MS + 1_000L)
        } catch (e: Exception) {
            Log.e(TAG, "attachAndPlay failed", e)
            statusText = e.message ?: getString(R.string.playback_error)
            ui.spinner = false
            mediaAttached = false
            mediaAttachAtMs = 0L
        }
    }

    private fun queueSeek(targetMs: Long, settleMs: Long) {
        seekTargetMs = targetMs.coerceAtLeast(0)
        userSeeking = true
        seekToken++
        val token = seekToken
        statusText = "Seeking ${formatMs(seekTargetMs)}…"
        cancelEndCountdown()
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
        val durationMs = mp.length.takeIf { it > 0 }
            ?: lastKnownDurationMs.takeIf { it > 0 }
            ?: 0L
        Log.i(TAG, "commitSeek $target dur=$durationMs")
        try {
            // Retarget swarm BEFORE the player Range request so pieces arrive at the scrub.
            if (localTorrent) {
                TorrentClient.seekTo(target, durationMs, aggressive = true)
            }
            mp.seekTo(target)
            lastGoodPosMs = target
            recoveryAnchorMs = target
            statusText = "Buffering at ${formatMs(target)}…"
        } catch (e: Exception) {
            Log.e(TAG, "seek failed", e)
        }
        main.postDelayed({
            if (token == seekToken) {
                userSeeking = false
                seekTargetMs = -1
                renderTransport()
            }
        }, 1_500L)
    }

    private fun maybeLoadSegments() {
        val tid = titleId ?: return
        if (System.currentTimeMillis() < segmentsRetryAtMs) return
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
                AppLog.i(
                    TAG,
                    "segments title=$tid s=$seasonNum e=$episodeNum kind=$kind dur=$dur -> " +
                        segs.joinToString { "${it.kind} ${it.startMs}-${it.endMs}" }.ifEmpty { "none" },
                )
                if (segs.isEmpty() && !haveDuration) segmentsLoaded = false
            } catch (e: Exception) {
                Log.w(TAG, "mediaSegments failed", e)
                segmentsLoaded = false
                segmentsRetryAtMs = System.currentTimeMillis() + RETRY_LOOKUP_MS
            }
        }
    }

    private fun loadNextEpisode() {
        if (nextLoaded || nextEpisode != null) return
        if (System.currentTimeMillis() < nextRetryAtMs) return // this runs from the 400 ms tick
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
                nextRetryAtMs = System.currentTimeMillis() + RETRY_LOOKUP_MS
                Log.w(TAG, "next episode lookup failed", e)
            }
        }
    }

    private fun findNextEpisode(item: TitleItem, season: Int, episode: Int): NextEpisode? {
        val seasons = item.seasons.filter { it.seasonNumber > 0 }.sortedBy { it.seasonNumber }
        val current = seasons.firstOrNull { it.seasonNumber == season }
        // java.time needs Android 8 (API 26); the app supports 7.0, where
        // LocalDate.now() crashed the player at the end of an episode.
        val today = java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.US).format(java.util.Date())
        fun aired(e: app.peanutbutter.core.Episode) = e.airDate?.take(10)?.let { it <= today } ?: true
        // Same order as the episode list on the details screen.
        val later = current?.let { TorrentFilePicker.inViewingOrder(item.seasons, it) }
            ?.dropWhile { it.episodeNumber != episode }
            ?.drop(1)
            ?.firstOrNull(::aired)
        if (later != null) {
            return NextEpisode(
                season, later.episodeNumber, later.id, item.displayTitle, item.kind, item.posterUrl, item.backdropUrl,
                TorrentFilePicker.releaseEpisode(item.seasons, season, later.episodeNumber),
            )
        }
        for (s in seasons) {
            if (s.seasonNumber <= season) continue
            val first = TorrentFilePicker.inViewingOrder(item.seasons, s)
                .firstOrNull { it.episodeNumber > 0 && aired(it) } ?: continue
            return NextEpisode(
                s.seasonNumber, first.episodeNumber, first.id, item.displayTitle, item.kind, item.posterUrl, item.backdropUrl,
                TorrentFilePicker.releaseEpisode(item.seasons, s.seasonNumber, first.episodeNumber),
            )
        }
        return null
    }

    private fun updateSkipNext() {
        if (!streamOpened) return
        maybeLoadSegments()
        loadNextEpisode()
        val mp = player ?: return
        // During a seek use its target: the old position would bring Skip straight back.
        val pos = (if (seekTargetMs >= 0) seekTargetMs else mp.time).toInt()
        val dur = mp.length.toInt()
        skippedSegment?.let { if (!it.contains(pos, dur)) skippedSegment = null }
        val opening = segments.firstOrNull {
            (it.kind.equals("INTRO", true) || it.kind.equals("RECAP", true)) &&
                it.contains(pos, dur) && it != skippedSegment
        }
        activeSegment = opening
        val showSkip = opening != null
        val wasSkip = ui.skipLabel != null
        if (showSkip) {
            ui.skipLabel = opening?.label?.ifBlank { null } ?: getString(R.string.skip_intro)
            // Don't take focus from someone using the controls.
            if (!wasSkip && !chromeVisible) ui.focused = Ctl.SKIP
        } else {
            ui.skipLabel = null
            if (ui.focused == Ctl.SKIP) ui.focused = null
        }
        val nearEnd = dur > 60_000 && (pos >= dur - 45_000 || pos.toDouble() / dur >= 0.97)
        val inCredits = segments.any { it.kind.equals("CREDITS", true) && it.contains(pos, dur) }
        // Promote to Watched (~85% / credits) without waiting for app reopen.
        val mostlyDone = dur >= 5 * 60_000 && pos > 0 && pos >= (dur * 0.85).toInt()
        if ((mostlyDone || inCredits) && !markedComplete) {
            markedComplete = true
            saveWatchProgress(force = true, complete = true)
        }
        showPlayNext(
            !nextBusy && (endCountdownLeft > 0 || (!showSkip && (nearEnd || inCredits) && nextEpisode != null)),
        )
    }

    private fun showPlayNext(show: Boolean) {
        if (!show) {
            if (ui.focused == Ctl.NEXT) ui.focused = null
            playNextVisible = false
            ui.nextShown = false
            return
        }
        val was = playNextVisible
        playNextVisible = true
        ui.nextLabel = nextEpisode?.let {
            String.format(java.util.Locale.US, "%s · S%02dE%02d", it.catalogTitle, it.season, it.episode)
        }
        ui.nextShown = true
        // Own layer — do not dump the whole transport chrome.
        if (!was && !chromeVisible) ui.focused = Ctl.NEXT
    }

    /** Press feedback: the control shrinks a moment, then [then] runs. */
    private fun pulseAction(ctl: Ctl, then: () -> Unit) {
        ui.pressed = ctl
        main.postDelayed({
            ui.pressed = null
            then()
        }, 120L)
    }

    /** OK on the lit control. */
    private fun activate(ctl: Ctl) {
        when (ctl) {
            Ctl.BACK -> pulseAction(ctl) { handleBackPress() }
            Ctl.AUDIO -> pulseAction(ctl) { openAudio() }
            Ctl.SUBS -> pulseAction(ctl) { openSubtitles() }
            Ctl.ASPECT -> pulseAction(ctl) { openAspect() }
            Ctl.REW -> {
                seekBy(-10_000)
                showChrome()
            }
            Ctl.FF -> {
                seekBy(10_000)
                showChrome()
            }
            Ctl.PLAY, Ctl.SEEK -> togglePlay()
            Ctl.SKIP -> pulseAction(ctl) { skipActiveSegment() }
            Ctl.NEXT -> pulseAction(ctl) { playNextEpisode() }
        }
    }

    /** The chip shown bottom-left, if any (Skip and Play Next never show together). */
    private fun visibleChip(): Ctl? = when {
        ui.skipLabel != null -> Ctl.SKIP
        ui.nextShown -> Ctl.NEXT
        else -> null
    }

    /**
     * D-pad between the controls, laid out like the desktop player:
     * Back · title · Audio · Subtitles · Picture on top, the seek bar, then
     * −10 · Play · +10. Skip / Play Next sit bottom-left, left of −10.
     */
    private fun moveFocus(from: Ctl, keyCode: Int): Ctl? {
        val chip = visibleChip()
        val top = listOfNotNull(Ctl.BACK, Ctl.AUDIO.takeIf { ui.audioChoice }, Ctl.SUBS, Ctl.ASPECT)
        val transport = listOf(Ctl.REW, Ctl.PLAY, Ctl.FF)
        return when (keyCode) {
            KeyEvent.KEYCODE_DPAD_LEFT -> when (from) {
                in top -> top.getOrNull(top.indexOf(from) - 1)
                Ctl.REW -> chip
                in transport -> transport[transport.indexOf(from) - 1]
                else -> null
            }
            KeyEvent.KEYCODE_DPAD_RIGHT -> when (from) {
                in top -> top.getOrNull(top.indexOf(from) + 1)
                in transport -> transport.getOrNull(transport.indexOf(from) + 1)
                Ctl.SKIP, Ctl.NEXT -> Ctl.REW
                else -> null
            }
            KeyEvent.KEYCODE_DPAD_UP -> when (from) {
                in transport -> chip ?: Ctl.SEEK
                Ctl.SEEK -> chip ?: Ctl.SUBS
                Ctl.SKIP, Ctl.NEXT -> Ctl.SUBS
                else -> null
            }
            KeyEvent.KEYCODE_DPAD_DOWN -> when (from) {
                in top -> chip ?: Ctl.SEEK
                Ctl.SKIP, Ctl.NEXT -> Ctl.SEEK
                Ctl.SEEK -> Ctl.PLAY
                else -> null
            }
            else -> null
        }
    }

    private fun playNextEpisode() {
        val next = nextEpisode ?: return
        val tid = titleId ?: return
        if (nextBusy) return
        nextBusy = true
        // The button has done its job: hide it (and stop the end countdown,
        // which would close the player mid-lookup). The loading card stays.
        cancelEndCountdown()
        showPlayNext(false)
        statusText = getString(R.string.looking_up_sources)
        // Finding a source takes a while: stop the old episode and say what's happening.
        val wasPlaying = player?.wantsToPlay == true
        runCatching { player?.pause() }
        ui.nextLoading = String.format(java.util.Locale.US, "%s · S%02dE%02d", next.catalogTitle, next.season, next.episode)
        lifecycleScope.launch {
            try {
                saveWatchProgress(force = true, complete = true)
                // Drop previous episode pieces when clear-cache-on-exit is enabled.
                maybeWipeStreamCache()
                val api = application.asTv().api
                val label = String.format(java.util.Locale.US, "%s S%02dE%02d", next.catalogTitle, next.season, next.episode)
                val searchEp = next.fileEpisode ?: next.episode
                val query = String.format(java.util.Locale.US, "%s S%02dE%02d", next.catalogTitle, next.season, searchEp)
                // Already ranked by the server (same order the picker shows).
                val source = api.lookupSources(query, next.kind, tid, next.season, searchEp).firstOrNull()
                if (source == null) {
                    Toast.makeText(this@PlayerActivity, R.string.no_sources, Toast.LENGTH_LONG).show()
                    return@launch
                }
                // The new player starts its torrent before this one is destroyed;
                // onDestroy must not stop/wipe it (TorrentClient is process-wide).
                handedOffToNext = true
                startActivity(
                    Intent(this@PlayerActivity, PlayerActivity::class.java)
                        .putExtra(EXTRA_TITLE, label)
                        .putStreamSource(source.magnet, source.url.takeIf { source.isHttp }, source.headers)
                        .putExtra(EXTRA_POSTER, next.posterUrl)
                        .putExtra(EXTRA_BACKDROP, next.backdropUrl)
                        .putExtra(EXTRA_TITLE_ID, tid)
                        .putExtra(EXTRA_EPISODE_ID, next.episodeId)
                        .putExtra(EXTRA_KIND, next.kind)
                        .putExtra(EXTRA_SEASON, next.season)
                        .putExtra(EXTRA_EPISODE, next.episode)
                        .putExtra(EXTRA_FILE_EPISODE, next.fileEpisode ?: -1)
                        .putExtra(EXTRA_RESUME_MS, 0L),
                )
                finish()
            } catch (e: Exception) {
                Log.e(TAG, "play next failed", e)
                Toast.makeText(this@PlayerActivity, e.message, Toast.LENGTH_LONG).show()
            } finally {
                nextBusy = false
                // Handed off: stay covered until the new player takes over.
                if (!handedOffToNext) {
                    ui.nextLoading = null
                    if (wasPlaying) {
                        // Still watching this episode, so keep saving its position.
                        markedComplete = false
                        runCatching { player?.play() }
                    }
                    if (ui.nextShown) ui.focused = Ctl.NEXT
                }
            }
        }
    }

    private fun skipActiveSegment() {
        val seg = activeSegment ?: return
        val mp = player ?: return
        val dur = mp.length.toInt()
        val target = seg.skipTargetMs(dur).toLong()
        skippedSegment = seg
        activeSegment = null
        // Hide chip after the pulse; keep focus on root so transport doesn't steal it.
        ui.skipLabel = null
        ui.focused = null
        showHud(getString(R.string.skip_intro))
        queueSeek(target, settleMs = 100L)
    }

    private fun togglePlay() {
        val mp = player ?: return
        // By intent, not isPlaying: that's false while buffering, so Pause did nothing.
        if (mp.wantsToPlay && !mp.needsRestart) {
            mp.pause()
        } else {
            softErrorCount = 0
            stallRecoverCount = 0
            // Resuming means back to watching: get out of the way soon.
            hideDelayMs = CHROME_HIDE_AFTER_RESUME_MS
            mp.play()
        }
        renderTransport()
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
            ui.durMs = len
        }
        ui.posMs = target
        queueSeek(target, settleMs = if (isStream) 700L else 50L)
        // Scrubbing shows transport; Skip-driven seeks do not (they call queueSeek directly).
        if (ui.focused != Ctl.SKIP && ui.focused != Ctl.NEXT) {
            showChrome()
        }
    }

    private fun updateProgressUi() {
        val mp = player ?: return
        if (userSeeking) return
        val len = mp.length
        val pos = mp.time
        if (pos > lastGoodPosMs) lastGoodPosMs = pos
        // Retry limits come back only after real progress; a one-second resume
        // between failures used to reset them, so the loops never ended.
        if (pos - recoveryAnchorMs > RECOVERY_RESET_MS) {
            recoveryAnchorMs = pos
            falseEofCount = 0
            stallRecoverCount = 0
            softErrorCount = 0
        }
        ui.subsOn = mp.selectedTextTrackId != null
        ui.canSeek = len > 0
        if (len > 0) {
            // Lighter track = what's ready to play: the player's own buffer (at most
            // a minute) or, usually further, what the torrent has without gaps.
            // The playhead can read a few ms past the length in the last second;
            // coerceIn(pos, len) then threw and the player crashed at every ending.
            val buffered = maxOf(mp.bufferedPositionMs, (torrentDownloadedTo * len).toLong())
                .coerceIn(pos.coerceAtMost(len), len)
            ui.bufMs = buffered
            ui.durMs = len
        } else {
            ui.durMs = 0
        }
        ui.posMs = pos
        saveWatchProgress()
    }

    /** Write resume position so the home Continue watching row can list this title. */
    private fun saveWatchProgress(
        force: Boolean = false,
        complete: Boolean = false,
        episodeStarted: Boolean = false,
    ) {
        val id = titleId?.takeIf { it.isNotBlank() } ?: return
        // Once finished, a later plain save would park the resume point back near
        // the end and put the episode back in Continue watching.
        if (markedComplete && !complete) return
        val mp = player
        val length = mp?.length?.takeIf { it > 0L } ?: lastKnownDurationMs.takeIf { it > 0L } ?: 0L
        var pos = when {
            mp != null && mp.time > 0L -> mp.time
            else -> lastGoodPosMs
        }
        if (complete && length > 0L) pos = maxOf(pos, length)
        if (!complete && !episodeStarted && pos < 2_000L) return
        // Every save is two mutations (progress + stream bookmark); 15s keeps
        // resume accurate without a server write every few seconds.
        if (!force && !complete && lastSavedPosMs >= 0L && kotlin.math.abs(pos - lastSavedPosMs) < 15_000L) return
        // onPause + onStop + onDestroy all flush: send it once.
        if (force && !complete && pos == lastSavedPosMs) return
        val dur = length.takeIf { it > 0L }
        lastSavedPosMs = pos
        if (complete) markedComplete = true
        val ep = episodeId
        val api = application.asTv().api
        // Direct links are saved in the bookmark's magnet field; Resume tells
        // them apart by the http(s) scheme.
        val mag = magnet ?: directUrl
        val sid = sessionId.orEmpty().ifBlank { "local" }
        val titleText = fullTitle
        val write = suspend {
            api.updateProgress(
                titleId = id,
                episodeId = ep,
                positionMs = pos,
                durationMs = dur,
                complete = complete,
            )
            if (!mag.isNullOrBlank()) {
                api.streamResume(
                    sessionId = sid,
                    positionMs = if (complete) 0L else pos,
                    titleId = id,
                    title = titleText,
                    magnet = mag,
                    season = seasonNum,
                    episode = episodeNum,
                    fileIndex = fileIndex,
                )
            }
        }
        // This used to runBlocking on the main thread for pause / stop / episode end;
        // OkHttp ignores coroutine timeouts, so an unreachable server froze the UI for
        // the full connect timeout (ANR on exit). The app-scoped queue outlives this
        // Activity and keeps a finished episode's save ahead of the next one's.
        application.asTv().enqueueWrite(write)
    }

    private fun formatMs(ms: Long): String {
        val total = (ms / 1000).toInt().coerceAtLeast(0)
        val h = total / 3600
        val m = (total % 3600) / 60
        val s = total % 60
        return if (h > 0) String.format(java.util.Locale.US, "%d:%02d:%02d", h, m, s)
        else String.format(java.util.Locale.US, "%d:%02d", m, s)
    }

    private fun showChrome() {
        if (!streamOpened) {
            // Pre-play only: title + buffer status (no transport).
            chromeVisible = true
            applyBufferingChrome()
            main.removeCallbacks(hideChrome)
            syncSubtitlePad()
            return
        }
        chromeVisible = true
        applyPlayingChrome(showTransport = true)
        scheduleHideChrome()
        syncSubtitlePad()
    }

    private fun syncSubtitlePad() {
        (player as? TvPlayback)?.setSubtitlesChromeVisible(chromeVisible && streamOpened)
    }

    /**
     * Pre-play underrun / peer-find chrome only.
     * Intentional pause uses the normal transport bar ([applyPlayingChrome]).
     */
    private fun isBufferingUi(): Boolean = !streamOpened

    private fun applyBufferingChrome() {
        ui.preparing = true
        ui.chrome = false
        // Back is the one control before playback (OK on it asks to leave).
        if (ui.focused == null) ui.focused = Ctl.BACK
        main.removeCallbacks(hideChrome)
    }

    private fun applyPlayingChrome(showTransport: Boolean) {
        ui.preparing = false
        chromeVisible = showTransport
        ui.audioChoice = hasAltAudio()
        ui.chrome = showTransport
        syncSubtitlePad()
    }

    private fun setChrome(visible: Boolean) {
        // Never fade away the buffering banner before playback starts.
        if (!visible && isBufferingUi()) {
            applyBufferingChrome()
            return
        }
        if (!visible && streamOpened && !userSeeking) {
            applyPlayingChrome(showTransport = false)
            main.removeCallbacks(hideChrome)
            // Back to the chip, so OK skips as it did before the controls opened.
            ui.focused = visibleChip()
        } else if (visible) {
            showChrome()
        }
    }

    private fun overlaysVisible(): Boolean {
        // Pre-play / buffering chrome is not dismissible via Back — Back exits.
        if (isBufferingUi()) return false
        if (chromeVisible) return true
        // Skip/Next alone count as an overlay so Back can dismiss focus cleanly.
        return ui.focused == Ctl.SKIP || ui.focused == Ctl.NEXT
    }

    private fun hidePlayerUi() {
        if (isBufferingUi()) {
            applyBufferingChrome()
            return
        }
        // If focus is on Skip/Next, first Back clears focus but keeps the chip.
        if (ui.focused == Ctl.SKIP || ui.focused == Ctl.NEXT) {
            ui.focused = null
            if (!chromeVisible) return
        }
        setChrome(false)
        main.removeCallbacks(hideChrome)
        ui.focused = null
    }

    private fun scheduleHideChrome() {
        main.removeCallbacks(hideChrome)
        // Not while a menu is open or the player is paused: the controls stay up.
        if (streamOpened && !userSeeking && !userPaused && chromeVisible && hasWindowFocus() && !ui.overlayOpen) {
            main.postDelayed(hideChrome, hideDelayMs)
        }
    }

    /** Shared by onKeyDown + OnBackPressedDispatcher — never finishes unless user confirms Leave. */
    private fun handleBackPress() {
        if (ui.back()) {
            scheduleHideChrome()
            return
        }
        // While finding peers / buffering: Back always shows leave dialog.
        if (isBufferingUi()) {
            confirmLeave()
            return
        }
        if (overlaysVisible()) {
            hidePlayerUi()
            return
        }
        confirmLeave()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) scheduleHideChrome() else main.removeCallbacks(hideChrome)
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        val code = event.keyCode
        // Menus and cards take the remote while they're open (Back too).
        if (ui.overlayOpen && code != KeyEvent.KEYCODE_VOLUME_UP && code != KeyEvent.KEYCODE_VOLUME_DOWN &&
            code != KeyEvent.KEYCODE_VOLUME_MUTE
        ) {
            if (event.action == KeyEvent.ACTION_DOWN) {
                if (code == KeyEvent.KEYCODE_BACK || code == KeyEvent.KEYCODE_ESCAPE) {
                    if (event.repeatCount == 0) handleBackPress()
                } else {
                    ui.overlayKey(code)
                }
                if (!ui.overlayOpen) scheduleHideChrome()
            }
            return true
        }
        // Before playback only the controls are dead; volume keys must still work.
        // Back still reaches the leave card.
        if (!streamOpened && code in PLAYER_KEYS) {
            if (event.action == KeyEvent.ACTION_DOWN && ui.focused == Ctl.BACK &&
                (code == KeyEvent.KEYCODE_DPAD_CENTER || code == KeyEvent.KEYCODE_ENTER)
            ) {
                confirmLeave()
            }
            return true
        }
        if (event.action == KeyEvent.ACTION_DOWN && chromeVisible) {
            hideDelayMs = CHROME_HIDE_MS
            scheduleHideChrome()
        }
        // Every key goes through onKeyDown: there are no focusable views.
        if (event.action == KeyEvent.ACTION_DOWN) return onKeyDown(code, event) || super.dispatchKeyEvent(event)
        return super.dispatchKeyEvent(event)
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean {
        // Handle Back before showChrome() — otherwise the second Back re-shows
        // chrome and never reaches the exit dialog.
        if (keyCode == KeyEvent.KEYCODE_BACK || keyCode == KeyEvent.KEYCODE_ESCAPE) {
            if ((event?.repeatCount ?: 0) == 0) handleBackPress()
            return true
        }
        if (!streamOpened) return false

        // Media keys work wherever focus is. Only the first press of a held key toggles.
        val firstPress = (event?.repeatCount ?: 0) == 0
        when (keyCode) {
            KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE -> {
                if (firstPress) togglePlay()
                return true
            }
            KeyEvent.KEYCODE_MEDIA_PLAY -> {
                if (firstPress && (player?.wantsToPlay != true || player?.needsRestart == true)) togglePlay()
                return true
            }
            KeyEvent.KEYCODE_MEDIA_PAUSE -> {
                if (firstPress && player?.wantsToPlay == true) togglePlay()
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
            KeyEvent.KEYCODE_MEDIA_NEXT -> {
                if (firstPress && ui.nextShown) playNextEpisode()
                return true
            }
        }

        val isOk = keyCode == KeyEvent.KEYCODE_DPAD_CENTER || keyCode == KeyEvent.KEYCODE_ENTER ||
            keyCode == KeyEvent.KEYCODE_NUMPAD_ENTER || keyCode == KeyEvent.KEYCODE_SPACE
        val isMove = keyCode == KeyEvent.KEYCODE_DPAD_LEFT || keyCode == KeyEvent.KEYCODE_DPAD_RIGHT ||
            keyCode == KeyEvent.KEYCODE_DPAD_UP || keyCode == KeyEvent.KEYCODE_DPAD_DOWN
        val focus = ui.focused

        // A control is lit: OK presses it, arrows move between controls.
        if (focus != null && (chromeVisible || focus == Ctl.SKIP || focus == Ctl.NEXT)) {
            if (isOk) {
                if (firstPress) activate(focus)
                if (focus != Ctl.SKIP && focus != Ctl.NEXT) showChrome() else scheduleHideChrome()
                return true
            }
            if (!isMove) return false
            // Skip / Next are their own layer: with the controls hidden any arrow opens them.
            if (!chromeVisible) {
                showChrome()
                ui.focused = Ctl.SEEK
                return true
            }
            // The seek bar steps by time; holding the key speeds up.
            if (focus == Ctl.SEEK &&
                (keyCode == KeyEvent.KEYCODE_DPAD_LEFT || keyCode == KeyEvent.KEYCODE_DPAD_RIGHT)
            ) {
                val repeat = event?.repeatCount ?: 0
                val step = when {
                    repeat >= 20 -> 60_000L
                    repeat >= 8 -> 30_000L
                    else -> 10_000L
                }
                seekBy(if (keyCode == KeyEvent.KEYCODE_DPAD_LEFT) -step else step)
                return true
            }
            moveFocus(focus, keyCode)?.let { ui.focused = it }
            showChrome()
            return true
        }

        // OK / Enter toggles playback and reveals the controls.
        if (isOk) {
            if (firstPress) togglePlay()
            showChrome()
            ui.focused = Ctl.PLAY
            return true
        }

        when (keyCode) {
            KeyEvent.KEYCODE_DPAD_UP -> {
                // Always surface chrome first (especially when paused with UI hidden).
                showChrome()
                ui.focused = visibleChip() ?: Ctl.PLAY
                return true
            }
            KeyEvent.KEYCODE_DPAD_RIGHT, KeyEvent.KEYCODE_DPAD_LEFT -> {
                // A quick seek with the controls hidden only shows them briefly,
                // with the seek bar lit: more presses keep seeking (3 presses
                // = 30 s). Lighting Play made the next presses move focus instead.
                hideDelayMs = CHROME_HIDE_AFTER_SEEK_MS
                ui.focused = Ctl.SEEK
                seekBy(if (keyCode == KeyEvent.KEYCODE_DPAD_RIGHT) 10_000 else -10_000)
                return true
            }
            KeyEvent.KEYCODE_DPAD_DOWN -> {
                showChrome()
                ui.focused = Ctl.PLAY
                return true
            }
        }
        return false
    }

    private fun confirmLeave() {
        if (ui.leaving) {
            ui.leaving = false
            return
        }
        main.removeCallbacks(hideChrome)
        ui.askLeave()
    }

    /** The desktop's card: Continue from (focused) or Start over, then it plays. */
    private fun askResume() {
        askingResume = true
        var picked = false
        ui.onResume = { fromStart ->
            if (!picked) {
                picked = true
                askingResume = false
                if (fromStart) {
                    resumeMs = 0
                    openStartMs = 0
                    lastGoodPosMs = 0
                    if (localTorrent && lastKnownDurationMs > 0) {
                        runCatching { TorrentClient.retargetPlayhead(0, lastKnownDurationMs) }
                    }
                    torrentStartedWithResume = false
                }
                attachAndPlay()
            }
        }
        // Back on the card: leave, like Back before anything plays.
        ui.onResumeCancel = {
            if (!picked) {
                askingResume = false
                finish()
            }
        }
        ui.askResume(
            ResumeCard(
                title = fullTitle.ifBlank { intent.getStringExtra(EXTRA_TITLE).orEmpty() },
                atMs = resumeMs,
                totalMs = lastKnownDurationMs,
            ),
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
        ui.openMenu(
            PlayerMenu(
                getString(R.string.menu_picture),
                options.map { (mode, label) ->
                    MenuRow.Option(getString(label), checked = mode == current) {
                        application.asTv().session.aspectRatio = mode
                        player?.setAspectMode(mode)
                    }
                },
            ),
        )
        main.removeCallbacks(hideChrome)
    }

    /** Only offer the Audio button when there's a real choice. */
    private fun hasAltAudio(): Boolean = (player?.listAudioTracks()?.size ?: 0) > 1

    private fun openAudio() {
        showChrome()
        val tracks = player?.listAudioTracks().orEmpty()
        if (tracks.isEmpty()) return
        ui.openMenu(
            PlayerMenu(
                getString(R.string.menu_audio),
                tracks.map { (id, label, on) ->
                    MenuRow.Option(label, checked = on) { player?.selectAudioTrack(id) }
                },
            ),
        )
        main.removeCallbacks(hideChrome)
    }

    private fun openSubtitles() {
        showChrome()
        main.removeCallbacks(hideChrome)
        val app = application.asTv()
        SubtitlePicker(
            activity = this,
            ui = ui,
            player = { player },
            api = app.api,
            titleId = { titleId },
            season = { seasonNum },
            episode = { episodeNum },
            languages = { app.session.preferredLanguages },
            delayMs = { subDelayMs },
            setDelayMs = { subDelayMs = it },
        ).show()
    }

    private val clearHud = Runnable { ui.hud = null }

    /** A short notice under the top row. */
    private fun showHud(text: String) {
        ui.hud = text
        main.removeCallbacks(clearHud)
        main.postDelayed(clearHud, 1_200L)
    }

    /** "Show S01E02" → "Show" over "S01E02", like the desktop player. */
    private fun setTitleText(label: String) {
        fullTitle = label
        val code = Regex("""\s+(S\d{2,}E\d{2,})$""").find(label)
        if (code != null) {
            ui.title = label.substring(0, code.range.first)
            ui.episode = code.groupValues[1]
        } else {
            ui.title = label
            ui.episode = null
        }
    }

    override fun onPause() {
        saveWatchProgress(force = true)
        super.onPause()
    }

    override fun onStop() {
        saveWatchProgress(force = true)
        // Home / screensaver: don't keep playing behind another app. It stays
        // paused on return; before the first frame the surface callback resumes it.
        runCatching { player?.pause() }
        super.onStop()
    }

    override fun onDestroy() {
        stopped = true
        app.peanutbutter.core.AuthEvents.onPlaybackEnded()
        saveWatchProgress(force = true)
        TorrentClient.onStatsUpdated = null
        waitJob?.cancel()
        statusPollJob?.cancel()
        main.removeCallbacks(hideChrome)
        main.removeCallbacks(tickProgress)
        main.removeCallbacks(commitSeek)
        main.removeCallbacks(bufferStallRecover)
        main.removeCallbacks(showRebufferSpinner)
        main.removeCallbacks(endCountdown)
        // Also the one-off delayed lambdas (seek commits, focus, retries): this
        // handler is the player's own, so nothing else is cancelled.
        main.removeCallbacksAndMessages(null)
        val sid = sessionId
        if (localTorrent || sid?.startsWith("local-") == true) {
            // Closing the player always stops the torrent. Downloaded pieces are
            // deleted only when Settings → Clear cache on exit is on; otherwise
            // they stay on disk for a fast resume. After "Play next" the torrent
            // belongs to the new player — leave it alone.
            if (!handedOffToNext) {
                if (application.asTv().session.clearCacheOnExit) {
                    maybeWipeStreamCache()
                } else {
                    runCatching { TorrentClient.stop(this, deleteFiles = false) }
                }
            }
        }
        // Don't clear the session a newer player (Play next) already registered.
        val tvApp = application.asTv()
        if (tvApp.activeStreamSession == sid) tvApp.activeStreamSession = null
        runCatching {
            player?.stop()
            player?.release()
        }
        player = null
        super.onDestroy()
    }

    /** When Settings → Clear cache on exit is enabled, purge torrent pieces now. */
    private fun maybeWipeStreamCache() {
        val app = application.asTv()
        if (!app.session.clearCacheOnExit) return
        runCatching {
            TorrentClient.stop(this, deleteFiles = true)
            StreamDownloads.wipe(this)
        }
    }

    private data class NextEpisode(
        val season: Int,
        val episode: Int,
        val episodeId: String,
        val catalogTitle: String,
        val kind: String,
        val posterUrl: String?,
        val backdropUrl: String?,
        val fileEpisode: Int? = null,
    )

    companion object {
        private const val TAG = "PlayerActivity"
        /** Exo stuck in BUFFERING this long before the first frame → reopen. */
        private const val PRE_PLAY_REOPEN_MS = 45_000L
        private const val CHROME_HIDE_MS = 5_000L
        private const val CHROME_HIDE_AFTER_RESUME_MS = 1_500L
        private const val CHROME_HIDE_AFTER_SEEK_MS = 2_500L
        private const val REBUFFER_SPINNER_DELAY_MS = 400L
        private const val BUFFER_STALL_CHECK_MS = 20_000L
        private const val MAX_STALL_REOPENS = 2
        /** Playback must move this far before retry limits reset. */
        private const val RECOVERY_RESET_MS = 30_000L
        private const val RETRY_LOOKUP_MS = 30_000L
        private const val END_COUNTDOWN_S = 30
        private val PLAYER_KEYS = setOf(
            KeyEvent.KEYCODE_DPAD_UP, KeyEvent.KEYCODE_DPAD_DOWN, KeyEvent.KEYCODE_DPAD_LEFT,
            KeyEvent.KEYCODE_DPAD_RIGHT, KeyEvent.KEYCODE_DPAD_CENTER, KeyEvent.KEYCODE_ENTER,
            KeyEvent.KEYCODE_NUMPAD_ENTER, KeyEvent.KEYCODE_SPACE,
            KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE, KeyEvent.KEYCODE_MEDIA_PLAY, KeyEvent.KEYCODE_MEDIA_PAUSE,
            KeyEvent.KEYCODE_MEDIA_FAST_FORWARD, KeyEvent.KEYCODE_MEDIA_REWIND,
        )
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
        const val EXTRA_DURATION_MS = "duration_ms"
        const val EXTRA_LOCAL = "local_torrent"
        const val EXTRA_MAGNET = "magnet"
        const val EXTRA_FILE_INDEX = "file_index"
        const val EXTRA_FILE_EPISODE = "file_episode"
        const val EXTRA_DIRECT = "direct_stream"
        const val EXTRA_HEADER_NAMES = "header_names"
        const val EXTRA_HEADER_VALUES = "header_values"

        /**
         * What to play: a torrent (magnet, started on this device) or, when
         * [directUrl] is set, a direct link from an add-on, played as is with
         * its [headers] and no torrent or server session.
         */
        fun Intent.putStreamSource(
            magnet: String,
            directUrl: String?,
            headers: Map<String, String> = emptyMap(),
        ): Intent = if (!directUrl.isNullOrBlank()) {
            putExtra(EXTRA_URL, directUrl)
                .putExtra(EXTRA_DIRECT, true)
                .putExtra(EXTRA_LOCAL, false)
                .putExtra(EXTRA_HEADER_NAMES, headers.keys.toTypedArray())
                .putExtra(EXTRA_HEADER_VALUES, headers.values.toTypedArray())
        } else {
            putExtra(EXTRA_SESSION, "local-${System.currentTimeMillis()}")
                .putExtra(EXTRA_URL, "")
                .putExtra(EXTRA_MAGNET, magnet)
                .putExtra(EXTRA_LOCAL, true)
        }
    }
}
