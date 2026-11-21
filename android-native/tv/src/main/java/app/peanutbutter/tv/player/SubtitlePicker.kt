package app.peanutbutter.tv.player

import androidx.compose.ui.unit.sp
import android.widget.Toast
import androidx.fragment.app.FragmentActivity
import androidx.lifecycle.lifecycleScope
import androidx.media3.common.MimeTypes
import app.peanutbutter.core.ApiClient
import app.peanutbutter.core.SubtitleHit
import app.peanutbutter.tv.R
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import java.io.File
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.ui.unit.dp

/** Player Subtitles menu: look, embedded tracks, OpenSubtitles, Wyzie (lazy download), or a link. */
class SubtitlePicker(
    private val activity: FragmentActivity,
    private val ui: PlayerUi,
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
            val current = player()?.selectedTextTrackId
            val rows = ArrayList<MenuRow>()
            // As on desktop: the look (size, background, delay) comes first.
            rows += styleRows()
            rows += MenuRow.Section(activity.getString(R.string.subs_language_section))
            rows += MenuRow.Option(activity.getString(R.string.subs_off), checked = current == null) {
                player()?.selectTextTrack(null)
            }
            tracks.forEach { (id, label) ->
                rows += MenuRow.Option(label, checked = id == current) { player()?.selectTextTrack(id) }
            }
            rows += MenuRow.Section(activity.getString(R.string.subs_add_section))
            rows += MenuRow.Option(activity.getString(R.string.subs_from_link)) { promptLink() }
            val subsReady = info?.subtitlesConfigured == true ||
                info?.opensubtitlesConfigured == true ||
                info?.wyzieConfigured == true
            if (subsReady) {
                rows += MenuRow.Section(activity.getString(R.string.subs_online_section))
                if (info?.wyzieConfigured == true) {
                    // One search per language (it used to be the first only).
                    langs.forEach { code ->
                        rows += MenuRow.Option(activity.getString(R.string.subs_search_wyzie, code.uppercase())) {
                            searchWyzie(code)
                        }
                    }
                }
                if (info?.opensubtitlesConfigured == true) {
                    langs.forEach { code ->
                        rows += MenuRow.Option(activity.getString(R.string.subs_download, code.uppercase())) {
                            fetchOpenSubtitles(code)
                        }
                    }
                }
            } else if (info != null) {
                rows += MenuRow.Option(activity.getString(R.string.subs_add_key)) { promptKey() }
            }
            ui.openMenu(PlayerMenu(activity.getString(R.string.subs_title), rows))
        }
    }

    /** Size, Background and Delay, the desktop's box at the top of the menu. */
    private fun styleRows(): List<MenuRow> {
        val rows = ArrayList<MenuRow>()
        if (player()?.canStyleSubtitles == true) {
            rows += MenuRow.Segments(
                label = activity.getString(R.string.subs_size),
                choices = List(4) { "A" },
                choiceSizes = List(4) { (13f + it * 3.5f).sp },
                selected = SubtitleLook.size(activity),
            ) { i ->
                SubtitleLook.save(activity, size = i)
                SubtitleLook.apply(activity, player())
            }
            val bgKeys = listOf("shadow", "outline", "box")
            rows += MenuRow.Segments(
                label = activity.getString(R.string.subs_background),
                choices = listOf(R.string.subs_bg_shadow, R.string.subs_bg_outline, R.string.subs_bg_box)
                    .map { activity.getString(it) },
                selected = bgKeys.indexOf(SubtitleLook.background(activity)).coerceAtLeast(0),
            ) { i ->
                SubtitleLook.save(activity, background = bgKeys[i])
                SubtitleLook.apply(activity, player())
            }
        }
        if (player()?.canDelaySubtitles == true) {
            fun text(ms: Long) = String.format(java.util.Locale.US, "%.1f s", ms / 1000.0)
            rows += MenuRow.Stepper(activity.getString(R.string.subs_delay), text(delayMs())) { dir ->
                val next = delayMs() + dir * 100L
                setDelayMs(next)
                player()?.setSubtitleDelay(next)
                text(next)
            }
        }
        return rows
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

    /** OpenSubtitles and Wyzie keys, saved on the server for every device. */
    private fun promptKey() {
        app.peanutbutter.tv.ui.showPbDialog(activity) { dismiss ->
            var opensub by androidx.compose.runtime.remember { androidx.compose.runtime.mutableStateOf("") }
            var wyzie by androidx.compose.runtime.remember { androidx.compose.runtime.mutableStateOf("") }
            KeyCard(
                title = activity.getString(R.string.subs_key_title),
                fields = listOf(
                    Triple(opensub, activity.getString(R.string.subs_key_hint)) { v: String -> opensub = v },
                    Triple(wyzie, activity.getString(R.string.subs_wyzie_hint)) { v: String -> wyzie = v },
                ),
                password = true,
                onCancel = dismiss,
                onSave = {
                    val osKey = opensub.trim()
                    val wyzieKey = wyzie.trim()
                    if (osKey.isEmpty() && wyzieKey.isEmpty()) return@KeyCard
                    dismiss()
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
                },
            )
        }
    }

    /** A subtitle file from a web address (SRT, VTT or ASS). */
    private fun promptLink() {
        app.peanutbutter.tv.ui.showPbDialog(activity) { dismiss ->
            var link by androidx.compose.runtime.remember { androidx.compose.runtime.mutableStateOf("") }
            KeyCard(
                title = activity.getString(R.string.subs_from_link),
                fields = listOf(Triple(link, "https://…/captions.srt") { v: String -> link = v }),
                password = false,
                onCancel = dismiss,
                onSave = {
                    val url = link.trim()
                    if (!url.startsWith("http://") && !url.startsWith("https://")) {
                        toast(activity.getString(R.string.subs_bad_link))
                        return@KeyCard
                    }
                    dismiss()
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
                },
            )
        }
    }

    private fun showList(title: String, options: List<Pair<String, () -> Unit>>) {
        ui.openMenu(PlayerMenu(title, options.map { (label, pick) -> MenuRow.Option(label, onPick = pick) }))
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

/** The app's card with text fields, Cancel and Save (subtitle keys and links). */
@androidx.compose.runtime.Composable
private fun KeyCard(
    title: String,
    fields: List<Triple<String, String, (String) -> Unit>>,
    password: Boolean,
    onCancel: () -> Unit,
    onSave: () -> Unit,
) {
    app.peanutbutter.tv.ui.DialogCard {
        androidx.compose.foundation.text.BasicText(title, style = app.peanutbutter.tv.ui.compose.PbType.h2)
        androidx.compose.foundation.layout.Spacer(androidx.compose.ui.Modifier.height(16.dp))
        fields.forEach { (value, hint, onChange) ->
            app.peanutbutter.tv.ui.compose.PbTextField(
                value, onChange, hint,
                androidx.compose.ui.Modifier.fillMaxWidth().padding(bottom = 10.dp),
                password = password,
                keyboardType = if (password) androidx.compose.ui.text.input.KeyboardType.Password else androidx.compose.ui.text.input.KeyboardType.Uri,
            )
        }
        androidx.compose.foundation.layout.Spacer(androidx.compose.ui.Modifier.height(12.dp))
        androidx.compose.foundation.layout.Row(
            horizontalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(12.dp),
            modifier = androidx.compose.ui.Modifier.align(androidx.compose.ui.Alignment.End),
        ) {
            app.peanutbutter.tv.ui.compose.PbButton(activityString(android.R.string.cancel), null, primary = false, onClick = onCancel)
            app.peanutbutter.tv.ui.compose.PbButton(activityString(R.string.subs_save), null, primary = true, onClick = onSave)
        }
    }
}

@androidx.compose.runtime.Composable
private fun activityString(id: Int): String = androidx.compose.ui.res.stringResource(id)
