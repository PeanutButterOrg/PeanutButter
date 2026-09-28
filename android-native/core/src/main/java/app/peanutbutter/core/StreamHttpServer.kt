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
) {
    private val running = AtomicBoolean(false)
    private var serverSocket: ServerSocket? = null
    private val pool = Executors.newCachedThreadPool()

    @Volatile
    var url: String = ""
        private set

    fun start() {
        if (running.getAndSet(true)) return
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
            writeHeaders(output, start, end, length, headOnly = false)
            streamRange(output, start, end)
            output.flush()
        } catch (t: Throwable) {
            Log.w(TAG, "client error: ${t.message}")
        } finally {
            runCatching { socket.close() }
        }
    }

    private fun streamRange(output: OutputStream, start: Long, end: Long) {
        var pos = start
        val buf = ByteArray(64 * 1024)
        RandomAccessFile(file, "r").use { raf ->
            while (pos <= end && running.get()) {
                waitForBytes(pos, min(pos + buf.size - 1, end))
                raf.seek(pos)
                val want = min(buf.size.toLong(), end - pos + 1).toInt()
                val got = raf.read(buf, 0, want)
                if (got <= 0) {
                    // File still growing — brief wait then retry.
                    Thread.sleep(80)
                    continue
                }
                output.write(buf, 0, got)
                pos += got
            }
        }
    }

    private fun waitForBytes(start: Long, end: Long) {
        val handle = handleProvider()?.takeIf { it.isValid } ?: return
        val info = runCatching { handle.torrentFile() }.getOrNull() ?: return
        val pieceLength = info.pieceLength().coerceAtLeast(1)
        val fs = info.files()
        val fileOffset = fs.fileOffset(fileIndex)
        val first = ((fileOffset + start) / pieceLength).toInt()
        val last = ((fileOffset + end) / pieceLength).toInt()
        val deadline = System.currentTimeMillis() + 45_000L
        while (System.currentTimeMillis() < deadline && running.get()) {
            val live = handleProvider()?.takeIf { it.isValid } ?: break
            var missing = false
            for (p in first..last) {
                if (!runCatching { live.havePiece(p) }.getOrDefault(true)) {
                    missing = true
                    runCatching {
                        live.setPieceDeadline(p, 50)
                        live.piecePriority(p, org.libtorrent4j.Priority.TOP_PRIORITY)
                    }
                }
            }
            if (!missing) return
            // Also accept if the on-disk file already covers the range.
            if (file.exists() && file.length() > end) return
            Thread.sleep(100)
        }
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
        sb.append("Content-Type: video/mp4\r\n")
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
        if (header.isNullOrBlank() || !header.startsWith("bytes=")) {
            return 0L to (size - 1)
        }
        val spec = header.removePrefix("bytes=").substringBefore(',').trim()
        val dash = spec.indexOf('-')
        if (dash < 0) return 0L to (size - 1)
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
                    val start = startStr.toLong().coerceIn(0, size - 1)
                    start to (size - 1)
                }
                else -> {
                    val start = startStr.toLong().coerceIn(0, size - 1)
                    val end = endStr.toLong().coerceIn(start, size - 1)
                    start to end
                }
            }
        } catch (_: Exception) {
            0L to (size - 1)
        }
    }

    companion object {
        private const val TAG = "StreamHttp"
    }
}
