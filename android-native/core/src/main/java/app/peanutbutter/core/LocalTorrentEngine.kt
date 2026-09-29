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
            // DHT/LSD have crashed libtorrent native on this BeyondTV (armeabi-v7a).
            pack.setEnableDht(false)
            pack.setEnableLsd(false)
            pack.connectionsLimit(60)
            pack.activeDownloads(3)
            pack.activeSeeds(1)
            pack.activeLimit(4)
            pack.downloadRateLimit(0)
            pack.uploadRateLimit(0)
            pack.listenInterfaces("0.0.0.0:0")
            sm.start()
            sm.applySettings(pack)
            sm.maxConnections(60)
            sm.downloadRateLimit(0)
            sm.uploadRateLimit(0)
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
            AppLog.i(TAG, "libtorrent session started save=$dir (dht=off lsd=off)")
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
        onStats: ((LocalStreamStats) -> Unit)? = null,
    ): LocalStreamHandle = withContext(Dispatchers.IO) {
        ensureInit(context)
        if (!ready) throw IllegalStateException("On-device torrent streaming isn’t available on this device.")
        AppLog.i(TAG, "start magnet=${magnet.take(64)}… fileIndex=$fileIndex")
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
        runCatching { handle.setFlags(TorrentFlags.SEQUENTIAL_DOWNLOAD) }
        runCatching { handle.resume() }

        // Prioritize a small head window only — large deadline loops OOMed / crashed ARM.
        val fs = info.files()
        val fileSize = fs.fileSize(chosen)
        val pieceLength = info.pieceLength().coerceAtLeast(1)
        val firstPiece = (fs.fileOffset(chosen) / pieceLength).toInt()
        val lastPiece = ((fs.fileOffset(chosen) + fileSize - 1) / pieceLength).toInt()
        runCatching { handle.setSequentialRange(firstPiece, lastPiece) }
        val headPieces = ((4L * 1024 * 1024) / pieceLength).toInt().coerceIn(2, 12)
        for (i in 0 until headPieces.coerceAtMost(lastPiece - firstPiece + 1)) {
            val p = firstPiece + i
            runCatching {
                handle.setPieceDeadline(p, 100 + i * 50)
                handle.piecePriority(p, Priority.TOP_PRIORITY)
            }
        }
        AppLog.i(TAG, "prioritized pieces $firstPiece..${firstPiece + headPieces - 1} of $lastPiece")

        val videoRel = fs.filePath(chosen)
        val videoFile = File(dir, videoRel)
        videoFile.parentFile?.mkdirs()
        videoFileRef.set(videoFile)

        // Wait until some head bytes exist (or whole file done) before exposing URL.
        val readyEnough = withTimeoutOrNull(90_000L) {
            while (true) {
                val h = liveHandle(sm)
                if (h == null) {
                    delay(300)
                    continue
                }
                val st = runCatching { h.status() }.getOrNull()
                if (st == null) {
                    delay(300)
                    continue
                }
                val progress = fileProgress(h, chosen, fileSize)
                val stats = LocalStreamStats(
                    bufferPct = (progress * 100.0).coerceIn(0.0, if (progress >= 0.99) 100.0 else 99.0),
                    downloadMbps = st.downloadPayloadRate() / (1024.0 * 1024.0),
                    seeders = st.numSeeds().coerceAtLeast(0),
                    peers = st.numPeers().coerceAtLeast(0),
                    ready = progress >= 0.01 || st.isFinished || st.progress().toDouble() >= 0.99,
                    torrentComplete = st.isFinished || progress >= 0.99 || st.progress().toDouble() >= 0.99,
                )
                onStats?.invoke(stats)
                if (stats.ready || stats.torrentComplete || st.downloadPayloadRate() > 16 * 1024) {
                    if (stats.torrentComplete || videoFile.exists() && videoFile.length() > 256 * 1024) {
                        return@withTimeoutOrNull true
                    }
                    if (progress >= 0.005) return@withTimeoutOrNull true
                }
                delay(300)
            }
            @Suppress("UNREACHABLE_CODE")
            false
        } == true
        if (!readyEnough) {
            val h = liveHandle(sm)
            val peers = runCatching { h?.status()?.numPeers() ?: 0 }.getOrDefault(0)
            if (!videoFile.exists() && peers <= 0) {
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
            val torrentPct = st.progress().toDouble()
            val complete = st.isFinished || progress >= 0.99 || torrentPct >= 0.99
            LocalStreamStats(
                bufferPct = when {
                    complete -> 100.0
                    progress >= 0.01 -> (progress * 100.0).coerceIn(0.0, 99.0)
                    else -> (torrentPct * 100.0).coerceIn(0.0, 95.0)
                },
                downloadMbps = st.downloadPayloadRate() / (1024.0 * 1024.0),
                seeders = st.numSeeds().coerceAtLeast(0),
                peers = st.numPeers().coerceAtLeast(0),
                ready = progress >= 0.01 || complete,
                torrentComplete = complete,
            )
        } catch (_: Throwable) {
            null
        }
    }

    fun seekTo(positionMs: Long, durationMs: Long) {
        val sm = session ?: return
        val handle = liveHandle(sm) ?: return
        val idx = fileIndexRef.get() ?: return
        if (positionMs < 0) return
        try {
            val st = runCatching { handle.status() }.getOrNull() ?: return
            if (st.isFinished || st.progress().toDouble() >= 0.99) return
            val info = runCatching { handle.torrentFile() }.getOrNull() ?: return
            val fs = info.files()
            val fileSize = fs.fileSize(idx)
            if (fileSize <= 0) return
            val pieceLength = info.pieceLength().coerceAtLeast(1)
            val ratio = if (durationMs > 0) {
                (positionMs.toDouble() / durationMs).coerceIn(0.0, 0.98)
            } else {
                val assumedBps = 250_000.0
                ((positionMs / 1000.0) * assumedBps / fileSize).coerceIn(0.0, 0.98)
            }
            val offset = (fileSize * ratio).toLong()
            val piece = ((fs.fileOffset(idx) + offset) / pieceLength).toInt()
            val last = ((fs.fileOffset(idx) + fileSize - 1) / pieceLength).toInt()
            val firstFile = (fs.fileOffset(idx) / pieceLength).toInt()

            // Drop old deadlines so the swarm stops chasing the previous playhead.
            runCatching { handle.clearPieceDeadlines() }

            // Demote pieces before the seek point — keep them downloadable but not urgent.
            val prios = Priority.array(Priority.DEFAULT, info.numPieces())
            for (p in firstFile until piece.coerceAtMost(last + 1)) {
                if (p in prios.indices) prios[p] = Priority.LOW
            }
            // High priority window right at the scrubbed frame.
            val window = 48
            for (i in 0 until window) {
                val p = piece + i
                if (p > last || p !in prios.indices) break
                prios[p] = Priority.TOP_PRIORITY
            }
            // Keep remaining file pieces default so sequential can continue after the window.
            runCatching { handle.prioritizePieces(prios) }
            handle.setSequentialRange(piece, last)
            for (i in 0 until window) {
                val p = piece + i
                if (p > last) break
                handle.setPieceDeadline(p, 20 + i * 25)
            }
            handle.resume()
            AppLog.i(TAG, "seekTo pos=$positionMs dur=$durationMs piece=$piece offset=$offset")

            // Flutter parity: open a Range reader at the seek byte so the HTTP
            // server blocks on those pieces and peers fill from the scrub point.
            val url = httpServer.get()?.url
            if (!url.isNullOrBlank()) {
                Thread {
                    probeHttpRange(url, offset, fileSize)
                }.start()
            }
        } catch (t: Throwable) {
            Log.w(TAG, "seekTo failed", t)
            AppLog.e(TAG, "seekTo failed", t)
        }
    }

    /** Pull a few MB from [offset] so libtorrent's piece window follows the seek. */
    private fun probeHttpRange(url: String, offset: Long, fileSize: Long) {
        if (offset < 0 || fileSize <= 0) return
        val end = (offset + 4L * 1024 * 1024 - 1).coerceAtMost(fileSize - 1).coerceAtLeast(offset)
        var conn: java.net.HttpURLConnection? = null
        try {
            conn = (java.net.URL(url).openConnection() as java.net.HttpURLConnection).apply {
                connectTimeout = 4_000
                readTimeout = 12_000
                setRequestProperty("Range", "bytes=$offset-$end")
            }
            conn.connect()
            conn.inputStream.use { input ->
                val buf = ByteArray(64 * 1024)
                var got = 0
                while (got < 2 * 1024 * 1024) {
                    val n = input.read(buf)
                    if (n <= 0) break
                    got += n
                }
            }
        } catch (t: Throwable) {
            Log.w(TAG, "probeHttpRange failed: ${t.message}")
        } finally {
            runCatching { conn?.disconnect() }
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
        for (tr in publicTrackers.take(3)) {
            runCatching { handle.addTracker(AnnounceEntry(tr)) }
        }
        // Do NOT forceReannounce here — native crash on BeyondTV after metadata.
    }

    /** Keep magnet lean — stuffing dozens of trackers has crashed native on ARM TVs. */
    private fun slimMagnet(magnet: String): String {
        val uri = magnet.trim()
        if (!uri.lowercase().startsWith("magnet:")) return uri
        val trCount = Regex("[?&]tr=").findAll(uri).count()
        if (trCount >= 2) return uri
        return withPublicTrackers(uri)
    }

    private fun withPublicTrackers(magnet: String): String {
        var uri = magnet.trim()
        if (!uri.lowercase().startsWith("magnet:")) return uri
        for (tr in publicTrackers.take(5)) {
            val enc = URLEncoder.encode(tr, "UTF-8")
            if (!uri.contains(enc) && !uri.contains(tr)) {
                uri = "$uri&tr=$enc"
            }
        }
        return uri
    }

    private fun pickFile(info: TorrentInfo, season: Int?, episode: Int?): Int? {
        val fs = info.files()
        val videoExt = setOf("mkv", "mp4", "avi", "webm", "mov", "m4v")
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
