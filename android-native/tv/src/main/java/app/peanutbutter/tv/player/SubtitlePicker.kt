package app.peanutbutter.tv.player

import android.app.AlertDialog
import android.text.InputType
import android.view.inputmethod.EditorInfo
import android.view.ViewGroup
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import androidx.fragment.app.FragmentActivity
import androidx.lifecycle.lifecycleScope
import androidx.media3.common.MimeTypes
import app.peanutbutter.core.ApiClient
import app.peanutbutter.tv.R
import app.peanutbutter.tv.ui.closeKeyboardOnIme
import app.peanutbutter.tv.ui.hideKeyboard
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

/** Player caption menu: embedded tracks, OpenSubtitles SRT, or a subtitle link. */
class SubtitlePicker(
    private val activity: FragmentActivity,
    private val player: () -> PlaybackEngine?,
    private val api: ApiClient,
    private val titleId: () -> String?,
    private val season: () -> Int?,
    private val episode: () -> Int?,
    private val languages: () -> Set<String>,
) {
    fun show() {
        activity.lifecycleScope.launch {
            val info = withContext(Dispatchers.IO) { runCatching { api.serverInfo() }.getOrNull() }
            val tracks = player()?.listTextTracks().orEmpty()
            val langs = languages().ifEmpty { setOf("en") }
            val options = ArrayList<Pair<String, () -> Unit>>()
            options += activity.getString(R.string.subs_off) to { player()?.selectTextTrack(null) }
            tracks.forEach { (id, label) ->
                options += label to { player()?.selectTextTrack(id) }
            }
            if (info?.opensubtitlesConfigured == true) {
                langs.forEach { code ->
                    val label = activity.getString(R.string.subs_download, code.uppercase())
                    options += label to { fetch(code) }
                }
            } else {
                options += activity.getString(R.string.subs_add_key) to { promptKey() }
            }
            options += activity.getString(R.string.subs_from_link) to { promptLink() }
            showList(activity.getString(R.string.subs_title), options)
        }
    }

    private fun fetch(language: String) {
        val id = titleId()?.takeIf { it.isNotBlank() } ?: run {
            toast(activity.getString(R.string.subs_no_title))
            return
        }
        activity.lifecycleScope.launch {
            try {
                val rows = api.fetchSubtitles(id, language, season(), episode())
                val sub = rows.firstOrNull { it.content.contains("-->") } ?: rows.firstOrNull()
                if (sub == null || !sub.content.contains("-->")) {
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
        val input = EditText(activity).apply {
            hint = activity.getString(R.string.subs_key_hint)
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD
            imeOptions = EditorInfo.IME_ACTION_DONE
            isFocusable = true
            closeKeyboardOnIme()
        }
        AlertDialog.Builder(activity)
            .setTitle(R.string.subs_key_title)
            .setView(input)
            .setNegativeButton(android.R.string.cancel, null)
            .setPositiveButton(R.string.subs_save) { _, _ ->
                input.hideKeyboard()
                val key = input.text?.toString()?.trim().orEmpty()
                if (key.isEmpty()) return@setPositiveButton
                activity.lifecycleScope.launch {
                    try {
                        api.updateOpenSubtitles(enabled = true, apiKey = key)
                        toast(activity.getString(R.string.subs_enabled))
                    } catch (e: Exception) {
                        toast(e.message ?: activity.getString(R.string.error_generic))
                    }
                }
            }
            .show()
        input.requestFocus()
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

    private fun showList(title: String, options: List<Pair<String, () -> Unit>>) {
        val col = LinearLayout(activity).apply {
            orientation = LinearLayout.VERTICAL
            val pad = (18 * resources.displayMetrics.density).toInt()
            setPadding(pad, pad / 2, pad, pad / 2)
        }
        val dialog = AlertDialog.Builder(activity)
            .setTitle(title)
            .setView(ScrollView(activity).apply {
                addView(col, ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
            })
            .setNegativeButton(android.R.string.cancel, null)
            .create()
        options.forEachIndexed { index, (label, action) ->
            val row = TextView(activity).apply {
                text = label
                textSize = 16f
                setTextColor(activity.getColor(R.color.pb_white))
                val py = (12 * resources.displayMetrics.density).toInt()
                setPadding(py, py, py, py)
                isFocusable = true
                isFocusableInTouchMode = true
                setBackgroundResource(R.drawable.kind_tab_bg)
                setOnClickListener {
                    dialog.dismiss()
                    action()
                }
            }
            val lp = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT,
            )
            if (index > 0) lp.topMargin = (8 * activity.resources.displayMetrics.density).toInt()
            col.addView(row, lp)
        }
        dialog.setOnShowListener { (col.getChildAt(0) as? TextView)?.requestFocus() }
        dialog.show()
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
