package app.peanutbutter.tv.player

import android.os.Handler
import android.os.Looper
import androidx.media3.common.text.Cue
import androidx.media3.ui.SubtitleView
import java.io.File

/**
 * Sideloaded SRT/VTT cues drawn on [SubtitleView] from the playhead clock.
 * Avoids ExoPlayer [setMediaItem] remounts (which kill progressive torrent streams
 * and drop captions after a flash).
 */
class SrtOverlay {
    data class TimedCue(val startMs: Long, val endMs: Long, val text: String)

    private val main = Handler(Looper.getMainLooper())
    private var cues: List<TimedCue> = emptyList()
    private var label: String = "Subtitle"
    private var view: SubtitleView? = null
    private var positionProvider: (() -> Long)? = null
    private var lastText: String? = null
    var active: Boolean = false
        private set

    private val tick = object : Runnable {
        override fun run() {
            if (!active) return
            paint()
            main.postDelayed(this, 200L)
        }
    }

    fun bind(view: SubtitleView?, positionProvider: () -> Long) {
        this.view = view
        this.positionProvider = positionProvider
    }

    fun load(file: File, label: String) {
        val text = runCatching { file.readText(Charsets.UTF_8) }.getOrElse {
            runCatching { file.readText(Charsets.ISO_8859_1) }.getOrDefault("")
        }
        cues = parse(text)
        this.label = label.ifBlank { file.name }
        active = cues.isNotEmpty()
        lastText = null
        main.removeCallbacks(tick)
        if (active) {
            paint()
            main.post(tick)
        } else {
            view?.setCues(emptyList())
        }
    }

    fun clear() {
        active = false
        cues = emptyList()
        label = "Subtitle"
        lastText = null
        main.removeCallbacks(tick)
        view?.setCues(emptyList())
    }

    fun listEntry(): Pair<String, String>? =
        if (active) "ext:sideload" to label else null

    fun selectExternal() {
        if (!active) return
        lastText = null
        paint()
        main.removeCallbacks(tick)
        main.post(tick)
    }

    private fun paint() {
        val pos = positionProvider?.invoke() ?: return
        val text = cues
            .asSequence()
            .filter { pos >= it.startMs && pos < it.endMs }
            .joinToString("\n") { it.text }
            .trim()
        if (text == lastText) return
        lastText = text
        val v = view ?: return
        if (text.isEmpty()) {
            v.setCues(emptyList())
        } else {
            v.setCues(listOf(Cue.Builder().setText(text).build()))
        }
    }

    companion object {
        fun parse(raw: String): List<TimedCue> {
            val normalized = raw.replace("\r\n", "\n").replace('\r', '\n').trim()
            if (normalized.isEmpty()) return emptyList()
            val body = if (normalized.startsWith("WEBVTT", ignoreCase = true)) {
                normalized.substringAfter('\n')
            } else {
                normalized
            }
            val blocks = body.split(Regex("\n{2,}"))
            val out = ArrayList<TimedCue>(blocks.size)
            val timeLine = Regex(
                """(\d{1,2}:)?(\d{1,2}):(\d{1,2})[.,](\d{1,3})\s*-->\s*(\d{1,2}:)?(\d{1,2}):(\d{1,2})[.,](\d{1,3})""",
            )
            for (block in blocks) {
                val lines = block.lines().map { it.trimEnd() }.filter { it.isNotBlank() }
                if (lines.isEmpty()) continue
                var idx = 0
                if (lines[0].all { it.isDigit() } && lines.size > 1) idx = 1
                if (idx >= lines.size) continue
                val match = timeLine.find(lines[idx]) ?: continue
                val start = toMs(match.groupValues[1], match.groupValues[2], match.groupValues[3], match.groupValues[4])
                val end = toMs(match.groupValues[5], match.groupValues[6], match.groupValues[7], match.groupValues[8])
                if (end <= start) continue
                val text = lines.drop(idx + 1)
                    .joinToString("\n")
                    .replace(Regex("<[^>]+>"), "")
                    .trim()
                if (text.isEmpty()) continue
                out += TimedCue(start, end, text)
            }
            return out
        }

        private fun toMs(hPrefix: String, m: String, s: String, frac: String): Long {
            val h = hPrefix.trimEnd(':').toLongOrNull() ?: 0L
            val mm = m.toLongOrNull() ?: 0L
            val ss = s.toLongOrNull() ?: 0L
            val ms = frac.padEnd(3, '0').take(3).toLongOrNull() ?: 0L
            return ((h * 3600) + (mm * 60) + ss) * 1000 + ms
        }
    }
}
