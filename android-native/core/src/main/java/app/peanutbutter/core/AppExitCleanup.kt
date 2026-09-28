package app.peanutbutter.core

import android.app.Application
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.ProcessLifecycleOwner

/** When the app leaves the foreground / starts, optionally wipe stream cache. */
object AppExitCleanup {
    fun install(app: Application, shouldWipe: () -> Boolean, onExit: (deleteFiles: Boolean) -> Unit) {
        // Cold start: only wipe leftover pieces when the user opted into clear-on-exit.
        if (shouldWipe()) {
            runCatching { LocalTorrentEngine.purge(app) }
        }

        ProcessLifecycleOwner.get().lifecycle.addObserver(object : DefaultLifecycleObserver {
            override fun onStop(owner: LifecycleOwner) {
                val wipe = shouldWipe()
                onExit(wipe)
                if (wipe) {
                    runCatching { StreamDownloads.wipe(app) }
                }
            }
        })
    }
}
