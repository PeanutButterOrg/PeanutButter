package app.peanutbutter.core

import android.system.Os
import java.io.File

/**
 * Keeps streamed episodes from filling the device. Pieces stay on disk for fast
 * resume, but nothing ever removed them unless "Clear cache on exit" was on, so a
 * TV eventually had no room left even to install an update.
 */
internal object DownloadBudget {
    data class Entry(val name: String, val bytes: Long, val lastUsedMs: Long)

    private const val MAX_BYTES = 10L * 1024 * 1024 * 1024
    private const val KEEP_FREE_BYTES = 2L * 1024 * 1024 * 1024

    /** At most 10 GB or 40% of the disk, less if the disk itself is nearly full. */
    fun budget(totalDisk: Long, freeDisk: Long, usedByDownloads: Long): Long {
        val allowed = minOf(MAX_BYTES, totalDisk * 4 / 10)
        val shortfall = (KEEP_FREE_BYTES - freeDisk).coerceAtLeast(0)
        if (shortfall == 0L) return allowed
        return minOf(allowed, usedByDownloads - shortfall).coerceAtLeast(0)
    }

    /** Oldest first, until what's left fits. */
    fun toDelete(entries: List<Entry>, budget: Long): List<Entry> {
        var used = entries.sumOf { it.bytes }
        val out = ArrayList<Entry>()
        for (e in entries.sortedBy { it.lastUsedMs }) {
            if (used <= budget) break
            out += e
            used -= e.bytes
        }
        return out
    }

    /** Run while no torrent is active. */
    fun trim(dir: File) {
        val children = dir.listFiles() ?: return
        val stats = children.map { it to measure(it) }
        val used = stats.sumOf { it.second.first }
        val budget = budget(dir.totalSpace, dir.usableSpace, used)
        val entries = stats.map { (f, m) -> Entry(f.name, m.first, m.second) }
        for (e in toDelete(entries, budget)) {
            AppLog.i("DownloadBudget", "removing old download ${e.name} (${e.bytes / 1048576} MB)")
            File(dir, e.name).deleteRecursively()
        }
    }

    /** Bytes really on disk (torrent files are sparse) and the newest change. */
    private fun measure(f: File): Pair<Long, Long> {
        var bytes = 0L
        var newest = f.lastModified()
        f.walkTopDown().filter { it.isFile }.forEach {
            bytes += runCatching { Os.stat(it.path).st_blocks * 512 }.getOrDefault(it.length())
            newest = maxOf(newest, it.lastModified())
        }
        return bytes to newest
    }
}
