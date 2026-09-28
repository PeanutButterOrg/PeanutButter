package app.peanutbutter.core

import android.content.Context
import java.io.File

/** Deletes on-device streamed pieces and player cache. Does not touch preferences. */
object StreamDownloads {
    fun wipe(context: Context) {
        LocalTorrentEngine.purge(context)
    }

    /** Player / Exo caches only — used after torrent purge. */
    fun wipePlayerCaches(context: Context) {
        val app = context.applicationContext
        val targets = listOfNotNull(
            File(app.cacheDir, "exoplayer"),
            File(app.filesDir, "streams"),
            File(app.filesDir, "torrents"),
            app.externalCacheDir,
        )
        val seen = HashSet<String>()
        for (dir in targets) {
            if (!seen.add(dir.absolutePath)) continue
            wipeTree(dir)
        }
        // Wipe loose files under cache except keep pb-streams root for recreation.
        app.cacheDir.listFiles()?.forEach { child ->
            if (child.name == "pb-streams") return@forEach
            if (child.isDirectory) wipeTree(child) else child.delete()
        }
    }

    private fun wipeTree(dir: File) {
        if (!dir.exists()) return
        dir.listFiles()?.forEach { child ->
            if (child.isDirectory) wipeTree(child)
            child.delete()
        }
        if (dir.name != "cache") dir.delete()
    }
}
