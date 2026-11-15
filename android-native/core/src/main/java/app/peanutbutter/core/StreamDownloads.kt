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
        // Other player leftovers under cache. Keep pb-streams (recreated by
        // the engine), the poster image cache and a downloaded app update:
        // wiping those made every launch re-download all posters, and deleted
        // the update while Android's installer was open (leaving the app
        // counts as exit), so Install downloaded it again.
        app.cacheDir.listFiles()?.forEach { child ->
            if (child.name in KEEP_IN_CACHE) return@forEach
            if (child.isDirectory) wipeTree(child) else child.delete()
        }
    }

    /** Cache folders that aren't stream data (Glide's "pb_img", app updates). */
    private val KEEP_IN_CACHE = setOf("pb-streams", "pb_img", "updates")

    private fun wipeTree(dir: File) {
        if (!dir.exists()) return
        dir.listFiles()?.forEach { child ->
            if (child.isDirectory) wipeTree(child)
            child.delete()
        }
        if (dir.name != "cache") dir.delete()
    }
}
