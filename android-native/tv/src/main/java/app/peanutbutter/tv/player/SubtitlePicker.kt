package app.peanutbutter.tv.player

import android.app.AlertDialog
import app.peanutbutter.tv.ui.showRoundListDialog
import android.text.InputType
import android.view.inputmethod.EditorInfo
import android.view.ViewGroup
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import androidx.fragment.app.FragmentActivity
import androidx.lifecycle.lifecycleScope
import androidx.media3.common.MimeTypes
import app.peanutbutter.core.ApiClient
import app.peanutbutter.core.SubtitleHit
import app.peanutbutter.tv.R
import app.peanutbutter.tv.ui.closeKeyboardOnIme
import app.peanutbutter.tv.ui.hideKeyboard
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import java.io.File

/** Player caption menu: embedded tracks, OpenSubtitles, Wyzie (lazy download), or a link. */
class SubtitlePicker(
    private val activity: FragmentActivity,
    private val player: () -> PlaybackEngine?,
    private val api: ApiClient,
    private val titleId: () -> String?,
    private val season: () -> Int?,
    private val episode: () -> Int?,
    private val languages: () -> Set<String>,
    /** This video's subtitle delay, kept by the player between menu opens. */
    private val delayMs: () -> Long = { 0L },
    private val setDelayMs: (Long) -> Unit = {},
) {
    fun show() {
        activity.lifecycleScope.launch {
            // The menu mostly lists local tracks; a slow server must not hold it back.
            val info = withTimeoutOrNull(3_000L) {
                withContext(Dispatchers.IO) { runCatching { api.serverInfo() }.getOrNull() }
            }
            val tracks = player()?.listTextTracks().orEmpty()
            val langs = app.peanutbutter.core.ContentLanguages.subtitleLanguages(languages())
            val options = ArrayList<Pair<String, () -> Unit>>()
            // As on desktop: the look (size, background, delay) comes first.
            options += activity.getString(R.string.subs_style) to { showStyle() }
            options += activity.getString(R.string.subs_off) to { player()?.selectTextTrack(null) }
            tracks.forEach { (id, label) ->
                options += label to { player()?.selectTextTrack(id) }
            }
            val current = player()?.selectedTextTrackId
            val checked = 1 + if (current == null) 0 else tracks.indexOfFirst { it.first == current } + 1
            val subsReady = info?.subtitlesConfigured == true ||
                info?.opensubtitlesConfigured == true ||
                info?.wyzieConfigured == true
            if (subsReady) {
                if (info?.wyzieConfigured == true) {
                    // One search per language (it used to be the first only).
                    langs.forEach { code ->
                        options += activity.getString(R.string.subs_search_wyzie, code.uppercase()) to {
                            searchWyzie(code)
                        }
                    }
                }
                if (info?.opensubtitlesConfigured == true) {
                    langs.forEach { code ->
                        val label = activity.getString(R.string.subs_download, code.uppercase())
                        options += label to { fetchOpenSubtitles(code) }
                    }
                }
            } else if (info != null) {
                options += activity.getString(R.string.subs_add_key) to { promptKey() }
            }
            options += activity.getString(R.string.subs_from_link) to { promptLink() }
            showList(activity.getString(R.string.subs_title), options, checked)
        }
    }

    /** Size, Background and Delay, each a row of chips in the app's panel. */
    private fun showStyle() {
        val view = android.view.LayoutInflater.from(activity).inflate(R.layout.dialog_list, null)
        view.findViewById<TextView>(R.id.dialog_title).text = activity.getString(R.string.subs_style_title)
        val list = view.findViewById<LinearLayout>(R.id.dialog_list)
        val done = view.findViewById<TextView>(R.id.dialog_negative)
        done.setText(R.string.done)
        val density = activity.resources.displayMetrics.density
        fun dp(v: Int) = (v * density).toInt()
        fun label(text: Int) = TextView(activity).apply {
            setText(text)
            textSize = 12f
            letterSpacing = 0.1f
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            setTextColor(activity.getColor(R.color.pbt_text_faint))
            setPadding(0, dp(10), 0, dp(6))
        }
        fun chip(text: String, textSp: Float = 15f) = TextView(activity).apply {
            this.text = text
            textSize = textSp
            gravity = android.view.Gravity.CENTER
            isFocusable = true
            isFocusableInTouchMode = true
            setBackgroundResource(R.drawable.choice_chip)
            minWidth = dp(64)
            setPadding(dp(14), 0, dp(14), 0)
        }
        fun row(chips: List<TextView>): LinearLayout = LinearLayout(activity).apply {
            orientation = LinearLayout.HORIZONTAL
            chips.forEachIndexed { i, c ->
                addView(c, LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, dp(40)).apply {
                    if (i > 0) marginStart = dp(8)
                })
            }
        }
        fun paint(chips: List<TextView>, picked: Int) = chips.forEachIndexed { i, c ->
            c.isSelected = i == picked
            c.setTextColor(activity.getColor(if (i == picked) R.color.pbt_on_primary else R.color.pbt_text))
        }

        val sizeChips = (0 until 4).map { chip("A", 13f + it * 3) }
        val bgKeys = listOf("shadow", "outline", "box")
        val bgChips = listOf(R.string.subs_bg_shadow, R.string.subs_bg_outline, R.string.subs_bg_box)
            .map { chip(activity.getString(it)) }
        paint(sizeChips, SubtitleLook.size(activity))
        paint(bgChips, bgKeys.indexOf(SubtitleLook.background(activity)).coerceAtLeast(0))
        sizeChips.forEachIndexed { i, c ->
            c.setOnClickListener {
                SubtitleLook.save(activity, size = i)
                paint(sizeChips, i)
                SubtitleLook.apply(activity, player())
            }
        }
        bgChips.forEachIndexed { i, c ->
            c.setOnClickListener {
                SubtitleLook.save(activity, background = bgKeys[i])
                paint(bgChips, i)
                SubtitleLook.apply(activity, player())
            }
        }
        list.addView(label(R.string.subs_size))
        list.addView(row(sizeChips))
        list.addView(label(R.string.subs_background))
        list.addView(row(bgChips))
        if (player()?.canDelaySubtitles == true) {
            val value = TextView(activity).apply {
                gravity = android.view.Gravity.CENTER
                textSize = 15f
                setTextColor(activity.getColor(R.color.pbt_text))
                minWidth = dp(96)
            }
            fun show() {
                value.text = String.format(java.util.Locale.US, "%.1f s", delayMs() / 1000.0)
            }
            fun step(by: Long) {
                val next = delayMs() + by
                setDelayMs(next)
                player()?.setSubtitleDelay(next)
                show()
            }
            val minus = chip("−").apply { setOnClickListener { step(-100) } }
            val plus = chip("+").apply { setOnClickListener { step(100) } }
            show()
            list.addView(label(R.string.subs_delay))
            list.addView(LinearLayout(activity).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = android.view.Gravity.CENTER_VERTICAL
                addView(minus, LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, dp(40)))
                addView(value, LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, dp(40)))
                addView(plus, LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, dp(40)))
            })
        }
        val dialog = AlertDialog.Builder(activity).setView(view).create()
        done.setOnClickListener { dialog.dismiss() }
        dialog.setOnShowListener {
            dialog.window?.setBackgroundDrawable(android.graphics.drawable.ColorDrawable(android.graphics.Color.TRANSPARENT))
            sizeChips[SubtitleLook.size(activity)].requestFocus()
        }
        dialog.show()
        dialog.window?.setBackgroundDrawable(android.graphics.drawable.ColorDrawable(android.graphics.Color.TRANSPARENT))
    }

    private fun searchWyzie(language: String) {
        val id = titleId()?.takeIf { it.isNotBlank() } ?: run {
            toast(activity.getString(R.string.subs_no_title))
            return
        }
        activity.lifecycleScope.launch {
            try {
                val hits = api.searchSubtitles(id, language, season(), episode())
                if (hits.isEmpty()) {
                    toast(activity.getString(R.string.subs_none))
                    return@launch
                }
                val options = hits.map { hit ->
                    hit.label to { downloadHit(hit) }
                }
                showList(activity.getString(R.string.subs_wyzie_results), options)
            } catch (e: Exception) {
                toast(e.message ?: activity.getString(R.string.subs_none))
            }
        }
    }

    private fun downloadHit(hit: SubtitleHit) {
        activity.lifecycleScope.launch {
            try {
                val sub = api.downloadSubtitle(hit)
                if (!sub.content.contains("-->")) {
                    toast(activity.getString(R.string.subs_none))
                    return@launch
                }
                val file = writeSubtitle(sub.label.ifBlank { "${hit.language}.srt" }, sub.content)
                player()?.addExternalSubtitle(
                    file,
                    sub.label.ifBlank { hit.language },
                    mimeFor(file.name, sub.content),
                )
                toast(activity.getString(R.string.subs_added))
            } catch (e: Exception) {
                toast(e.message ?: activity.getString(R.string.subs_none))
            }
        }
    }

    private fun fetchOpenSubtitles(language: String) {
        val id = titleId()?.takeIf { it.isNotBlank() } ?: run {
            toast(activity.getString(R.string.subs_no_title))
            return
        }
        activity.lifecycleScope.launch {
            try {
                val rows = api.fetchSubtitles(id, language, season(), episode())
                val sub = app.peanutbutter.core.FetchedSubtitle.pick(rows, language)
                if (sub == null) {
                    toast(activity.getString(R.string.subs_none))
                    return@launch
                }
                val file = writeSubtitle(sub.label.ifBlank { "$language.srt" }, sub.content)
                player()?.addExternalSubtitle(file, sub.label.ifBlank { language }, mimeFor(file.name, sub.content))
                toast(activity.getString(R.string.subs_added))
            } catch (e: Exception) {
                toast(e.message ?: activity.getString(R.string.subs_none))
            }
        }
    }

    private fun promptKey() {
        val col = LinearLayout(activity).apply {
            orientation = LinearLayout.VERTICAL
            val pad = (18 * resources.displayMetrics.density).toInt()
            setPadding(pad, pad / 2, pad, pad / 2)
        }
        val opensub = EditText(activity).apply {
            hint = activity.getString(R.string.subs_key_hint)
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD
            imeOptions = EditorInfo.IME_ACTION_NEXT
            isFocusable = true
            closeKeyboardOnIme()
        }
        val wyzie = EditText(activity).apply {
            hint = activity.getString(R.string.subs_wyzie_hint)
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD
            imeOptions = EditorInfo.IME_ACTION_DONE
            isFocusable = true
            closeKeyboardOnIme()
            val lp = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT,
            )
            lp.topMargin = (10 * resources.displayMetrics.density).toInt()
            layoutParams = lp
        }
        col.addView(opensub)
        col.addView(wyzie)
        AlertDialog.Builder(activity)
            .setTitle(R.string.subs_key_title)
            .setView(col)
            .setNegativeButton(android.R.string.cancel, null)
            .setPositiveButton(R.string.subs_save) { _, _ ->
                opensub.hideKeyboard()
                wyzie.hideKeyboard()
                val osKey = opensub.text?.toString()?.trim().orEmpty()
                val wyzieKey = wyzie.text?.toString()?.trim().orEmpty()
                if (osKey.isEmpty() && wyzieKey.isEmpty()) return@setPositiveButton
                activity.lifecycleScope.launch {
                    try {
                        api.updateSubtitleKeys(
                            opensubtitlesEnabled = true,
                            opensubtitlesApiKey = osKey.ifBlank { null },
                            wyzieApiKey = wyzieKey.ifBlank { null },
                        )
                        toast(activity.getString(R.string.subs_enabled))
                    } catch (e: Exception) {
                        toast(e.message ?: activity.getString(R.string.error_generic))
                    }
                }
            }
            .show()
        opensub.requestFocus()
    }

    private fun promptLink() {
        val input = EditText(activity).apply {
            hint = "https://…/captions.srt"
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_URI
            imeOptions = EditorInfo.IME_ACTION_DONE
            isFocusable = true
            closeKeyboardOnIme()
        }
        AlertDialog.Builder(activity)
            .setTitle(R.string.subs_from_link)
            .setView(input)
            .setNegativeButton(android.R.string.cancel, null)
            .setPositiveButton(R.string.subs_save) { _, _ ->
                input.hideKeyboard()
                val url = input.text?.toString()?.trim().orEmpty()
                if (!url.startsWith("http://") && !url.startsWith("https://")) {
                    toast(activity.getString(R.string.subs_bad_link))
                    return@setPositiveButton
                }
                activity.lifecycleScope.launch {
                    try {
                        val bytes = api.downloadBytes(url)
                        val text = bytes.toString(Charsets.UTF_8)
                        if (!text.contains("-->")) {
                            toast(activity.getString(R.string.subs_not_srt))
                            return@launch
                        }
                        val name = url.substringAfterLast('/').substringBefore('?').ifBlank { "subtitle.srt" }
                        val file = writeSubtitle(name, text)
                        player()?.addExternalSubtitle(file, name, mimeFor(name, text))
                        toast(activity.getString(R.string.subs_added))
                    } catch (e: Exception) {
                        toast(e.message ?: activity.getString(R.string.subs_none))
                    }
                }
            }
            .show()
        input.requestFocus()
    }

    private fun showList(title: String, options: List<Pair<String, () -> Unit>>, checked: Int = -1) {
        showRoundListDialog(activity, title, options.map { it.first }, checked) { which -> options[which].second() }
    }

    private fun writeSubtitle(name: String, content: String): File {
        val safe = name.replace(Regex("[^A-Za-z0-9._-]"), "_").ifBlank { "subtitle.srt" }
        val dir = File(activity.cacheDir, "pb-subs").apply { mkdirs() }
        return File(dir, safe).apply { writeText(content) }
    }

    private fun mimeFor(name: String, text: String): String {
        val lower = name.lowercase()
        return when {
            lower.endsWith(".vtt") || text.trimStart().startsWith("WEBVTT") -> MimeTypes.TEXT_VTT
            lower.endsWith(".ass") || lower.endsWith(".ssa") -> MimeTypes.TEXT_SSA
            else -> MimeTypes.APPLICATION_SUBRIP
        }
    }

    private fun toast(message: String) {
        Toast.makeText(activity, message, Toast.LENGTH_SHORT).show()
    }
}

/** Subtitle size and background, kept on this TV (desktop keeps its own). */
object SubtitleLook {
    private const val PREFS = "pb_player"

    private fun prefs(context: android.content.Context) =
        context.getSharedPreferences(PREFS, android.content.Context.MODE_PRIVATE)

    fun size(context: android.content.Context): Int = prefs(context).getInt("sub_size", 1).coerceIn(0, 3)

    fun background(context: android.content.Context): String =
        prefs(context).getString("sub_bg", "box") ?: "box"

    fun save(context: android.content.Context, size: Int? = null, background: String? = null) {
        prefs(context).edit().apply {
            size?.let { putInt("sub_size", it) }
            background?.let { putString("sub_bg", it) }
        }.apply()
    }

    fun apply(context: android.content.Context, player: PlaybackEngine?) {
        player?.setSubtitleLook(size(context), background(context))
    }
}
