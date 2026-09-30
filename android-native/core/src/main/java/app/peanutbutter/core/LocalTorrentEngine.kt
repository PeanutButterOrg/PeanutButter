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
    private val publicTrackers = listOf(
        "udp://tracker.opentrackr.org:1337/announce",
        "udp://open.stealth.si:80/announce",
        "udp://tracker.openbittorrent.com:6969/announce",
        "udp://explodie.org:6969/announce",
        "udp://tracker.torrent.eu.org:451/announce",
        "udp://exodus.desync.com:6969/announce",
        "udp://open.demonii.com:1337/announce",
        "udp://tracker.moeking.me:6969/announce",
        "udp://tracker.tiny-vps.com:6969/announce",
        "udp://tracker.dler.org:6969/announce",
        "udp://tracker1.bt.moack.co.kr:80/announce",
        "udp://bt1.archive.org:6969/announce",
        "udp://bt2.archive.org:6969/announce",
        "http://tracker.openbittorrent.com:80/announce",
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
    /** Smoothed UI buffer % so large pieces don't leap 1→40→80. */
    @Volatile private var smoothedBufferPct: Double = 0.0

    val isSupported: Boolean get() = !nativeUnavailable
    val isActive: Boolean get() = handleRef.get()?.isValid == true

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
            pack.setEnableLsd(true)
            pack.connectionsLimit(200)
            pack.activeDownloads(8)
            pack.activeSeeds(4)
            pack.activeLimit(12)
            pack.downloadRateLimit(0)
            pack.uploadRateLimit(0)
            pack.listenInterfaces("0.0.0.0:0")
            pack.maxPeerlistSize(4_000)
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

        // Tiny container head for Exo Range(0) moov/ftyp probe.
        val headKeep = if (wantResume) {
            ((2L * 1024 * 1024) / pieceLength).toInt().coerceIn(1, 2)
        } else {
            ((4L * 1024 * 1024) / pieceLength).toInt().coerceIn(1, 4)
        }
        // Skip the gap between head and playhead — that was the 10–20% crawl.
        if (wantResume && playPiece > firstPiece + headKeep) {
            for (p in (firstPiece + headKeep) until playPiece) {
                runCatching { handle.piecePriority(p, Priority.IGNORE) }
            }
        }
        for (i in 0 until headKeep.coerceAtMost(lastPiece - firstPiece + 1)) {
            val p = firstPiece + i
            runCatching {
                handle.setPieceDeadline(p, 4 + i * 8)
                handle.piecePriority(p, Priority.TOP_PRIORITY)
            }
        }

        // Deep deadline window ahead of the playhead for smooth playback.
        val playWindow = ((40L * 1024 * 1024) / pieceLength).toInt().coerceIn(16, 96)
        for (i in 0 until playWindow.coerceAtMost(lastPiece - playPiece + 1)) {
            val p = playPiece + i
            runCatching {
                handle.setPieceDeadline(p, 5 + i * 8)
                handle.piecePriority(p, Priority.TOP_PRIORITY)
            }
        }
        // Demote the far future so deadlines win, but keep pieces wanted (LOW —
        // not IGNORE) so st.progress() isn't "100%" after a 40MB window.
        val demoteFrom = (playPiece + playWindow).coerceAtMost(lastPiece + 1)
        if (demoteFrom <= lastPiece) {
            for (p in demoteFrom..lastPiece) {
                runCatching { handle.piecePriority(p, Priority.LOW) }
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
        val minPlayContiguous = when {
            pieceLength >= 1_000_000 -> 1
            pieceLength >= 512_000 -> 2
            else -> 3
        }.coerceAtMost(playWindow)
        val minHeadContiguous = if (wantResume && playPiece > firstPiece + headKeep) 1 else minPlayContiguous
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
                    (playHave >= 1 && rate >= 0.35)
                val headReady = complete || (headOk && playOk)
                val needTotal = (minHeadContiguous + minPlayContiguous).coerceAtLeast(1)
                val gotTotal = (headHave + playHave).coerceAtMost(needTotal)
                val rawPct = when {
                    complete -> 100.0
                    headReady -> 90.0
                    else -> (gotTotal.toDouble() / needTotal * 85.0).coerceIn(0.0, 84.0)
                }
                smoothedBufferPct = smoothBuffer(rawPct)
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
        )
        server.start()
        httpServer.set(server)
        val url = server.url
        AppLog.i(TAG, "stream ready url=$url file=${videoFile.name} size=$fileSize")
        Log.i(TAG, "stream ready url=$url file=${videoFile.name} size=$fileSize")
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
            // Full-file only — never st.progress() (IGNORE gap makes that hit ~1.0 early).
            val complete = progress >= 0.99
            val playheadPct = playheadBufferPct(handle, info, idx)
            val rawPct = when {
                complete -> 100.0
                else -> playheadPct.coerceIn(0.0, 90.0)
            }
            smoothedBufferPct = smoothBuffer(rawPct)
            LocalStreamStats(
                bufferPct = smoothedBufferPct,
                downloadMbps = st.downloadPayloadRate() / (1024.0 * 1024.0),
                seeders = st.numSeeds().coerceAtLeast(0),
                peers = st.numPeers().coerceAtLeast(0),
                ready = playheadPct >= 8.0 || complete,
                torrentComplete = complete,
            )
        } catch (_: Throwable) {
            null
        }
    }

    /**
     * Playhead runway (not whole-file download %): contiguous bytes ready at the
     * resume/play position vs ~24MB comfort window, scaled 0–90.
     * Includes partial progress on the next piece so the bar doesn't leap per piece.
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
        val comfortBytes = 24L * 1024 * 1024
        val needBytes = comfortBytes.toDouble()
        var haveBytes = 0.0
        var p = from
        while (haveBytes < needBytes && p <= last) {
            if (runCatching { handle.havePiece(p) }.getOrDefault(false)) {
                haveBytes += pieceLength.toDouble()
                p++
                continue
            }
            // Credit blocks already finished in the next incomplete piece.
            val partial = runCatching {
                handle.getDownloadQueue().firstOrNull { it.pieceIndex() == p }
            }.getOrNull()
            if (partial != null && partial.blocksInPiece() > 0) {
                haveBytes += pieceLength.toDouble() *
                    (partial.finished().toDouble() / partial.blocksInPiece())
            }
            break
        }
        return ((haveBytes / needBytes) * 90.0).coerceIn(0.0, 90.0)
    }

    /** Ease the UI bar toward the raw playhead % (piece boundaries are coarse). */
    private fun smoothBuffer(raw: Double): Double {
        val prev = smoothedBufferPct
        val next = when {
            raw >= 99.5 -> 100.0
            raw <= prev -> raw // allow drop on seek
            else -> prev + (raw - prev) * 0.35
        }
        return next.coerceIn(0.0, 100.0)
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
                for (p in firstFile until piece.coerceAtMost(last + 1)) {
                    if (p in prios.indices) prios[p] = Priority.IGNORE
                }
                for (i in 0 until headKeep) {
                    val p = firstFile + i
                    if (p in prios.indices && p <= last) prios[p] = Priority.TOP_PRIORITY
                }
                val window = 72
                for (i in 0 until window) {
                    val p = piece + i
                    if (p > last || p !in prios.indices) break
                    prios[p] = Priority.TOP_PRIORITY
                }
                // Far future: wanted but not urgent (keeps st.progress honest).
                for (p in (piece + window).coerceAtMost(last + 1)..last) {
                    if (p in prios.indices) prios[p] = Priority.LOW
                }
                runCatching { handle.prioritizePieces(prios) }
                lastSoftPiece = piece
                for (i in 0 until window) {
                    val p = piece + i
                    if (p > last) break
                    handle.setPieceDeadline(p, 4 + i * 8)
                }
                for (i in 0 until headKeep) {
                    val p = firstFile + i
                    if (p > last || p >= piece) break
                    handle.setPieceDeadline(p, 3 + i * 6)
                }
            } else {
                // Soft playhead nudge: boost deadlines only — no sequential thrash.
                val window = 72
                if (lastSoftPiece < 0 || kotlin.math.abs(piece - lastSoftPiece) >= 3) {
                    lastSoftPiece = piece
                }
                for (i in 0 until window) {
                    val p = piece + i
                    if (p > last) break
                    handle.setPieceDeadline(p, 6 + i * 8)
                    handle.piecePriority(p, Priority.TOP_PRIORITY)
                }
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
                "seekTo pos=$positionMs dur=$durationMs piece=$piece aggressive=$aggressive window=72",
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

    private fun injectTrackers(handle: TorrentHandle) {
        for (tr in publicTrackers.take(10)) {
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
