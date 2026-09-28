package app.peanutbutter.core

import android.content.Context
import java.io.File

/** Deletes on-device streamed pieces and player cache. Does not touch preferences. */
object StreamDownloads {
    fun wipe(context: Context) {
        val app = context.applicationContext
        val targets = listOfNotNull(
            File(app.cacheDir, "pb-streams"),
            File(app.cacheDir, "exoplayer"),
            File(app.filesDir, "pb-streams"),
            File(app.filesDir, "streams"),
            File(app.filesDir, "torrents"),
            app.externalCacheDir?.let { File(it, "pb-streams") },
            app.externalCacheDir,
            app.cacheDir,
        )
        val seen = HashSet<String>()
        for (dir in targets) {
            if (!seen.add(dir.absolutePath)) continue
            wipeTree(dir)
        }
    }

    private fun wipeTree(dir: File) {
        if (!dir.exists()) return
        dir.listFiles()?.forEach { child ->
            if (child.isDirectory) wipeTree(child)
            child.delete()
        }
        // Keep the cache root itself; Android recreates it. Nested folders are removed.
        if (dir.name != "cache") dir.delete()
    }
}
