package app.peanutbutter.core

import android.content.Context
import android.util.Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import org.libtorrent4j.AlertListener
import org.libtorrent4j.AnnounceEntry
import org.libtorrent4j.Priority
import org.libtorrent4j.SessionManager
import org.libtorrent4j.SettingsPack
import org.libtorrent4j.swig.settings_pack
import org.libtorrent4j.TorrentHandle
import org.libtorrent4j.TorrentInfo
import org.libtorrent4j.alerts.AddTorrentAlert
import org.libtorrent4j.alerts.Alert
import org.libtorrent4j.alerts.AlertType
import org.libtorrent4j.alerts.MetadataReceivedAlert
import org.libtorrent4j.alerts.TorrentRemovedAlert
import org.libtorrent4j.LibTorrent
import org.libtorrent4j.Sha1Hash
import org.libtorrent4j.TorrentFlags
import org.libtorrent4j.swig.session_handle
import org.libtorrent4j.swig.torrent_flags_t
import java.io.File
import java.net.URLEncoder
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

/**
 * On-device libtorrent streaming (Flutter LocalTorrentEngine parity).
 * Server only supplies magnets — pieces never land on Zima.
 */
object LocalTorrentEngine {
    private const val TAG = "LocalTorrent"
    /** Seconds of video kept downloading ahead of the player's read position. */
    private const val READAHEAD_SECONDS = 90.0
    /** Fallback when the server hasn't sent its live list (serverInfo.streamTrackers). */
    private val publicTrackers = listOf(
        "udp://tracker.opentrackr.org:1337/announce",
        "udp://open.demonii.com:1337/announce",
        "udp://open.stealth.si:80/announce",
        "udp://tracker.torrent.eu.org:451/announce",
        "udp://exodus.desync.com:6969/announce",
        "udp://explodie.org:6969/announce",
        "udp://tracker.theoks.net:6969/announce",
        "udp://tracker.dler.org:6969/announce",
        "udp://bt1.archive.org:6969/announce",
        "udp://bt2.archive.org:6969/announce",
        "http://tracker.opentrackr.org:1337/announce",
    )

    @Volatile private var ready = false
    @Volatile private var nativeUnavailable = false
    @Volatile private var saveDir: File? = null
    private var session: SessionManager? = null
    private val handleRef = AtomicReference<TorrentHandle?>(null)
    private val infoHashRef = AtomicReference<Sha1Hash?>(null)
    private val fileIndexRef = AtomicReference<Int?>(null)
    private val videoFileRef = AtomicReference<File?>(null)
    private val httpServer = AtomicReference<StreamHttpServer?>(null)
    private val metadataLatch = AtomicBoolean(false)
    @Volatile private var lastSoftPiece: Int = -1
    /** Smoothed UI buffer % so large pieces don't leap. */
    @Volatile private var smoothedBufferPct: Double = 0.0
    /** Once the local HTTP stream is open, UI buffer is complete (100%). */
    @Volatile private var streamReadyLatched: Boolean = false

    @Volatile private var extraTrackers: List<String> = emptyList()

    /** Bytes per second of the playing file (size / duration), 0 when unknown. */
    @Volatile private var bytesPerSec: Double = 0.0
    @Volatile private var streamPieceLength: Long = 0
    @Volatile private var streamFirstPiece = 0
    @Volatile private var streamLastPiece = -1
    @Volatile private var readaheadFrom = -1

    val isSupported: Boolean get() = !nativeUnavailable
    val isActive: Boolean get() = handleRef.get()?.isValid == true

    /** Optional Jackett-harvested announce URLs (kept for ApiClient compat). */
    fun setExtraTrackers(trackers: List<String>) {
        extraTrackers = trackers
            .map { it.trim() }
            .filter { it.isNotEmpty() }
            .distinct()
            .take(40)
    }

    @Synchronized
    fun ensureInit(context: Context) {
        if (ready || nativeUnavailable) return
        try {
            // Load JNI deps explicitly — UnsatisfiedLinkError is an Error, not Exception.
            runCatching { System.loadLibrary("c++_shared") }
            runCatching { System.loadLibrary("torrent4j") }
            Log.i(TAG, "libtorrent ${LibTorrent.version()} / ${LibTorrent.libtorrent4jVersion()}")
            AppLog.i(TAG, "libtorrent ${LibTorrent.version()} / ${LibTorrent.libtorrent4jVersion()}")
            val dir = File(context.applicationContext.filesDir, "pb-streams")
            if (!dir.exists()) dir.mkdirs()
            saveDir = dir
            val sm = SessionManager()
            val pack = SettingsPack()
            // DHT/LSD run in the isolated :torrent process — UI survives a native crash.
            // Keeping them off made swarms tiny and downloads crawl.
            pack.setEnableDht(true)
            // Several routers so a cold DHT (every app start) bootstraps fast;
            // libtorrent's default is a single node.
            pack.setDhtBootstrapNodes(
                "dht.libtorrent.org:25401,router.bittorrent.com:6881," +
                    "router.utorrent.com:6881,dht.transmissionbt.com:6881",
            )
            pack.setEnableLsd(true)
            pack.connectionsLimit(200)
            pack.activeDownloads(8)
            pack.activeSeeds(4)
            pack.activeLimit(12)
            pack.downloadRateLimit(0)
            pack.uploadRateLimit(0)
            pack.listenInterfaces("0.0.0.0:0")
            pack.maxPeerlistSize(4_000)
            applyStreamingTuning(pack)
            sm.start()
            sm.applySettings(pack)
            sm.maxConnections(200)
            sm.downloadRateLimit(0)
            sm.uploadRateLimit(0)
            runCatching { sm.startDht() }
            sm.addListener(object : AlertListener {
                override fun types(): IntArray = intArrayOf(
                    AlertType.ADD_TORRENT.swig(),
                    AlertType.METADATA_RECEIVED.swig(),
                    AlertType.TORRENT_REMOVED.swig(),
                )

                override fun alert(alert: Alert<*>) {
                    try {
                        when (alert.type()) {
                            AlertType.ADD_TORRENT -> {
                                val h = (alert as AddTorrentAlert).handle()
                                if (h != null && h.isValid) {
                                    handleRef.set(h)
                                    runCatching { infoHashRef.set(h.infoHash()) }
                                }
                                AppLog.i(TAG, "ADD_TORRENT")
                            }
                            AlertType.METADATA_RECEIVED -> {
                                // Only flip the latch + stash info-hash. Do not poke the
                                // alert handle further — remap makes it crash-prone on ARM.
                                metadataLatch.set(true)
                                runCatching {
                                    val h = (alert as MetadataReceivedAlert).handle()
                                    if (h != null && h.isValid) {
                                        runCatching { infoHashRef.set(h.infoHash()) }
                                    }
                                }
                                AppLog.i(TAG, "METADATA_RECEIVED")
                            }
                            AlertType.TORRENT_REMOVED -> {
                                AppLog.i(TAG, "TORRENT_REMOVED")
                                handleRef.set(null)
                            }
                            else -> Unit
                        }
                    } catch (t: Throwable) {
                        AppLog.e(TAG, "alert handler", t)
                    }
                }
            })
            session = sm
            ready = true
            Log.i(TAG, "libtorrent session started save=$dir")
            AppLog.i(TAG, "libtorrent session started save=$dir (dht=on lsd=on connections=200)")
        } catch (t: Throwable) {
            nativeUnavailable = true
            Log.e(TAG, "libtorrent unavailable", t)
            AppLog.e(TAG, "libtorrent unavailable", t)
        }
    }

    suspend fun start(
        context: Context,
        magnet: String,
        season: Int? = null,
        episode: Int? = null,
        fileIndex: Int? = null,
        resumeMs: Long = 0L,
        durationMs: Long = 0L,
        onStats: ((LocalStreamStats) -> Unit)? = null,
    ): LocalStreamHandle = withContext(Dispatchers.IO) {
        ensureInit(context)
        if (!ready) {
            throw IllegalStateException(
                "On-device torrent streaming isn’t available on this device " +
                    "(native libtorrent missing for this CPU). Use an arm64/x86_64 build or device.",
            )
        }
        AppLog.i(TAG, "start magnet=${magnet.take(64)}… fileIndex=$fileIndex resumeMs=$resumeMs")
        // Keep previous pieces on disk — wipe only via clear-cache-on-exit.
        stop(deleteFiles = false)
        val sm = session ?: throw IllegalStateException("Torrent session not ready")
        val dir = saveDir ?: throw IllegalStateException("Save path missing")
        if (!dir.exists()) dir.mkdirs()

        metadataLatch.set(false)
        // Keep magnet lean — stuffing dozens of trackers has crashed native on ARM TV.
        val magnetUri = slimMagnet(magnet.trim())
        AppLog.i(TAG, "download() len=${magnetUri.length}")
        try {
            sm.download(magnetUri, dir, torrent_flags_t())
        } catch (t: Throwable) {
            AppLog.e(TAG, "download() threw", t)
            throw t
        }
        AppLog.i(TAG, "download() returned — waiting metadata")

        val metaOk = withTimeoutOrNull(180_000L) {
            // CRITICAL: do not call torrentFile()/status() on the magnet handle
            // before metadata — that native path crashes armeabi-v7a BeyondTV.
            while (!metadataLatch.get()) {
                onStats?.invoke(LocalStreamStats.empty().copy(peers = 0, seeders = 0))
                delay(500)
            }
            true
        } == true
        AppLog.i(TAG, "metadata ok=$metaOk")
        if (!metaOk) {
            stop(deleteFiles = false)
            throw IllegalStateException("Couldn’t find enough peers to start this stream. Try another result.")
        }

        // SessionManager remaps magnet→torrent after metadata; alert handles go stale.
        // Give the native remap a moment before touching the handle again.
        delay(1_200)
        val handle = liveHandle(sm)
            ?: run {
                AppLog.e(TAG, "live handle missing after metadata")
                stop(deleteFiles = false)
                throw IllegalStateException("Couldn’t start this stream. Try another result.")
            }
        AppLog.i(TAG, "live handle ok hash=${infoHashRef.get()}")

        // Skip forceReannounce — it has crashed native right after metadata on ARM TVs.
        runCatching { injectTrackers(handle) }.onFailure {
            AppLog.e(TAG, "injectTrackers failed", it)
        }

        val info = runCatching { handle.torrentFile() }.getOrNull()
            ?: run {
                AppLog.e(TAG, "torrentFile() null after metadata")
                stop(deleteFiles = false)
                throw IllegalStateException("Couldn’t start this stream. Try another result.")
            }
        AppLog.i(TAG, "torrent info files=${info.numFiles()} pieceLength=${info.pieceLength()}")
        val chosen = fileIndex?.takeIf { it in 0 until info.numFiles() }
            ?: pickFile(info, season, episode)
            ?: run {
                stop(deleteFiles = false)
                throw IllegalStateException("This source doesn’t contain a playable video file. Try another result.")
            }
        fileIndexRef.set(chosen)
        AppLog.i(TAG, "chosen file index=$chosen name=${runCatching { info.files().fileName(chosen) }.getOrNull()}")

        runCatching {
            val priorities = Priority.array(Priority.IGNORE, info.numFiles())
            priorities[chosen] = Priority.TOP_PRIORITY
            handle.prioritizeFiles(priorities)
        }.onFailure { AppLog.e(TAG, "prioritizeFiles failed", it) }
        // Deadlines (not sequential_download) drive streaming — sequential fights
        // playhead seeks and fills 0→resume (libtorrent streaming docs).
        runCatching { handle.unsetFlags(TorrentFlags.SEQUENTIAL_DOWNLOAD) }
        runCatching { handle.resume() }

        val fs = info.files()
        val fileSize = fs.fileSize(chosen)
        val pieceLength = info.pieceLength().coerceAtLeast(1)
        val firstPiece = (fs.fileOffset(chosen) / pieceLength).toInt()
        val lastPiece = ((fs.fileOffset(chosen) + fileSize - 1) / pieceLength).toInt()
        streamPieceLength = pieceLength.toLong()
        streamFirstPiece = firstPiece
        streamLastPiece = lastPiece
        readaheadFrom = -1
        noteDuration(fileSize, durationMs)

        // Resume/seek: aim the swarm at the playhead — never fill 0→resume.
        val wantResume = resumeMs > 2_000L
        val resumeRatio = if (wantResume) {
            if (durationMs > 0L) {
                (resumeMs.toDouble() / durationMs).coerceIn(0.0, 0.98)
            } else {
                // Prefer duration when known; else assume ~2.5 Mbps (1080p WEBRip).
                val assumedBps = 2_500_000.0
                ((resumeMs / 1000.0) * assumedBps / fileSize).coerceIn(0.0, 0.98)
            }
        } else {
            0.0
        }
        val playPiece = if (wantResume) {
            ((fs.fileOffset(chosen) + (fileSize * resumeRatio).toLong()) / pieceLength)
                .toInt()
                .coerceIn(firstPiece, lastPiece)
        } else {
            firstPiece
        }
        lastSoftPiece = playPiece

        // Container head the player reads first: an MP4 "faststart" index (moov)
        // is several MB on a long film, so 1 MB on resume left the player
        // waiting on skipped pieces before it could seek.
        val headBytes = if (isMp4(fs.fileName(chosen))) 8L * 1024 * 1024 else 4L * 1024 * 1024
        val headKeep = (headBytes / pieceLength).toInt().coerceIn(1, 16)
        for (i in 0 until headKeep.coerceAtMost(lastPiece - firstPiece + 1)) {
            val p = firstPiece + i
            runCatching {
                handle.setPieceDeadline(p, 4 + i * 8)
                handle.piecePriority(p, Priority.TOP_PRIORITY)
            }
        }

        // Deep window ahead of the playhead, deadlines spread by when each
        // piece will be needed (see readaheadAt).
        val playWindow = windowPieces(pieceLength.toLong())
        // Demote the far future so deadlines win, but keep pieces wanted (LOW —
        // not IGNORE) so st.progress() isn't "100%" after the window fills.
        // One array call: a per-piece call re-sorts the picker thousands of times.
        // The gap between head and resume point is LOW too, not IGNORE: the
        // resume byte is only an estimate, and a skipped piece the player
        // really needs stalled the start.
        val demoteFrom = (playPiece + playWindow).coerceAtMost(lastPiece + 1)
        runCatching {
            val prios = handle.piecePriorities()
            for (p in (firstPiece + headKeep) until playPiece) {
                if (p in prios.indices) prios[p] = Priority.LOW
            }
            for (p in demoteFrom..lastPiece) {
                if (p in prios.indices) prios[p] = Priority.LOW
            }
            handle.prioritizePieces(prios)
        }.onFailure { AppLog.e(TAG, "demote far pieces failed", it) }
        readaheadAt(handle, playPiece, force = true)
        // MKV cues / MP4 moov usually sit at the end of the file and the
        // player reads them before it starts: fetch the tail early.
        if (needsTailIndex(fs.fileName(chosen))) {
            val tail = ((4L * 1024 * 1024) / pieceLength).toInt().coerceIn(1, 4)
            for (i in 0 until tail) {
                val p = lastPiece - i
                if (p < playPiece + playWindow) break
                runCatching {
                    handle.setPieceDeadline(p, 300 + i * 100)
                    handle.piecePriority(p, Priority.TOP_PRIORITY)
                }
            }
        }
        AppLog.i(
            TAG,
            "prioritized playhead=$playPiece headKeep=$headKeep window=$playWindow " +
                "of $lastPiece pieceLen=$pieceLength resume=$wantResume",
        )

        val videoRel = fs.filePath(chosen)
        val videoFile = File(dir, videoRel)
        videoFile.parentFile?.mkdirs()
        videoFileRef.set(videoFile)

        // Ready when playhead has a contiguous head — not when 0→resume is filled.
        // Need enough for Exo to open + first decode without a post-100% stall.
        val minPlayContiguous = when {
            pieceLength >= 1_000_000 -> 2
            pieceLength >= 512_000 -> 3
            else -> 4
        }.coerceAtMost(playWindow)
        // On resume the playhead piece is a guess from the duration, so don't
        // hold the start for several of them: open once the head is in and let
        // the player's real reads steer the window.
        val minHeadContiguous = if (wantResume && playPiece > firstPiece + headKeep) {
            headKeep
        } else {
            minPlayContiguous
        }
        val readyEnough = withTimeoutOrNull(90_000L) {
            while (true) {
                val h = liveHandle(sm)
                if (h == null) {
                    delay(150)
                    continue
                }
                val st = runCatching { h.status() }.getOrNull()
                if (st == null) {
                    delay(150)
                    continue
                }
                fun countHave(from: Int, need: Int): Int {
                    var n = 0
                    while (n < need) {
                        val p = from + n
                        if (p > lastPiece) break
                        if (!runCatching { h.havePiece(p) }.getOrDefault(false)) break
                        n++
                    }
                    return n
                }
                val headHave = countHave(firstPiece, headKeep)
                val playHave = countHave(playPiece, minPlayContiguous)
                // Re-assert deadlines while waiting.
                if (headHave < minHeadContiguous) {
                    for (i in headHave until minHeadContiguous.coerceAtMost(headKeep)) {
                        val p = firstPiece + i
                        runCatching {
                            h.setPieceDeadline(p, 3 + i * 6)
                            h.piecePriority(p, Priority.TOP_PRIORITY)
                        }
                    }
                }
                if (playHave < minPlayContiguous) {
                    for (i in playHave until minPlayContiguous) {
                        val p = playPiece + i
                        if (p > lastPiece) break
                        runCatching {
                            h.setPieceDeadline(p, 2 + i * 6)
                            h.piecePriority(p, Priority.TOP_PRIORITY)
                        }
                    }
                }
                val progress = fileProgress(h, chosen, fileSize)
                // Never use st.progress() here — IGNORE gap shrinks "wanted" so
                // progress hits ~1.0 as soon as the playhead window fills.
                val complete = progress >= 0.99
                val rate = st.downloadPayloadRate() / (1024.0 * 1024.0)
                val headOk = headHave >= minHeadContiguous || playPiece <= firstPiece
                val playOk = playHave >= minPlayContiguous ||
                    (playHave >= 1 && rate >= 0.35) ||
                    (wantResume && headHave >= headKeep && playHave >= 1)
                val headReady = complete || (headOk && playOk)
                // Accurate 0–100%: bytes ready at head+playhead vs bytes needed to start.
                val needBytes = (
                    minHeadContiguous.toLong() * pieceLength +
                        minPlayContiguous.toLong() * pieceLength
                    ).coerceAtLeast(pieceLength.toLong()).toDouble()
                val gotBytes = (
                    headHave.toLong() * pieceLength +
                        playHave.toLong() * pieceLength
                    ).toDouble().coerceAtMost(needBytes)
                // Credit partial blocks on the next missing playhead piece.
                val nextPlay = playPiece + playHave
                val partialFrac = if (!headReady && nextPlay <= lastPiece) {
                    runCatching {
                        h.getDownloadQueue().firstOrNull { it.pieceIndex() == nextPlay }
                            ?.let { pi ->
                                if (pi.blocksInPiece() > 0) {
                                    pi.finished().toDouble() / pi.blocksInPiece()
                                } else {
                                    0.0
                                }
                            } ?: 0.0
                    }.getOrDefault(0.0)
                } else {
                    0.0
                }
                val rawPct = when {
                    complete || headReady -> 100.0
                    else -> (((gotBytes + partialFrac * pieceLength) / needBytes) * 100.0)
                        .coerceIn(0.0, 99.0)
                }
                smoothedBufferPct = smoothBuffer(rawPct, snapComplete = headReady || complete)
                val stats = LocalStreamStats(
                    bufferPct = smoothedBufferPct,
                    downloadMbps = rate,
                    seeders = st.numSeeds().coerceAtLeast(0),
                    peers = st.numPeers().coerceAtLeast(0),
                    ready = headReady,
                    torrentComplete = complete,
                )
                onStats?.invoke(stats)
                if (headReady) {
                    AppLog.i(
                        TAG,
                        "head ready playHave=$playHave/$minPlayContiguous headHave=$headHave " +
                            "playPiece=$playPiece rate=$rate",
                    )
                    return@withTimeoutOrNull true
                }
                delay(150)
            }
            @Suppress("UNREACHABLE_CODE")
            false
        } == true
        if (!readyEnough) {
            val h = liveHandle(sm)
            val peers = runCatching { h?.status()?.numPeers() ?: 0 }.getOrDefault(0)
            val got = if (h != null) {
                runCatching { fileProgress(h, chosen, fileSize) }.getOrDefault(0.0)
            } else {
                0.0
            }
            if (got < 0.001 && peers <= 0) {
                stop(deleteFiles = true)
                throw IllegalStateException("Couldn’t find enough peers to start this stream. Try another result.")
            }
        }

        val server = StreamHttpServer(
            handleProvider = { liveHandle(sm) },
            fileIndex = chosen,
            file = videoFile,
            fileSize = fileSize,
            onReadPiece = { piece -> liveHandle(sm)?.let { readaheadAt(it, piece) } },
        )
        server.start()
        httpServer.set(server)
        streamReadyLatched = true
        smoothedBufferPct = 100.0
        val url = server.url
        AppLog.i(TAG, "stream ready url=$url file=${videoFile.name} size=$fileSize")
        Log.i(TAG, "stream ready url=$url file=${videoFile.name} size=$fileSize")
        // Final tick so UI hits 100% before Exo opens.
        onStats?.invoke(
            LocalStreamStats(
                bufferPct = 100.0,
                downloadMbps = runCatching {
                    liveHandle(sm)?.status()?.downloadPayloadRate()?.div(1024.0 * 1024.0)
                }.getOrNull() ?: 0.0,
                seeders = runCatching { liveHandle(sm)?.status()?.numSeeds() ?: 0 }.getOrDefault(0),
                peers = runCatching { liveHandle(sm)?.status()?.numPeers() ?: 0 }.getOrDefault(0),
                ready = true,
                torrentComplete = false,
            ),
        )
        LocalStreamHandle(
            sessionId = "local-${System.currentTimeMillis()}",
            url = url,
            magnet = magnet,
            fileIndex = chosen,
        )
    }

    /** Prefer session.find(infoHash) — alert handles go stale after magnet metadata remap. */
    private fun liveHandle(sm: SessionManager): TorrentHandle? {
        val hash = infoHashRef.get()
        if (hash != null) {
            val found = runCatching { sm.find(hash) }.getOrNull()
            if (found != null && found.isValid) {
                handleRef.set(found)
                return found
            }
        }
        val cached = handleRef.get()
        if (cached != null && cached.isValid) {
            runCatching { infoHashRef.set(cached.infoHash()) }
            return cached
        }
        return null
    }

    fun currentStats(): LocalStreamStats? {
        val sm = session ?: return null
        val handle = liveHandle(sm) ?: return null
        val idx = fileIndexRef.get() ?: 0
        return try {
            val st = handle.status()
            val info = handle.torrentFile()
            val fileSize = info?.files()?.fileSize(idx) ?: st.totalWanted().coerceAtLeast(1)
            val progress = fileProgress(handle, idx, fileSize)
            val complete = progress >= 0.99
            if (streamReadyLatched) logStreamHealth(handle, st)
            if (streamReadyLatched || complete) {
                smoothedBufferPct = 100.0
                return LocalStreamStats(
                    bufferPct = 100.0,
                    downloadMbps = st.downloadPayloadRate() / (1024.0 * 1024.0),
                    seeders = st.numSeeds().coerceAtLeast(0),
                    peers = st.numPeers().coerceAtLeast(0),
                    ready = true,
                    torrentComplete = complete,
                )
            }
            val playheadPct = playheadBufferPct(handle, info, idx)
            smoothedBufferPct = smoothBuffer(playheadPct, snapComplete = playheadPct >= 99.5)
            LocalStreamStats(
                bufferPct = smoothedBufferPct,
                downloadMbps = st.downloadPayloadRate() / (1024.0 * 1024.0),
                seeders = st.numSeeds().coerceAtLeast(0),
                peers = st.numPeers().coerceAtLeast(0),
                ready = playheadPct >= 99.0 || complete,
                torrentComplete = complete,
            )
        } catch (_: Throwable) {
            null
        }
    }

    /**
     * Playhead runway as accurate 0–100%: contiguous (+partial) bytes at the
     * resume/play position vs the bytes needed for a smooth start (~start window).
     */
    private fun playheadBufferPct(handle: TorrentHandle, info: org.libtorrent4j.TorrentInfo?, idx: Int): Double {
        if (info == null) return 0.0
        val fs = info.files()
        val fileSize = fs.fileSize(idx)
        if (fileSize <= 0) return 0.0
        val pieceLength = info.pieceLength().coerceAtLeast(1)
        val first = (fs.fileOffset(idx) / pieceLength).toInt()
        val last = ((fs.fileOffset(idx) + fileSize - 1) / pieceLength).toInt()
        val from = if (lastSoftPiece >= 0) lastSoftPiece.coerceIn(first, last) else first
        // Match startup gate: enough contiguous playhead for Exo to open.
        val needPieces = when {
            pieceLength >= 1_000_000 -> 2
            pieceLength >= 512_000 -> 3
            else -> 4
        }.coerceAtMost(last - from + 1).coerceAtLeast(1)
        val needBytes = needPieces.toDouble() * pieceLength
        var haveBytes = 0.0
        var p = from
        while (haveBytes < needBytes && p <= last) {
            if (runCatching { handle.havePiece(p) }.getOrDefault(false)) {
                haveBytes += pieceLength.toDouble()
                p++
                continue
            }
            val partial = runCatching {
                handle.getDownloadQueue().firstOrNull { it.pieceIndex() == p }
            }.getOrNull()
            if (partial != null && partial.blocksInPiece() > 0) {
                haveBytes += pieceLength.toDouble() *
                    (partial.finished().toDouble() / partial.blocksInPiece())
            }
            break
        }
        return ((haveBytes / needBytes) * 100.0).coerceIn(0.0, 100.0)
    }

    /** Ease toward raw %; snap to 100 when the stream is actually ready. */
    private fun smoothBuffer(raw: Double, snapComplete: Boolean = false): Double {
        if (snapComplete || raw >= 99.5) return 100.0
        val prev = smoothedBufferPct
        val alpha = when {
            raw - prev > 15 -> 0.55 // catch up on big piece completes
            else -> 0.40
        }
        val next = when {
            raw <= prev -> raw
            else -> prev + (raw - prev) * alpha
        }
        // Never stall forever just below the target.
        return if (raw - next < 1.5) raw.coerceIn(0.0, 100.0) else next.coerceIn(0.0, 100.0)
    }

    /**
     * Move the download window to [positionMs].
     * @param aggressive user scrub — clear old deadlines and demote behind the playhead.
     *                   Soft playhead nudges must pass false so we don't thrash the swarm
     *                   (that caused underruns → black screen / player error).
     */
    fun seekTo(positionMs: Long, durationMs: Long, aggressive: Boolean = true) {
        val sm = session ?: return
        val handle = liveHandle(sm) ?: return
        val idx = fileIndexRef.get() ?: return
        if (positionMs < 0) return
        try {
            val info = runCatching { handle.torrentFile() }.getOrNull() ?: return
            val fs = info.files()
            val fileSize = fs.fileSize(idx)
            if (fileSize <= 0) return
            // Only skip retarget when the *file* is fully on disk — st.progress()
            // hits ~1.0 early when the IGNORE gap shrinks totalWanted.
            val filePct = fileProgress(handle, idx, fileSize)
            if (filePct >= 0.99) return
            noteDuration(fileSize, durationMs)
            val pieceLength = info.pieceLength().coerceAtLeast(1)
            val ratio = if (durationMs > 0) {
                (positionMs.toDouble() / durationMs).coerceIn(0.0, 0.98)
            } else {
                val assumedBps = 2_500_000.0
                ((positionMs / 1000.0) * assumedBps / fileSize).coerceIn(0.0, 0.98)
            }
            val offset = (fileSize * ratio).toLong()
            val piece = ((fs.fileOffset(idx) + offset) / pieceLength).toInt()
            val last = ((fs.fileOffset(idx) + fileSize - 1) / pieceLength).toInt()
            val firstFile = (fs.fileOffset(idx) / pieceLength).toInt()

            // Deadlines only — sequential_download / setSequentialRange fight seeks
            // (libtorrent streaming docs + libtorrent_flutter).
            runCatching { handle.unsetFlags(TorrentFlags.SEQUENTIAL_DOWNLOAD) }
            if (aggressive) {
                runCatching { handle.clearPieceDeadlines() }
                val prios = Priority.array(Priority.DEFAULT, info.numPieces())
                // Drop the gap behind the new playhead so bandwidth isn't wasted.
                val headKeep = ((2L * 1024 * 1024) / pieceLength).toInt().coerceIn(1, 2)
                // The target piece is estimated from position / duration; keep
                // ~32 MB before it wanted (LOW) in case the real byte is earlier.
                val margin = ((32L * 1024 * 1024) / pieceLength).toInt()
                for (p in firstFile until piece.coerceAtMost(last + 1)) {
                    if (p in prios.indices) {
                        prios[p] = if (p >= piece - margin) Priority.LOW else Priority.IGNORE
                    }
                }
                for (i in 0 until headKeep) {
                    val p = firstFile + i
                    if (p in prios.indices && p <= last) prios[p] = Priority.TOP_PRIORITY
                }
                val window = windowPieces(pieceLength.toLong())
                for (i in 0 until window) {
                    val p = piece + i
                    if (p > last || p !in prios.indices) break
                    prios[p] = Priority.TOP_PRIORITY
                }
                // Far future: wanted but not urgent (keeps st.progress honest).
                for (p in (piece + window).coerceAtMost(last + 1)..last) {
                    if (p in prios.indices) prios[p] = Priority.LOW
                }
                // Keep the container index at the tail (MKV cues / MP4 moov).
                for (i in 0 until 2) {
                    val p = last - i
                    if (p >= piece + window && p in prios.indices) prios[p] = Priority.TOP_PRIORITY
                }
                runCatching { handle.prioritizePieces(prios) }
                lastSoftPiece = piece
                readaheadAt(handle, piece, force = true)
                for (i in 0 until headKeep) {
                    val p = firstFile + i
                    if (p > last || p >= piece) break
                    handle.setPieceDeadline(p, 3 + i * 6)
                }
            } else {
                // Soft playhead nudge: refresh the read-ahead deadlines only.
                if (lastSoftPiece < 0 || kotlin.math.abs(piece - lastSoftPiece) >= 3) {
                    lastSoftPiece = piece
                }
                // Once the player is reading, its real byte position beats this
                // estimate from position / duration (they can be tens of MB apart).
                val anchor = if (httpServer.get() != null && readaheadFrom >= 0) readaheadFrom else piece
                readaheadAt(handle, anchor, force = true)
                val headKeep = ((2L * 1024 * 1024) / pieceLength).toInt().coerceIn(1, 2)
                for (i in 0 until headKeep) {
                    val p = firstFile + i
                    if (p > last || p >= piece) break
                    handle.setPieceDeadline(p, 4 + i * 6)
                    handle.piecePriority(p, Priority.TOP_PRIORITY)
                }
            }
            handle.resume()
            AppLog.i(
                TAG,
                "seekTo pos=$positionMs dur=$durationMs piece=$piece aggressive=$aggressive",
            )
            // Never probe HTTP while Exo is already reading — competing Range
            // clients on our single-threaded stream server caused black screens.
        } catch (t: Throwable) {
            Log.w(TAG, "seekTo failed", t)
            AppLog.e(TAG, "seekTo failed", t)
        }
    }

    @Synchronized
    fun stop(deleteFiles: Boolean = true) {
        httpServer.getAndSet(null)?.stopQuietly()
        val sm = session
        val handle = handleRef.getAndSet(null)
        infoHashRef.set(null)
        fileIndexRef.set(null)
        videoFileRef.set(null)
        metadataLatch.set(false)
        lastSoftPiece = -1
        smoothedBufferPct = 0.0
        streamReadyLatched = false
        bytesPerSec = 0.0
        streamLastPiece = -1
        readaheadFrom = -1
        if (handle != null && handle.isValid && sm != null) {
            try {
                if (deleteFiles) {
                    sm.remove(handle, session_handle.delete_files)
                } else {
                    sm.remove(handle)
                }
            } catch (t: Throwable) {
                Log.w(TAG, "remove torrent failed", t)
                runCatching { sm.remove(handle) }
            }
        }
    }

    /** Stop torrents and delete all on-device stream pieces. */
    @Synchronized
    fun purge(context: Context) {
        stop(deleteFiles = true)
        val roots = listOfNotNull(
            saveDir,
            File(context.applicationContext.filesDir, "pb-streams"),
            File(context.applicationContext.cacheDir, "pb-streams"),
            context.applicationContext.externalCacheDir?.let { File(it, "pb-streams") },
        )
        for (root in roots) {
            runCatching {
                if (root.exists()) root.deleteRecursively()
                root.mkdirs()
            }
        }
        StreamDownloads.wipePlayerCaches(context)
    }

    private fun fileProgress(handle: TorrentHandle, index: Int, fileSize: Long): Double {
        if (fileSize <= 0) return handle.status().progress().toDouble()
        return try {
            val got = handle.fileProgress().getOrNull(index) ?: 0L
            (got.toDouble() / fileSize).coerceIn(0.0, 1.0)
        } catch (_: Throwable) {
            handle.status().progress().toDouble()
        }
    }

    @Volatile private var lastHealthLogMs = 0L

    /** Every 10 s while streaming: speed, peers and how much is ready past the reader. */
    private fun logStreamHealth(handle: TorrentHandle, st: org.libtorrent4j.TorrentStatus) {
        val now = System.currentTimeMillis()
        if (now - lastHealthLogMs < 10_000L) return
        lastHealthLogMs = now
        val from = readaheadFrom
        val last = streamLastPiece
        if (from < 0 || last < 0) return
        var ahead = 0
        while (from + ahead <= last && runCatching { handle.havePiece(from + ahead) }.getOrDefault(false)) ahead++
        val secs = ahead * streamPieceLength / planBytesPerSec()
        AppLog.i(
            TAG,
            "health rate=%.2fMB/s peers=%d seeds=%d reader=%d ready_ahead=%d pieces (~%.0fs)".format(
                st.downloadPayloadRate() / 1048576.0, st.numPeers(), st.numSeeds(), from, ahead, secs,
            ),
        )
    }

    private fun noteDuration(fileSize: Long, durationMs: Long) {
        if (fileSize > 0 && durationMs > 60_000L) {
            bytesPerSec = fileSize * 1000.0 / durationMs
        }
    }

    /** Bitrate to plan with: the real one when the duration is known, else ~12 Mbps. */
    private fun planBytesPerSec(): Double = bytesPerSec.takeIf { it > 0 } ?: 1_500_000.0

    /** Pieces covering ~[READAHEAD_SECONDS] of video, kept between 32 and 192 MB. */
    private fun windowPieces(pieceLength: Long): Int {
        val bytes = (planBytesPerSec() * READAHEAD_SECONDS)
            .coerceIn(32.0 * 1024 * 1024, 192.0 * 1024 * 1024)
        return (bytes / pieceLength.coerceAtLeast(1)).toInt().coerceIn(8, 384)
    }

    /**
     * Keep a sliding window of pieces wanted ahead of [piece] (the player's
     * read position). Each deadline is about half the time playback needs to
     * reach that piece, so the next piece is always the most urgent and later
     * ones are fetched in order instead of all at once.
     */
    private fun readaheadAt(handle: TorrentHandle, piece: Int, force: Boolean = false) {
        val last = streamLastPiece
        val pieceLength = streamPieceLength
        if (last < 0 || pieceLength <= 0) return
        val from = piece.coerceIn(streamFirstPiece, last)
        if (!force && from == readaheadFrom) return
        readaheadFrom = from
        val msPerPiece = pieceLength * 1000.0 / planBytesPerSec()
        val n = windowPieces(pieceLength)
        for (i in 0 until n) {
            val p = from + i
            if (p > last) break
            if (runCatching { handle.havePiece(p) }.getOrDefault(false)) continue
            runCatching {
                handle.setPieceDeadline(p, (i * msPerPiece * 0.5).toInt())
                handle.piecePriority(p, Priority.TOP_PRIORITY)
            }
        }
    }

    private fun isMp4(name: String): Boolean =
        name.substringAfterLast('.', "").lowercase() in setOf("mp4", "m4v", "mov")

    private fun needsTailIndex(name: String): Boolean =
        name.substringAfterLast('.', "").lowercase() in setOf("mkv", "webm", "mp4", "m4v", "mov")

    private fun injectTrackers(handle: TorrentHandle) {
        // Server's live list first: it is refreshed every 12h, the fallback isn't.
        val list = (extraTrackers + publicTrackers).distinct().take(20)
        for (tr in list) {
            runCatching { handle.addTracker(AnnounceEntry(tr)) }
        }
        // Do NOT forceReannounce here — native crash on BeyondTV after metadata.
    }

    /** Keep magnet lean enough for ARM, but ensure enough public trackers for peers. */
    private fun slimMagnet(magnet: String): String {
        val uri = magnet.trim()
        if (!uri.lowercase().startsWith("magnet:")) return uri
        val trCount = Regex("[?&]tr=").findAll(uri).count()
        if (trCount >= 6) return uri
        return withPublicTrackers(uri)
    }

    private fun withPublicTrackers(magnet: String): String {
        var uri = magnet.trim()
        if (!uri.lowercase().startsWith("magnet:")) return uri
        for (tr in publicTrackers.take(10)) {
            val enc = URLEncoder.encode(tr, "UTF-8")
            if (!uri.contains(enc) && !uri.contains(tr)) {
                uri = "$uri&tr=$enc"
            }
        }
        return uri
    }

    private fun pickFile(info: TorrentInfo, season: Int?, episode: Int?): Int? {
        val fs = info.files()
        val videoExt = setOf(
            "mkv", "mp4", "m4v", "mov", "avi", "webm", "ts", "m2ts", "mts",
            "mpeg", "mpg", "vob", "flv", "wmv", "ogv", "3gp",
        )
        fun isVideo(i: Int): Boolean {
            val name = fs.fileName(i).lowercase()
            val ext = name.substringAfterLast('.', "")
            return ext in videoExt
        }
        var videos = (0 until info.numFiles()).filter(::isVideo)
        if (videos.isEmpty()) return if (info.numFiles() > 0) 0 else null
        videos = videos.filter { i ->
            val h = " ${fs.fileName(i).lowercase().replace(Regex("[^a-z0-9]+"), " ")} "
            !h.contains(" sample ") && !h.contains(" trailer ")
        }.ifEmpty { (0 until info.numFiles()).filter(::isVideo) }

        if (season != null && episode != null) {
            val tag = "s${season.toString().padStart(2, '0')}e${episode.toString().padStart(2, '0')}"
            val hits = videos.filter { i ->
                val n = fs.fileName(i).lowercase().replace(Regex("[^a-z0-9]+"), "")
                n.contains(tag) || n.contains("${season}x${episode.toString().padStart(2, '0')}")
            }
            if (hits.isNotEmpty()) videos = hits
        }
        return videos.maxByOrNull { fs.fileSize(it) }
    }
    /**
     * Same peer and piece tuning as the desktop engine (torrent_bridge.cpp).
     * On libtorrent's defaults the TV announced to one tracker, opened 30
     * connections a second with 15 s timeouts, fetched each piece from a
     * single peer and dropped seeds after every streaming window — so it
     * found peers late and started playback much slower than desktop.
     */
    private fun applyStreamingTuning(pack: SettingsPack) {
        val i = { k: settings_pack.int_types, v: Int -> pack.setInteger(k.swigValue(), v) }
        val b = { k: settings_pack.bool_types, v: Boolean -> pack.setBoolean(k.swigValue(), v) }
        runCatching {
            // Find and connect to peers fast.
            b(settings_pack.bool_types.announce_to_all_trackers, true)
            b(settings_pack.bool_types.announce_to_all_tiers, true)
            i(settings_pack.int_types.connection_speed, 200)
            i(settings_pack.int_types.torrent_connect_boost, 200)
            b(settings_pack.bool_types.smooth_connects, false)
            i(settings_pack.int_types.min_reconnect_time, 5)
            i(settings_pack.int_types.max_failcount, 3)
            i(settings_pack.int_types.peer_connect_timeout, 5)
            i(settings_pack.int_types.handshake_timeout, 5)
            i(settings_pack.int_types.dht_announce_interval, 60)
            b(settings_pack.bool_types.enable_upnp, true)
            b(settings_pack.bool_types.enable_natpmp, true)
            // Streams only want a sliding window, so libtorrent keeps thinking
            // the torrent is finished; keep the seeds connected.
            b(settings_pack.bool_types.close_redundant_connections, false)
            b(settings_pack.bool_types.allow_multiple_connections_per_ip, true)
            // Pieces near the playhead come from many peers at once.
            i(settings_pack.int_types.whole_pieces_threshold, 0)
            i(settings_pack.int_types.piece_timeout, 5)
            i(settings_pack.int_types.request_timeout, 5)
            i(settings_pack.int_types.request_queue_time, 1)
            i(settings_pack.int_types.max_out_request_queue, 500)
            b(settings_pack.bool_types.strict_end_game_mode, false)
            b(settings_pack.bool_types.prioritize_partial_pieces, true)
            b(settings_pack.bool_types.piece_extent_affinity, true)
            i(settings_pack.int_types.initial_picker_threshold, 0)
            i(settings_pack.int_types.predictive_piece_announce, 500)
            // Reciprocate so peers unchoke us sooner.
            i(settings_pack.int_types.unchoke_slots_limit, -1)
            // Encrypted handshake first (gets past ISP throttling), plaintext allowed.
            i(settings_pack.int_types.in_enc_policy, settings_pack.enc_policy.pe_enabled.swigValue())
            i(settings_pack.int_types.out_enc_policy, settings_pack.enc_policy.pe_enabled.swigValue())
            i(settings_pack.int_types.allowed_enc_level, settings_pack.enc_level.pe_both.swigValue())
            // TVs have little RAM: a modest write queue instead of desktop's 64 MB.
            i(settings_pack.int_types.max_queued_disk_bytes, 16 * 1024 * 1024)
        }.onFailure { Log.w(TAG, "streaming tuning not applied", it) }
    }
}

data class LocalStreamHandle(
    val sessionId: String,
    val url: String,
    val magnet: String,
    val fileIndex: Int,
)

data class LocalStreamStats(
    val bufferPct: Double,
    val downloadMbps: Double,
    val seeders: Int,
    val peers: Int,
    val ready: Boolean,
    val torrentComplete: Boolean = false,
) {
    companion object {
        fun empty() = LocalStreamStats(0.0, 0.0, 0, 0, false)
    }

}
