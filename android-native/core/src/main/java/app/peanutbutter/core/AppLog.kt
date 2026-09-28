package app.peanutbutter.core

import android.content.Context
import android.util.Log
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/** App-private crash/debug log — system logcat is empty on some TV boxes. */
object AppLog {
    private const val TAG = "PeanutButter"
    private val fmt = SimpleDateFormat("HH:mm:ss.SSS", Locale.US)
    @Volatile private var file: File? = null

    fun init(context: Context) {
        if (file != null) return
        // filesDir — cacheDir is wiped on stream purge / app exit.
        val dir = File(context.applicationContext.filesDir, "logs").apply { mkdirs() }
        file = File(dir, "pb-debug.log")
        i("AppLog", "---- session ${Date()} ----")
    }

    fun i(tag: String, msg: String) = write("I", tag, msg, null)
    fun e(tag: String, msg: String, t: Throwable? = null) = write("E", tag, msg, t)

    fun dump(context: Context): String {
        init(context)
        return runCatching { file?.readText().orEmpty() }.getOrDefault("")
    }

    fun clear(context: Context) {
        init(context)
        runCatching { file?.writeText("") }
    }

    @Synchronized
    private fun write(level: String, tag: String, msg: String, t: Throwable?) {
        val line = "${fmt.format(Date())} $level/$tag: $msg"
        when (level) {
            "E" -> if (t != null) Log.e(TAG, "$tag: $msg", t) else Log.e(TAG, "$tag: $msg")
            else -> Log.i(TAG, "$tag: $msg")
        }
        runCatching {
            val f = file ?: return
            f.appendText(line + "\n")
            if (t != null) f.appendText(Log.getStackTraceString(t) + "\n")
            if (f.length() > 256 * 1024) {
                val keep = f.readText().takeLast(128 * 1024)
                f.writeText(keep)
            }
        }
    }
}
