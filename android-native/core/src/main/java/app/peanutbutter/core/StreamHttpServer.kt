package app.peanutbutter.core

import android.util.Log
import org.libtorrent4j.TorrentHandle
import java.io.BufferedOutputStream
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.io.RandomAccessFile
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import kotlin.math.min

/**
 * Minimal HTTP Range server over a growing torrent file.
 * Blocks until requested pieces exist (libtorrent streaming parity with Flutter).
 */
class StreamHttpServer(
    private val handleProvider: () -> TorrentHandle?,
    private val fileIndex: Int,
    private val file: File,
    private val fileSize: Long,
    /** Called when the player's read position enters a new piece (drives read-ahead). */
    private val onReadPiece: (Int) -> Unit = {},
    /** The player jumped to another part of the file (seek or resume). */
    private val onSeek: (Int) -> Unit = {},
) {
    private val running = AtomicBoolean(false)
    /**
     * The player has one live connection at a time; a seek opens a new one.
     * Older requests stop waiting as soon as a newer one arrives, so they
     * don't keep pulling pieces at the old position.
     */
    private val generation = AtomicLong(0)
    @Volatile private var geometry: Geometry? = null
    @Volatile private var lastReadPiece = -1
    /** Where the player's reading stands (byte after the last one sent). */
    @Volatile private var servedPos = -1L
    @Volatile private var startedAtMs = 0L
    /** Bumped when the user seeks: requests stuck waiting for a piece give up. */
    private val abortWaits = AtomicLong(0)

    private class Geometry(val pieceLength: Long, val fileOffset: Long, val lastPiece: Int)
    private var serverSocket: ServerSocket? = null
    private val pool = Executors.newCachedThreadPool()

    @Volatile
    var url: String = ""
        private set

    fun start() {
        if (running.getAndSet(true)) return
        startedAtMs = System.currentTimeMillis()
        val ss = ServerSocket(0, 8, InetAddress.getByName("127.0.0.1"))
        serverSocket = ss
        url = "http://127.0.0.1:${ss.localPort}/stream"
        pool.execute {
            while (running.get()) {
                try {
                    val socket = ss.accept()
                    pool.execute { handleClient(socket) }
                } catch (_: Throwable) {
                    if (!running.get()) break
                }
            }
        }
        Log.i(TAG, "HTTP stream listening on $url")
    }

    /**
     * The user seeks: end requests blocked on a missing piece now. The player
     * only sends the new request once the old read returns, which cost
     * seconds per seek while the old piece was still downloading.
     */
    fun abortWaiting() {
        abortWaits.incrementAndGet()
    }

    fun stopQuietly() {
        running.set(false)
        runCatching { serverSocket?.close() }
        pool.shutdownNow()
    }

    private fun handleClient(socket: Socket) {
        socket.soTimeout = 120_000
        try {
            val input = socket.getInputStream()
            val output = BufferedOutputStream(socket.getOutputStream())
            val request = readRequest(input) ?: return
            if (!request.path.startsWith("/stream")) {
                writeStatus(output, 404, "Not Found", 0)
                return
            }
            val (start, end) = parseRange(request.rangeHeader, fileSize)
            val length = end - start + 1
            if (request.method == "HEAD") {
                writeHeaders(output, start, end, length, headOnly = true)
                output.flush()
                return
            }
            val gen = generation.incrementAndGet()
            // Container index reads (MKV cues / MP4 moov at the end, while the
            // player opens the file) are not where playback is, so they don't
            // move the download. Later reads there are real seeks (credits).
            val tail = start >= fileSize - TAIL_BYTES &&
                System.currentTimeMillis() - startedAtMs < INDEX_READ_MS
            if (!tail) noteJump(start)
            writeHeaders(output, start, end, length, headOnly = false)
            streamRange(output, start, end, gen, tail)
            output.flush()
        } catch (t: Throwable) {
            Log.w(TAG, "client error: ${t.message}")
            // Reset, not a clean close: a response cut short with a normal
            // close reads as end of file to the player (a false "ended").
            runCatching { socket.setSoLinger(true, 0) }
        } finally {
            runCatching { socket.close() }
        }
    }

    /**
     * A request far from where the player was reading is a seek. Its byte is
     * exact, unlike a guess from position / duration, so the download window
     * jumps straight there.
     */
    private fun noteJump(start: Long) {
        val prev = servedPos
        // The player re-reads the file head while opening: not a seek, and
        // moving the window there would drop the real one.
        if (start < JUMP_BYTES) return
        val jumped = prev < 0 || kotlin.math.abs(start - prev) > JUMP_BYTES
        if (!jumped) return
        val g = geometry() ?: return
        val piece = ((g.fileOffset + start) / g.pieceLength).toInt().coerceAtMost(g.lastPiece)
        AppLog.i(TAG, "seek detected ${prev / 1048576}MB -> ${start / 1048576}MB (piece $piece)")
        lastReadPiece = piece
        runCatching { onSeek(piece) }
    }

    private fun streamRange(output: OutputStream, start: Long, end: Long, gen: Long, tail: Boolean) {
        var pos = start
        val buf = ByteArray(256 * 1024)
        RandomAccessFile(file, "r").use { raf ->
            while (pos <= end && running.get()) {
                if (gen != generation.get()) throw IOException("superseded by a newer request")
                // Throws if the bytes never arrive — closing the connection lets the
                // player retry instead of decoding the zeros of a sparse file.
                val chunkEnd = min(pos + buf.size - 1, end)
                if (!waitForBytes(pos, chunkEnd, gen)) {
                    throw IOException("pieces for bytes $pos.. not available yet")
                }
                raf.seek(pos)
                val want = (chunkEnd - pos + 1).toInt()
                val got = raf.read(buf, 0, want)
                if (got <= 0) {
                    // File still growing — brief wait then retry.
                    Thread.sleep(80)
                    continue
                }
                output.write(buf, 0, got)
                pos += got
                if (!tail) servedPos = pos
            }
        }
    }

    private fun geometry(): Geometry? {
        geometry?.let { return it }
        val handle = handleProvider()?.takeIf { it.isValid } ?: return null
        // torrentFile() copies the whole torrent info over JNI: read it once,
        // not on every chunk (that was a steady GC load during playback).
        val info = runCatching { handle.torrentFile() }.getOrNull() ?: return null
        val pieceLength = info.pieceLength().toLong().coerceAtLeast(1)
        val offset = info.files().fileOffset(fileIndex)
        val g = Geometry(pieceLength, offset, ((offset + fileSize - 1) / pieceLength).toInt())
        geometry = g
        return g
    }

    /** @return true when every piece covering [start]..[end] is on disk. */
    private fun waitForBytes(start: Long, end: Long, gen: Long): Boolean {
        val g = geometry() ?: return false
        val first = ((g.fileOffset + start) / g.pieceLength).toInt()
        val last = ((g.fileOffset + end) / g.pieceLength).toInt().coerceAtMost(g.lastPiece)
        if (first != lastReadPiece) {
            lastReadPiece = first
            runCatching { onReadPiece(first) }
        }
        val waitStart = System.currentTimeMillis()
        val abortAt = abortWaits.get()
        val deadline = waitStart + 120_000L
        var nextUrge = 0L
        while (System.currentTimeMillis() < deadline && running.get()) {
            if (gen != generation.get() || abortWaits.get() != abortAt) return false
            val live = handleProvider()?.takeIf { it.isValid } ?: return false
            var missing = false
            val now = System.currentTimeMillis()
            val urge = now >= nextUrge
            for (p in first..last) {
                // Default false — sparse/preallocated files look "present" on disk
                // even when the piece hasn't arrived; never treat a failed probe as had.
                if (runCatching { live.havePiece(p) }.getOrDefault(false)) continue
                missing = true
                // The player is blocked on this piece: make it the most urgent.
                // Re-assert every 2 s, not every poll (each priority change
                // re-sorts libtorrent's piece picker).
                if (urge) {
                    runCatching {
                        live.setPieceDeadline(p, 0)
                        live.piecePriority(p, org.libtorrent4j.Priority.TOP_PRIORITY)
                    }
                }
            }
            if (!missing) {
                val waited = now - waitStart
                if (waited >= 1_000L) AppLog.i(TAG, "player waited ${waited}ms for piece $first")
                return true
            }
            if (urge) nextUrge = now + 2_000L
            // Short sleep — the player is blocked on this read; wake ASAP when pieces land.
            Thread.sleep(40)
        }
        return false
    }

    private fun writeHeaders(
        out: OutputStream,
        start: Long,
        end: Long,
        length: Long,
        headOnly: Boolean,
    ) {
        val status = if (start == 0L && end == fileSize - 1) {
            "HTTP/1.1 200 OK\r\n"
        } else {
            "HTTP/1.1 206 Partial Content\r\n"
        }
        val sb = StringBuilder()
        sb.append(status)
        sb.append("Content-Type: ${contentTypeFor(file)}\r\n")
        sb.append("Accept-Ranges: bytes\r\n")
        sb.append("Content-Length: $length\r\n")
        if (start != 0L || end != fileSize - 1) {
            sb.append("Content-Range: bytes $start-$end/$fileSize\r\n")
        }
        sb.append("Connection: close\r\n")
        sb.append("\r\n")
        out.write(sb.toString().toByteArray(Charsets.US_ASCII))
        if (headOnly) out.flush()
    }

    private fun contentTypeFor(f: File): String {
        return when (f.name.substringAfterLast('.', "").lowercase()) {
            "mkv", "webm" -> "video/x-matroska"
            "mp4", "m4v", "mov" -> "video/mp4"
            "avi" -> "video/x-msvideo"
            "ts", "m2ts", "mts" -> "video/mp2t"
            "mpeg", "mpg", "vob" -> "video/mpeg"
            "flv" -> "video/x-flv"
            "ogv" -> "video/ogg"
            "wmv" -> "video/x-ms-wmv"
            else -> "video/mp4"
        }
    }

    private fun writeStatus(out: OutputStream, code: Int, msg: String, length: Int) {
        val body = msg.toByteArray()
        out.write("HTTP/1.1 $code $msg\r\nContent-Length: ${body.size}\r\nConnection: close\r\n\r\n".toByteArray())
        out.write(body)
        out.flush()
    }

    private data class Request(val method: String, val path: String, val rangeHeader: String?)

    private fun readRequest(input: InputStream): Request? {
        val lines = ArrayList<String>()
        val buf = StringBuilder()
        while (true) {
            val c = input.read()
            if (c < 0) break
            if (c == '\n'.code) {
                var line = buf.toString()
                if (line.endsWith("\r")) line = line.dropLast(1)
                buf.setLength(0)
                if (line.isEmpty()) break
                lines.add(line)
                if (lines.size > 64) break
            } else {
                buf.append(c.toChar())
            }
        }
        if (lines.isEmpty()) return null
        val parts = lines[0].split(' ')
        if (parts.size < 2) return null
        val range = lines.firstOrNull { it.startsWith("Range:", ignoreCase = true) }
            ?.substringAfter(':')?.trim()
        return Request(parts[0].uppercase(), parts[1], range)
    }

    private fun parseRange(header: String?, size: Long): Pair<Long, Long> {
        if (size <= 0) return 0L to 0L
        // No Range (the player's first request at byte 0) → the whole file,
        // streamed as pieces arrive. Answering with only 2 MB looked like a
        // 2 MB file to the player.
        val whole = 0L to (size - 1)
        if (header.isNullOrBlank() || !header.startsWith("bytes=")) return whole
        val spec = header.removePrefix("bytes=").substringBefore(',').trim()
        val dash = spec.indexOf('-')
        if (dash < 0) return whole
        val startStr = spec.substring(0, dash)
        val endStr = spec.substring(dash + 1)
        return try {
            when {
                startStr.isEmpty() && endStr.isNotEmpty() -> {
                    val suffix = endStr.toLong()
                    val start = (size - suffix).coerceAtLeast(0)
                    start to (size - 1)
                }
                startStr.isNotEmpty() && endStr.isEmpty() -> {
                    // Serve to the end of the file. Capping this at 8 MB made
                    // the player read a "short" file: it hit a false end of
                    // stream every 8 MB (the "Reconnecting…" stops) and closed
                    // the movie after a few of them.
                    startStr.toLong().coerceIn(0, size - 1) to (size - 1)
                }
                else -> {
                    val start = startStr.toLong().coerceIn(0, size - 1)
                    val end = endStr.toLong().coerceIn(start, size - 1)
                    start to end
                }
            }
        } catch (_: Exception) {
            whole
        }
    }

    companion object {
        private const val TAG = "StreamHttp"
        private const val TAIL_BYTES = 16L * 1024 * 1024
        private const val JUMP_BYTES = 8L * 1024 * 1024
        /** Index reads at the file's end happen while the player opens it. */
        private const val INDEX_READ_MS = 20_000L
    }
}
