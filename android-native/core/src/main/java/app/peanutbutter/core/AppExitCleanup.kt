package app.peanutbutter.core

import android.app.Application
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.ProcessLifecycleOwner

/** When the app leaves the foreground, stop the live stream and optionally wipe downloads. */
object AppExitCleanup {
    fun install(app: Application, shouldWipe: () -> Boolean = { true }, onExit: () -> Unit) {
        ProcessLifecycleOwner.get().lifecycle.addObserver(object : DefaultLifecycleObserver {
            override fun onStop(owner: LifecycleOwner) {
                onExit()
                if (shouldWipe()) StreamDownloads.wipe(app)
            }
        })
    }
}
