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
    /**
     * One cue: [text] without tags; [markup] keeps the <i>/<b>/<u> tags for
     * drawing; [align] is the {\anN} numpad spot (2: bottom centre, 8: top).
     */
    data class TimedCue(
        val startMs: Long,
        val endMs: Long,
        val text: String,
        val markup: String = text,
        val align: Int = 2,
    ) {
        val atBottom: Boolean get() = align in 1..3
    }

    private val main = Handler(Looper.getMainLooper())
    private var cues: List<TimedCue> = emptyList()
    private var label: String = "Subtitle"
    private var view: SubtitleView? = null
    private var positionProvider: (() -> Long)? = null
    /** What's on screen now, to skip repainting the same cues. */
    private var lastText: String? = null
    /** Draws the text instead of the SubtitleView when set (see TvPlayback.onTextCues). */
    var sink: ((androidx.compose.ui.text.AnnotatedString) -> Unit)? = null
    var active: Boolean = false
        private set

    /** Shifts the cues: positive shows them later. */
    var delayMs: Long = 0
        set(value) {
            field = value
            lastText = null
            if (active) paint()
        }

    /**
     * Gap under the text as a share of the view's height, like the view's own
     * bottom padding (which skips cues that set their own line).
     */
    var bottomFraction: Float = 0.10f
        set(value) {
            if (field == value) return
            field = value
            lastText = null
            if (active) paint()
        }

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

    /** Stop showing it, but keep it in the menu so it can be picked again. */
    fun deselect() {
        active = false
        lastText = null
        main.removeCallbacks(tick)
        view?.setCues(emptyList())
        sink?.invoke(androidx.compose.ui.text.AnnotatedString(""))
    }

    fun clear() {
        deselect()
        cues = emptyList()
        label = "Subtitle"
    }

    fun listEntry(): Pair<String, String>? =
        if (cues.isNotEmpty()) "ext:sideload" to label else null

    fun selectExternal() {
        if (cues.isEmpty()) return
        active = true
        lastText = null
        paint()
        main.removeCallbacks(tick)
        main.post(tick)
    }

    private fun paint() {
        val pos = (positionProvider?.invoke() ?: return) - delayMs
        val now = cues.filter { pos >= it.startMs && pos < it.endMs }
        val key = now.joinToString("\u0000") { "${it.align}|${it.markup}" }
        if (key == lastText) return
        lastText = key
        // Lines meant for elsewhere (a {\an8} sign at the top) keep their
        // spot on the SubtitleView; the usual bottom lines keep their
        // italics and bold, in the chosen look when there's a sink.
        val (bottom, placed) = now.partition { it.atBottom }
        val bottomText = styledLines(bottom.map(::styled))
        val placedCues = placed.map(::placedCue)
        sink?.let {
            view?.setCues(placedCues)
            it(bottomText)
            return
        }
        val v = view ?: return
        val bottomCues = if (bottom.isEmpty()) {
            emptyList()
        } else {
            // Explicit line near the bottom: default placement can land mid-frame on TV.
            listOf(
                Cue.Builder()
                    .setText(styledSpanned(bottom))
                    .setLine(1f - bottomFraction, Cue.LINE_TYPE_FRACTION)
                    .setLineAnchor(Cue.ANCHOR_TYPE_END)
                    .setPosition(0.5f)
                    .setPositionAnchor(Cue.ANCHOR_TYPE_MIDDLE)
                    .setTextAlignment(android.text.Layout.Alignment.ALIGN_CENTER)
                    .build(),
            )
        }
        v.setCues(bottomCues + placedCues)
    }

    private fun styled(cue: TimedCue): CharSequence =
        android.text.Html.fromHtml(cue.markup.replace("\n", "<br>"), android.text.Html.FROM_HTML_MODE_LEGACY)

    private fun styledSpanned(cues: List<TimedCue>): CharSequence {
        val out = android.text.SpannableStringBuilder()
        cues.forEachIndexed { i, c ->
            if (i > 0) out.append('\n')
            out.append(styled(c).trim())
        }
        return out
    }

    /** A cue at its {\anN} spot: 7–9 top, 4–6 middle; left, centre or right by column. */
    private fun placedCue(c: TimedCue): Cue {
        val (line, lineAnchor) = if (c.align >= 7) 0.06f to Cue.ANCHOR_TYPE_START else 0.5f to Cue.ANCHOR_TYPE_MIDDLE
        val (position, positionAnchor, alignment) = when (c.align % 3) {
            1 -> Triple(0.05f, Cue.ANCHOR_TYPE_START, android.text.Layout.Alignment.ALIGN_NORMAL)
            0 -> Triple(0.95f, Cue.ANCHOR_TYPE_END, android.text.Layout.Alignment.ALIGN_OPPOSITE)
            else -> Triple(0.5f, Cue.ANCHOR_TYPE_MIDDLE, android.text.Layout.Alignment.ALIGN_CENTER)
        }
        return Cue.Builder()
            .setText(styled(c).trim())
            .setLine(line, Cue.LINE_TYPE_FRACTION)
            .setLineAnchor(lineAnchor)
            .setPosition(position)
            .setPositionAnchor(positionAnchor)
            .setTextAlignment(alignment)
            .build()
    }

    companion object {
        fun parse(raw: String): List<TimedCue> {
            val normalized = raw.removePrefix("\uFEFF").replace("\r\n", "\n").replace('\r', '\n').trim()
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
                val raw = lines.drop(idx + 1).joinToString("\n")
                val align = Regex("""\{\\an([1-9])\}""").find(raw)?.groupValues?.get(1)?.toInt() ?: 2
                // {\...} override tags aren't text; <i>/<b>/<u> stay for drawing.
                val markup = raw.replace(Regex("""\{\\[^}]*\}"""), "").trim()
                val text = markup.replace(Regex("<[^>]+>"), "").trim()
                if (text.isEmpty()) continue
                out += TimedCue(start, end, text, markup, align)
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
