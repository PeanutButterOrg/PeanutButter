package app.peanutbutter.tv.player

import android.app.AlertDialog
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.KeyEvent
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.widget.FrameLayout
import android.widget.ImageButton
import android.widget.ProgressBar
import android.widget.SeekBar
import android.widget.TextView
import android.widget.Toast
import androidx.activity.OnBackPressedCallback
import androidx.core.view.isVisible
import androidx.core.widget.doAfterTextChanged
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
import app.peanutbutter.tv.ui.showRoundListDialog
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
    private var btnSubs: View? = null
    private var btnAspect: View? = null
    private var btnAudio: View? = null
    /** Speed / peers / buffer chip above the transport (desktop player's chip). */
    private var statsChip: TextView? = null
    private var leaveDialog: AlertDialog? = null

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
    private val showRebufferSpinner = Runnable { if (streamOpened) busy?.isVisible = true }
    private val endCountdown = object : Runnable {
        override fun run() {
            if (stopped) return
            endCountdownLeft--
            if (endCountdownLeft <= 0) {
                if (!isFinishing) finish()
                return
            }
            btnNext?.text = getString(R.string.play_next_countdown, endCountdownLeft)
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
        btnNext?.setText(R.string.play_next)
        overlayActions?.bringToFront()
        btnSubs = findViewById(R.id.btn_subs)
        btnAspect = findViewById(R.id.btn_aspect)
        btnAudio = findViewById(R.id.btn_audio)
        statsChip = findViewById(R.id.stats_chip)
        // Every status update also feeds the chip shown while playing.
        statusView?.doAfterTextChanged { statsChip?.text = it }

        // Cover first — avoid black frame while torrent/player wake up.
        posterHud?.isVisible = true
        val art = intent.getStringExtra(EXTRA_BACKDROP)?.takeIf { it.isNotBlank() }
            ?: intent.getStringExtra(EXTRA_POSTER)
        if (!art.isNullOrBlank()) {
            PbGlide.playerBackdrop(findViewById(R.id.poster_art), art)
        }
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
        titleView?.text = title
        statusView?.text = getString(R.string.finding_peers)
        // Pre-play HUD: center spinner + top buffer bar while finding peers / buffering.
        busy?.isVisible = true
        topProgress?.isVisible = true
        topProgress?.progress = 0
        topProgress?.secondaryProgress = 0

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

        btnRew?.setOnClickListener { seekBy(-10_000); showChrome() }
        btnFf?.setOnClickListener { seekBy(10_000); showChrome() }
        btnPlay?.setOnClickListener { togglePlay() }
        btnSkip?.setOnClickListener { pulseAction(btnSkip) { skipActiveSegment() } }
        btnNext?.setOnClickListener { pulseAction(btnNext) { playNextEpisode() } }
        btnSubs?.setOnClickListener { pulseAction(btnSubs) { openSubtitles() } }
        btnAspect?.setOnClickListener { pulseAction(btnAspect) { openAspect() } }
        btnAudio?.setOnClickListener { pulseAction(btnAudio) { openAudio() } }
        listOfNotNull(btnSkip, btnNext).forEach { chip ->
            chip.setOnFocusChangeListener { v, hasFocus ->
                v.animate().cancel()
                v.animate()
                    .scaleX(if (hasFocus) 1.08f else 1f)
                    .scaleY(if (hasFocus) 1.08f else 1f)
                    .setDuration(120)
                    .start()
            }
        }

        // API 34+ routes Back through OnBackPressedDispatcher (not only onKeyDown).
        // Without this callback the activity finishes and skips the exit dialog.
        onBackPressedDispatcher.addCallback(this, object : OnBackPressedCallback(true) {
            override fun handleOnBackPressed() {
                handleBackPress()
            }
        })

        listOfNotNull(btnRew, btnPlay, btnFf, btnAspect, btnAudio, btnSubs, seek, btnSkip, btnNext).forEach {
            it.isFocusable = true
            it.isFocusableInTouchMode = true
        }

        seek?.max = SEEK_MAX
        // D-pad steps by time, not a share of the file (2% was 2.4 min on a long
        // film); holding the key speeds up.
        seek?.setOnKeyListener { _, code, event ->
            val sign = when (code) {
                KeyEvent.KEYCODE_DPAD_LEFT -> -1L
                KeyEvent.KEYCODE_DPAD_RIGHT -> 1L
                else -> return@setOnKeyListener false
            }
            if (event.action == KeyEvent.ACTION_DOWN) {
                val step = when {
                    event.repeatCount >= 20 -> 60_000L
                    event.repeatCount >= 8 -> 30_000L
                    else -> 10_000L
                }
                seekBy(sign * step)
            }
            true
        }
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
        AppLog.i(TAG, "startLocalTorrent season=$seasonNum episode=$episodeNum fileEpisode=$fileEpisode")
        statusView?.text = getString(R.string.finding_peers)
        busy?.isVisible = true
        topProgress?.isVisible = true
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
            statusView?.text = getString(R.string.starting_stream)
            ensurePlayer(forceExo = true)
            attachAndPlay()
            startLocalStatusPolling()
        } catch (t: Throwable) {
            AppLog.e(TAG, "startLocalTorrent failed", t)
            torrentStartFailed = true // late stats must not repaint over the error
            if (!stopped) {
                statusView?.text = t.message?.takeIf { it.isNotBlank() }
                    ?: getString(R.string.stream_start_failed)
                busy?.isVisible = false
                topProgress?.isVisible = false
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
            title = titleView?.text?.toString().orEmpty(),
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
            topProgress?.isVisible = true
            topProgress?.progress = bufPct.coerceIn(0, 100)
            topProgress?.secondaryProgress = bufPct.coerceIn(0, 100)
            applyBufferingChrome()
        } else {
            topProgress?.isVisible = false
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
        if (!streamOpened) busy?.isVisible = !userSeeking && !userPaused
        if (userPaused || streamOpened) {
            topProgress?.isVisible = false
            posterHud?.isVisible = false
        }
    }

    private fun applyStatusLine(line: String) {
        if (userSeeking || seekTargetMs >= 0) return
        statusView?.text = line
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
            if (downloadMbps >= 0.05) append(String.format("  ·  %.1f MB/s", downloadMbps))
            if (peers > 0) append("  ·  $peers peers")
            if (aheadS > 0) append("  ·  ${aheadS}s buffered")
        }
    }

    /** It keeps downloading while paused; show that it does. */
    private fun pausedLine(downloadMbps: Double, peers: Int): String = buildString {
        append("Paused")
        if (downloadMbps >= 0.05) append(String.format("  ·  %.1f MB/s", downloadMbps))
        if (peers > 0) append("  ·  $peers peers")
    }

    private fun underrunBufferLine(downloadMbps: Double): String =
        if (downloadMbps >= 0.05) {
            String.format("Buffering… · %.1f MB/s", downloadMbps)
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
            torrentReadyLatched = true
            mediaAttached = false
            streamOpened = false
            Log.i(TAG, "stream playable url=${app.peanutbutter.core.AppLog.safeUrl(pendingUrl).take(140)}")
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
                    if (!mediaAttached && tick.streamUrl.isNotBlank()) {
                        val next = api.playableStreamUrl(tick.streamUrl)
                        if (next != pendingUrl) {
                            pendingUrl = next
                            torrentReadyLatched = true
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
                            topProgress?.isVisible = true
                            topProgress?.progress = buf
                            topProgress?.secondaryProgress = buf
                        }
                        busy?.isVisible = true
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
                        topProgress?.isVisible = false
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
                    topProgress?.progress = 100
                    topProgress?.secondaryProgress = 100
                    topProgress?.isVisible = false
                    posterHud?.isVisible = false
                    renderTransport()
                    if (firstOpen) {
                        // Clean start: hide transport; Skip/Next may appear on their own layer.
                        // Only here: this also fires after every pause, seek and rebuffer,
                        // where it closed the controls and took focus from the user.
                        busy?.isVisible = false
                        chromeVisible = false
                        applyPlayingChrome(showTransport = false)
                        findViewById<View>(R.id.player_root)?.requestFocus()
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
                    if (!userSeeking) statusView?.text = "Paused"
                    renderTransport()
                    // User pause ≠ underrun buffering — show full transport chrome.
                    topProgress?.isVisible = false
                    applyPlayingChrome(showTransport = true)
                    showChrome()
                    val focus = currentFocus
                    if (focus == null || focus.id == R.id.player_root) btnPlay?.requestFocus()
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
                        statusView?.text = "Retrying with FFmpeg…"
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
                        statusView?.text = if (mbps > 0.05) {
                            String.format("Buffering… · %.1f MB/s", mbps)
                        } else {
                            "Buffering…"
                        }
                        busy?.isVisible = true
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
                    statusView?.text = getString(R.string.playback_error)
                    busy?.isVisible = false
                    showChrome()
                    renderTransport()
                    btnPlay?.requestFocus()
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
                    main.post { timeDur?.text = formatMs(durationMs) }
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
            statusView?.text = "Reconnecting…"
            busy?.isVisible = true
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
            statusView?.text = getString(R.string.playback_error)
            busy?.isVisible = false
            saveWatchProgress(force = true)
            showChrome()
            return
        }
        statusView?.text = "Ended"
        saveWatchProgress(force = true, complete = true)
        if (stopped || isFinishing) return
        // Same as desktop / phone: offer the next episode for 30 s, then leave.
        if (nextEpisode != null) {
            endCountdownLeft = END_COUNTDOWN_S
            btnNext?.text = getString(R.string.play_next_countdown, endCountdownLeft)
            showPlayNext(true)
            btnNext?.requestFocus()
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
        btnNext?.setText(R.string.play_next)
    }

    /**
     * Play / pause icon, paused flag and rebuffer spinner, all from the player's
     * own state. Icons used to be set by hand in a few callbacks and drifted.
     */
    private fun renderTransport() {
        val mp = player ?: return
        val showPlay = !mp.wantsToPlay || mp.needsRestart
        btnPlay?.setImageResource(if (showPlay) R.drawable.ic_play_arrow else R.drawable.ic_pause)
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
            busy?.isVisible = false
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
            statusView?.text = getString(R.string.starting_stream)
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
            statusView?.text = e.message ?: getString(R.string.playback_error)
            busy?.isVisible = false
            mediaAttached = false
            mediaAttachAtMs = 0L
        }
    }

    private fun queueSeek(targetMs: Long, settleMs: Long) {
        seekTargetMs = targetMs.coerceAtLeast(0)
        userSeeking = true
        seekToken++
        val token = seekToken
        statusView?.text = "Seeking ${formatMs(seekTargetMs)}…"
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
            statusView?.text = "Buffering at ${formatMs(target)}…"
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
        val today = java.time.LocalDate.now().toString()
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
        val wasSkip = btnSkip?.isVisible == true
        if (showSkip) {
            btnSkip?.text = opening?.label?.ifBlank { null } ?: getString(R.string.skip_intro)
            // Don't take focus from someone using the controls.
            revealActionChip(btnSkip, focusIfNew = !wasSkip && !chromeVisible)
        } else if (wasSkip && currentFocus === btnSkip) {
            btnSkip?.isVisible = false
            findViewById<View>(R.id.player_root)?.requestFocus()
        } else {
            btnSkip?.isVisible = false
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
        updateOverlayFocusChain()
        placeSkipButtons(chromeVisible)
    }

    private fun showPlayNext(show: Boolean) {
        if (!show) {
            if (playNextVisible && currentFocus === btnNext) {
                findViewById<View>(R.id.player_root)?.requestFocus()
            }
            playNextVisible = false
            btnNext?.isVisible = false
            updateOverlayFocusChain()
            return
        }
        val was = playNextVisible
        playNextVisible = true
        // Own layer — do not dump the whole transport chrome.
        revealActionChip(btnNext, focusIfNew = !was && !chromeVisible)
        updateOverlayFocusChain()
    }

    /** Fade + scale in an action chip; optionally take focus without showing transport. */
    private fun revealActionChip(chip: TextView?, focusIfNew: Boolean) {
        val view = chip ?: return
        overlayActions?.bringToFront()
        overlayActions?.alpha = 1f
        if (!view.isVisible) {
            view.alpha = 0f
            view.scaleX = 0.92f
            view.scaleY = 0.92f
            view.isVisible = true
            view.animate()
                .alpha(1f)
                .scaleX(1f)
                .scaleY(1f)
                .setDuration(180)
                .start()
        } else {
            view.alpha = 1f
            view.scaleX = 1f
            view.scaleY = 1f
        }
        if (focusIfNew) {
            view.post { view.requestFocus() }
        }
    }

    /** Press feedback shared by Skip / Next / Aspect / Subs. */
    private fun pulseAction(view: View?, then: () -> Unit) {
        val v = view ?: run { then(); return }
        v.isPressed = true
        v.animate().cancel()
        v.animate()
            .scaleX(0.94f)
            .scaleY(0.94f)
            .setDuration(70)
            .withEndAction {
                v.animate()
                    .scaleX(1f)
                    .scaleY(1f)
                    .setDuration(110)
                    .withEndAction {
                        v.isPressed = false
                        then()
                        // Restore focus only if the chip is still on screen (Skip hides itself).
                        if (v.isShown && v.isFocusable) v.requestFocus()
                    }
                    .start()
            }
            .start()
    }

    /** Keep Skip / Play Next reachable from the transport row after focus leaves. */
    private fun updateOverlayFocusChain() {
        val skipVisible = btnSkip?.isVisible == true
        val nextVisible = btnNext?.isVisible == true
        val actionId = when {
            skipVisible -> R.id.btn_skip
            nextVisible -> R.id.btn_next
            else -> View.NO_ID
        }
        btnPlay?.nextFocusUpId = if (actionId != View.NO_ID) actionId else R.id.seek
        btnRew?.nextFocusUpId = if (actionId != View.NO_ID) actionId else R.id.seek
        btnFf?.nextFocusUpId = if (actionId != View.NO_ID) actionId else R.id.seek
        // Skip / Next sit bottom-left: reached by Left from the transport.
        btnFf?.nextFocusRightId = View.NO_ID
        btnRew?.nextFocusLeftId = if (actionId != View.NO_ID) actionId else View.NO_ID
        seek?.nextFocusUpId = when {
            skipVisible -> R.id.btn_skip
            nextVisible -> R.id.btn_next
            else -> R.id.btn_subs
        }
        if (skipVisible) {
            btnSkip?.nextFocusDownId = if (chromeVisible) R.id.seek else View.NO_ID
            btnSkip?.nextFocusRightId = if (chromeVisible) R.id.btn_rew else View.NO_ID
            btnSkip?.nextFocusUpId = if (chromeVisible) R.id.btn_subs else View.NO_ID
            btnSkip?.nextFocusLeftId = View.NO_ID
        }
        if (nextVisible) {
            btnNext?.nextFocusDownId = if (chromeVisible) R.id.seek else View.NO_ID
            btnNext?.nextFocusRightId = if (chromeVisible) R.id.btn_rew else View.NO_ID
            btnNext?.nextFocusUpId = if (skipVisible) R.id.btn_skip else {
                if (chromeVisible) R.id.btn_subs else View.NO_ID
            }
            btnNext?.nextFocusLeftId = View.NO_ID
        }
    }

    private fun raiseSkipButtons() {
        overlayActions?.bringToFront()
    }

    private fun placeSkipButtons(chromeUp: Boolean) {
        val overlay = overlayActions ?: return
        val lp = overlay.layoutParams as? FrameLayout.LayoutParams ?: return
        val d = resources.displayMetrics.density
        // Bottom-left like the desktop player; above the transport when it's up.
        lp.gravity = android.view.Gravity.BOTTOM or android.view.Gravity.START
        lp.bottomMargin = ((if (chromeUp) 176 else 48) * d).toInt()
        lp.marginStart = (48 * d).toInt()
        lp.marginEnd = 0
        overlay.layoutParams = lp
        overlay.bringToFront()
        overlay.alpha = 1f
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
        statusView?.text = getString(R.string.looking_up_sources)
        // Finding a source takes a while: stop the old episode and say what's happening.
        val wasPlaying = player?.wantsToPlay == true
        runCatching { player?.pause() }
        val loading = findViewById<View>(R.id.next_loading)
        findViewById<TextView>(R.id.next_loading_label).text =
            String.format("%s · S%02dE%02d", next.catalogTitle, next.season, next.episode)
        loading.isVisible = true
        loading.bringToFront()
        lifecycleScope.launch {
            try {
                saveWatchProgress(force = true, complete = true)
                // Drop previous episode pieces when clear-cache-on-exit is enabled.
                maybeWipeStreamCache()
                val api = application.asTv().api
                val label = String.format("%s S%02dE%02d", next.catalogTitle, next.season, next.episode)
                val searchEp = next.fileEpisode ?: next.episode
                val query = String.format("%s S%02dE%02d", next.catalogTitle, next.season, searchEp)
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
                    loading.isVisible = false
                    if (wasPlaying) {
                        // Still watching this episode, so keep saving its position.
                        markedComplete = false
                        runCatching { player?.play() }
                    }
                    if (btnNext?.isVisible == true) btnNext?.requestFocus()
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
        btnSkip?.isVisible = false
        findViewById<View>(R.id.player_root)?.requestFocus()
        updateOverlayFocusChain()
        statusView?.text = getString(R.string.skip_intro)
        chromeTop?.isVisible = true
        chromeTop?.alpha = 1f
        main.postDelayed({
            if (!chromeVisible && streamOpened && !userPaused) {
                chromeTop?.animate()?.alpha(0f)?.setDuration(220)?.start()
            }
        }, 1_200L)
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
            seek?.progress = ((target.toDouble() / len) * SEEK_MAX).toInt().coerceIn(0, SEEK_MAX)
        }
        timePos?.text = formatMs(target)
        queueSeek(target, settleMs = if (isStream) 700L else 50L)
        // Scrubbing shows transport; Skip-driven seeks do not (they call queueSeek directly).
        if (currentFocus !== btnSkip && currentFocus !== btnNext) {
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
        if (chromeVisible) btnSubs?.isSelected = mp.selectedTextTrackId != null
        if (len > 0) {
            seek?.progress = ((pos.toDouble() / len) * SEEK_MAX).toInt().coerceIn(0, SEEK_MAX)
            // Lighter track = what's ready to play: the player's own buffer (at most
            // a minute) or, usually further, what the torrent has without gaps.
            val buffered = maxOf(mp.bufferedPositionMs, (torrentDownloadedTo * len).toLong())
                .coerceIn(pos, len)
            seek?.secondaryProgress = ((buffered.toDouble() / len) * SEEK_MAX).toInt().coerceIn(0, SEEK_MAX)
            timeDur?.text = formatMs(len)
        } else {
            timeDur?.text = "--:--"
        }
        timePos?.text = formatMs(pos)
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
        val titleText = titleView?.text?.toString()
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
        return if (h > 0) String.format("%d:%02d:%02d", h, m, s)
        else String.format("%d:%02d", m, s)
    }

    private fun showChrome() {
        chromeTop?.animate()?.cancel()
        chromeBottom?.animate()?.cancel()
        if (!streamOpened) {
            // Pre-play only: title + buffer status (no transport).
            chromeVisible = true
            applyBufferingChrome()
            main.removeCallbacks(hideChrome)
            placeSkipButtons(false)
            syncSubtitlePad()
            return
        }
        // Already showing — only refresh the auto-hide timer. Re-running the
        // fade-in (alpha 0→1) on every D-pad press made the bar blink.
        if (chromeVisible &&
            chromeBottom?.isVisible == true &&
            (chromeBottom?.alpha ?: 0f) > 0.85f
        ) {
            scheduleHideChrome()
            placeSkipButtons(true)
            updateOverlayFocusChain()
            syncSubtitlePad()
            return
        }
        chromeVisible = true
        applyPlayingChrome(showTransport = true)
        placeSkipButtons(true)
        updateOverlayFocusChain()
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
        chromeTop?.isVisible = true
        chromeTop?.alpha = 1f
        btnAspect?.isVisible = false
        btnSubs?.isVisible = false
        btnAudio?.isVisible = false
        chromeBottom?.isVisible = false
        topProgress?.isVisible = true
        posterHud?.isVisible = true
        main.removeCallbacks(hideChrome)
        syncActionChipVisibility()
    }

    private fun applyPlayingChrome(showTransport: Boolean) {
        posterHud?.isVisible = false
        topProgress?.isVisible = false
        chromeTop?.animate()?.cancel()
        chromeBottom?.animate()?.cancel()
        if (showTransport) {
            chromeVisible = true
            chromeTop?.isVisible = true
            chromeBottom?.isVisible = true
            btnAspect?.isVisible = true
            btnSubs?.isVisible = true
            btnAudio?.isVisible = hasAltAudio()
            // Only fade in when coming from hidden — never reset alpha to 0 first.
            val topA = chromeTop?.alpha ?: 0f
            val botA = chromeBottom?.alpha ?: 0f
            if (topA < 0.95f) {
                chromeTop?.animate()?.alpha(1f)?.setDuration(180)?.start()
            } else {
                chromeTop?.alpha = 1f
            }
            if (botA < 0.95f) {
                chromeBottom?.animate()?.alpha(1f)?.setDuration(180)?.start()
            } else {
                chromeBottom?.alpha = 1f
            }
        } else {
            chromeVisible = false
            chromeTop?.animate()?.alpha(0f)?.setDuration(220)?.start()
            chromeBottom?.animate()?.alpha(0f)?.setDuration(220)?.withEndAction {
                if (!chromeVisible) chromeBottom?.isVisible = false
            }?.start()
            btnAspect?.isVisible = false
            btnSubs?.isVisible = false
            btnAudio?.isVisible = false
        }
        syncActionChipVisibility()
        syncSubtitlePad()
    }

    private fun syncActionChipVisibility() {
        // Title only on top once playing; live status moves to the chip.
        statusView?.isVisible = !streamOpened
        statsChip?.isVisible = streamOpened && isStream && chromeVisible &&
            !statsChip?.text.isNullOrBlank()
        overlayActions?.bringToFront()
        overlayActions?.alpha = 1f
        if (btnSkip?.isVisible == true) btnSkip?.alpha = 1f
        if (btnNext?.isVisible == true) btnNext?.alpha = 1f
        placeSkipButtons(chromeVisible && !isBufferingUi())
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
            // Keep focus on Skip/Next if they're up; otherwise clear to root.
            when {
                btnSkip?.isVisible == true && (currentFocus === btnSkip || currentFocus === btnNext) ->
                    btnSkip?.requestFocus()
                btnNext?.isVisible == true && currentFocus === btnNext ->
                    btnNext?.requestFocus()
                // Back to the chip, so OK skips as it did before the controls opened.
                btnSkip?.isVisible == true -> btnSkip?.requestFocus()
                btnNext?.isVisible == true -> btnNext?.requestFocus()
                else -> findViewById<View>(R.id.player_root)?.requestFocus()
            }
            updateOverlayFocusChain()
        } else if (visible) {
            showChrome()
        }
    }

    private fun overlaysVisible(): Boolean {
        if (leaveDialog?.isShowing == true) return false
        // Pre-play / buffering chrome is not dismissible via Back — Back exits.
        if (isBufferingUi()) return false
        if (chromeVisible) return true
        if ((chromeTop?.alpha ?: 0f) > 0.2f && (btnAspect?.isVisible == true || btnSubs?.isVisible == true)) {
            return true
        }
        if ((chromeBottom?.alpha ?: 0f) > 0.2f && chromeBottom?.isVisible == true) return true
        // Skip/Next alone count as an overlay so Back can dismiss focus cleanly.
        if (btnSkip?.isVisible == true || btnNext?.isVisible == true) {
            if (currentFocus === btnSkip || currentFocus === btnNext) return true
        }
        return false
    }

    private fun hidePlayerUi() {
        if (isBufferingUi()) {
            applyBufferingChrome()
            return
        }
        // If focus is on Skip/Next, first Back clears focus but keeps the chip.
        if (currentFocus === btnSkip || currentFocus === btnNext) {
            findViewById<View>(R.id.player_root)?.requestFocus()
            if (!chromeVisible) return
        }
        setChrome(false)
        main.removeCallbacks(hideChrome)
        findViewById<View>(R.id.player_root)?.requestFocus()
    }

    private fun scheduleHideChrome() {
        main.removeCallbacks(hideChrome)
        // Not while a menu is open or the player is paused: the controls stay up.
        if (streamOpened && !userSeeking && !userPaused && chromeVisible && hasWindowFocus()) {
            main.postDelayed(hideChrome, hideDelayMs)
        }
    }

    /** Shared by onKeyDown + OnBackPressedDispatcher — never finishes unless user confirms Leave. */
    private fun handleBackPress() {
        if (leaveDialog?.isShowing == true) {
            leaveDialog?.dismiss()
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
        // Before playback only the controls are dead; volume keys must still work.
        if (!streamOpened && event.keyCode in PLAYER_KEYS) return true
        if (event.action == KeyEvent.ACTION_DOWN && chromeVisible) {
            hideDelayMs = CHROME_HIDE_MS
            scheduleHideChrome()
        }
        return super.dispatchKeyEvent(event)
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean {
        // Handle Back before showChrome() — otherwise the second Back re-shows
        // chrome and never reaches the exit dialog.
        if (keyCode == KeyEvent.KEYCODE_BACK || keyCode == KeyEvent.KEYCODE_ESCAPE) {
            if ((event?.repeatCount ?: 0) == 0) handleBackPress()
            return true
        }
        if (!streamOpened) return super.onKeyDown(keyCode, event)

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
                if (firstPress && btnNext?.isVisible == true) playNextEpisode()
                return true
            }
        }

        val focus = currentFocus
        val onActionChip = focus === btnSkip || focus === btnNext
        val onTransport = focus === btnPlay || focus === btnRew || focus === btnFf ||
            focus === btnAspect || focus === btnAudio || focus === btnSubs || focus === seek

        // Skip / Next are their own layer — never force the full transport bar.
        if (onActionChip) {
            scheduleHideChrome()
            // The chips sit bottom-left: Right goes to the transport.
            if (keyCode == KeyEvent.KEYCODE_DPAD_RIGHT || keyCode == KeyEvent.KEYCODE_DPAD_DOWN ||
                keyCode == KeyEvent.KEYCODE_DPAD_LEFT
            ) {
                if (chromeVisible) {
                    when (keyCode) {
                        KeyEvent.KEYCODE_DPAD_RIGHT -> btnRew?.requestFocus()
                        KeyEvent.KEYCODE_DPAD_DOWN -> seek?.requestFocus()
                    }
                    return true
                }
                // Controls hidden: open them. This used to do nothing, so during an
                // intro or the credits the controls could not be reached at all.
                showChrome()
                btnPlay?.requestFocus()
                return true
            }
            return super.onKeyDown(keyCode, event)
        }

        // OK / Enter always toggles playback and reveals chrome (even over soft buttons).
        if (keyCode == KeyEvent.KEYCODE_DPAD_CENTER || keyCode == KeyEvent.KEYCODE_ENTER ||
            keyCode == KeyEvent.KEYCODE_NUMPAD_ENTER || keyCode == KeyEvent.KEYCODE_SPACE
        ) {
            if (firstPress) togglePlay()
            showChrome()
            btnPlay?.requestFocus()
            return true
        }

        if (onTransport && keyCode in listOf(
                KeyEvent.KEYCODE_DPAD_LEFT, KeyEvent.KEYCODE_DPAD_RIGHT,
                KeyEvent.KEYCODE_DPAD_UP, KeyEvent.KEYCODE_DPAD_DOWN,
            )
        ) {
            showChrome()
            // Skip / Play Next sit bottom-left: Up from the transport, or Left
            // from Rewind, reaches them.
            val toChip = (keyCode == KeyEvent.KEYCODE_DPAD_UP &&
                (focus === btnPlay || focus === btnRew || focus === btnFf || focus === seek)) ||
                (keyCode == KeyEvent.KEYCODE_DPAD_LEFT && focus === btnRew)
            if (toChip) {
                when {
                    btnSkip?.isVisible == true -> {
                        btnSkip?.requestFocus()
                        return true
                    }
                    btnNext?.isVisible == true && keyCode == KeyEvent.KEYCODE_DPAD_LEFT -> {
                        btnNext?.requestFocus()
                        return true
                    }
                    btnNext?.isVisible == true && focus !== seek -> {
                        btnNext?.requestFocus()
                        return true
                    }
                }
            }
            return super.onKeyDown(keyCode, event)
        }

        when (keyCode) {
            KeyEvent.KEYCODE_DPAD_UP -> {
                // Always surface chrome first (especially when paused with UI hidden).
                showChrome()
                when {
                    btnSkip?.isVisible == true -> {
                        btnSkip?.requestFocus()
                        return true
                    }
                    btnNext?.isVisible == true -> {
                        btnNext?.requestFocus()
                        return true
                    }
                    else -> {
                        btnPlay?.requestFocus()
                        return true
                    }
                }
            }
            KeyEvent.KEYCODE_DPAD_RIGHT -> {
                // A quick seek with the controls hidden only shows them briefly.
                hideDelayMs = CHROME_HIDE_AFTER_SEEK_MS
                seekBy(10_000)
                return true
            }
            KeyEvent.KEYCODE_DPAD_LEFT -> {
                hideDelayMs = CHROME_HIDE_AFTER_SEEK_MS
                seekBy(-10_000)
                return true
            }
            KeyEvent.KEYCODE_DPAD_DOWN -> {
                showChrome()
                btnPlay?.requestFocus()
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
        showRoundListDialog(
            activity = this,
            title = getString(R.string.aspect_title),
            options = options.map { getString(it.second) },
            checked = options.indexOfFirst { it.first == current },
        ) { which ->
            val mode = options[which].first
            application.asTv().session.aspectRatio = mode
            player?.setAspectMode(mode)
        }
    }

    /** Only offer the Audio chip when there's a real choice. */
    private fun hasAltAudio(): Boolean = (player?.listAudioTracks()?.size ?: 0) > 1

    private fun openAudio() {
        showChrome()
        val tracks = player?.listAudioTracks().orEmpty()
        if (tracks.isEmpty()) return
        showRoundListDialog(
            activity = this,
            title = getString(R.string.audio_title),
            options = tracks.map { it.second },
            checked = tracks.indexOfFirst { it.third },
        ) { which -> player?.selectAudioTrack(tracks[which].first) }
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

    override fun onStop() {
        saveWatchProgress(force = true)
        // Home / screensaver: don't keep playing behind another app. It stays
        // paused on return; before the first frame the surface callback resumes it.
        runCatching { player?.pause() }
        super.onStop()
    }

    override fun onDestroy() {
        leaveDialog?.dismiss()
        leaveDialog = null
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
        } else if (!sid.isNullOrBlank()) {
            val api = application.asTv().api
            Thread {
                runCatching { kotlinx.coroutines.runBlocking { api.stopStream(sid) } }
            }.start()
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
        private const val SEEK_MAX = 1000
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
