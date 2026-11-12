package app.peanutbutter.tv.ui

import android.content.Intent
import android.graphics.Typeface
import android.os.Bundle
import android.text.format.Formatter
import android.view.View
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import androidx.core.content.ContextCompat
import androidx.core.view.isVisible
import androidx.fragment.app.FragmentActivity
import androidx.lifecycle.lifecycleScope
import app.peanutbutter.core.ContentLanguages
import app.peanutbutter.core.SessionStore
import app.peanutbutter.core.StreamDownloads
import app.peanutbutter.core.StreamQuality
import app.peanutbutter.tv.R
import app.peanutbutter.tv.asTv
import app.peanutbutter.tv.update.checkForTvUpdate
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

/**
 * Same sections as the desktop app's Settings: Playback, Library & sources,
 * Subtitles, This device, About.
 *
 * Choice chips are built once and restyled in place when one is picked.
 * Rebuilding the row on every pick destroyed the focused chip, so the
 * remote's focus jumped elsewhere after each choice.
 */
class SettingsActivity : FragmentActivity() {
    private val session get() = application.asTv().session
    private var opensubEnabled = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_settings)
        val app = application.asTv()

        findViewById<TextView>(R.id.server_url).text =
            app.session.serverUrl.ifBlank { getString(R.string.not_paired) }

        // Playback
        bindChoices(
            R.id.quality_chips,
            StreamQuality.OPTIONS,
            isOn = { it == StreamQuality.normalize(session.preferredQuality) },
            onPick = { session.preferredQuality = it },
        )
        bindChoices(
            R.id.player_chips,
            listOf(
                SessionStore.PLAYER_EXO to getString(R.string.player_exo),
                SessionStore.PLAYER_VLC to getString(R.string.player_vlc),
            ),
            isOn = { it == SessionStore.normalizePlayer(session.playbackEngine) },
            onPick = { session.playbackEngine = it },
        )

        // Library & sources
        bindChoices(
            R.id.language_chips,
            listOf("" to getString(R.string.languages_all)) + ContentLanguages.OPTIONS,
            isOn = { code ->
                val current = session.preferredLanguages
                if (code.isEmpty()) current.isEmpty() else code in current
            },
            onPick = { code -> toggleLanguage(code) },
        )
        refreshLanguageLabel()

        // Subtitles
        bindChoices(
            R.id.opensub_chips,
            listOf(false to getString(R.string.opensubtitles_off), true to getString(R.string.opensubtitles_on)),
            isOn = { it == opensubEnabled },
            onPick = { setOpenSubtitles(it) },
        )
        setOpenSubtitles(false)
        findViewById<TextView>(R.id.opensub_save).setOnClickListener { saveOpenSubtitles() }
        findViewById<EditText>(R.id.opensub_key).closeKeyboardOnIme()

        // This device
        bindChoices(
            R.id.clear_cache_chips,
            listOf(false to getString(R.string.opensubtitles_off), true to getString(R.string.opensubtitles_on)),
            isOn = { it == session.clearCacheOnExit },
            onPick = { session.clearCacheOnExit = it },
        )
        findViewById<TextView>(R.id.clear_now).setOnClickListener { clearDownloads() }
        refreshDownloadsSize()

        // About
        findViewById<TextView>(R.id.app_version).text =
            runCatching { packageManager.getPackageInfo(packageName, 0).versionName }.getOrNull().orEmpty()
        findViewById<TextView>(R.id.check_updates).setOnClickListener {
            checkForTvUpdate(this@SettingsActivity, manual = true)
        }
        findViewById<TextView>(R.id.server_version).text = "…"
        findViewById<TextView>(R.id.disconnect).setOnClickListener {
            app.session.clear()
            startActivity(
                Intent(this, PairingActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK),
            )
            finish()
        }

        loadServerInfo()
    }

    private fun loadServerInfo() {
        val app = application.asTv()
        val overlay = findViewById<View>(R.id.loading_overlay)
        overlay.isVisible = true
        lifecycleScope.launch {
            try {
                val info = app.api.serverInfo()
                findViewById<TextView>(R.id.server_info).text =
                    getString(R.string.server_info_line, info.version, info.totalTitles)
                findViewById<TextView>(R.id.server_version).text = info.version
                session.preferredLanguages = ContentLanguages.normalize(info.preferredLanguages)
                restyle(R.id.language_chips)
                refreshLanguageLabel()
                setOpenSubtitles(info.opensubtitlesEnabled)
                if (info.opensubtitlesConfigured) {
                    findViewById<EditText>(R.id.opensub_key).hint =
                        getString(R.string.subs_key_hint) + " — paste to replace"
                }
                if (info.wyzieConfigured) {
                    findViewById<EditText>(R.id.wyzie_key).hint =
                        getString(R.string.subs_wyzie_hint) + " — paste to replace"
                }
                val jackett = findViewById<TextView>(R.id.jackett_status)
                if (info.jackettConfigured) {
                    jackett.text = getString(R.string.jackett_ok)
                    jackett.setTextColor(ContextCompat.getColor(this@SettingsActivity, R.color.pb_completed))
                } else {
                    jackett.text = getString(R.string.jackett_missing)
                    jackett.setTextColor(ContextCompat.getColor(this@SettingsActivity, R.color.pb_muted))
                }
            } catch (e: Exception) {
                findViewById<TextView>(R.id.server_version).text = getString(R.string.error_generic)
                Toast.makeText(this@SettingsActivity, e.message, Toast.LENGTH_LONG).show()
            } finally {
                overlay.isVisible = false
                overlay.isClickable = false
                overlay.isFocusable = false
            }
        }
    }

    // ── Choice chips ────────────────────────────────────────────────────────

    /** Chip state per container: whether a chip's value is the selected one. */
    private val chipState = HashMap<Int, (Any?) -> Boolean>()

    /**
     * One row of focusable chips. [isOn] reads the live setting, so after
     * [onPick] the row is restyled in place and focus stays on the chip.
     */
    @Suppress("UNCHECKED_CAST")
    private fun <T> bindChoices(
        containerId: Int,
        options: List<Pair<T, String>>,
        isOn: (T) -> Boolean,
        onPick: (T) -> Unit,
    ) {
        val container = findViewById<LinearLayout>(containerId)
        container.removeAllViews()
        chipState[containerId] = { value -> isOn(value as T) }
        options.forEachIndexed { index, (value, label) ->
            val chip = TextView(this).apply {
                text = label
                tag = value
                textSize = 14f
                setPadding(dp(18), dp(10), dp(18), dp(10))
                isFocusable = true
                isFocusableInTouchMode = true
                background = ContextCompat.getDrawable(this@SettingsActivity, R.drawable.kind_tab_bg)
                layoutParams = LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.WRAP_CONTENT,
                    LinearLayout.LayoutParams.WRAP_CONTENT,
                ).apply { if (index > 0) marginStart = dp(10) }
                setOnClickListener {
                    onPick(value)
                    restyle(containerId)
                }
            }
            container.addView(chip)
        }
        restyle(containerId)
    }

    private fun restyle(containerId: Int) {
        val container = findViewById<LinearLayout>(containerId)
        val isOn = chipState[containerId] ?: return
        for (i in 0 until container.childCount) {
            val chip = container.getChildAt(i) as? TextView ?: continue
            val on = isOn(chip.tag)
            chip.setTextColor(ContextCompat.getColor(this, if (on) R.color.pb_seed else R.color.pb_muted))
            chip.setTypeface(null, if (on) Typeface.BOLD else Typeface.NORMAL)
        }
    }

    // ── Library & sources ───────────────────────────────────────────────────

    private fun toggleLanguage(code: String) {
        val current = session.preferredLanguages
        val next = if (code.isEmpty()) {
            emptySet()
        } else {
            current.toMutableSet().apply { if (code in this) remove(code) else add(code) }
        }
        session.preferredLanguages = next
        refreshLanguageLabel()
        val app = application.asTv()
        lifecycleScope.launch {
            runCatching { app.api.updatePreferredLanguages(next.toList()) }
                .onFailure { err ->
                    Toast.makeText(this@SettingsActivity, err.message, Toast.LENGTH_SHORT).show()
                }
        }
    }

    private fun refreshLanguageLabel() {
        val current = session.preferredLanguages
        findViewById<TextView>(R.id.language_value).text = if (current.isEmpty()) {
            getString(R.string.languages_all)
        } else {
            getString(R.string.languages_selected, current.joinToString(", ").uppercase())
        }
    }

    // ── Subtitles ───────────────────────────────────────────────────────────

    private fun setOpenSubtitles(enabled: Boolean) {
        opensubEnabled = enabled
        restyle(R.id.opensub_chips)
        findViewById<EditText>(R.id.opensub_key).isVisible = enabled
        findViewById<EditText>(R.id.wyzie_key).isVisible = enabled
    }

    private fun saveOpenSubtitles() {
        val key = findViewById<EditText>(R.id.opensub_key).text?.toString()?.trim().orEmpty()
        val wyzie = findViewById<EditText>(R.id.wyzie_key).text?.toString()?.trim().orEmpty()
        val status = findViewById<TextView>(R.id.opensub_status)
        lifecycleScope.launch {
            try {
                application.asTv().api.updateSubtitleKeys(
                    opensubtitlesEnabled = opensubEnabled,
                    opensubtitlesApiKey = key.ifBlank { null },
                    wyzieApiKey = wyzie.ifBlank { null },
                )
                status.text = getString(R.string.opensubtitles_saved)
                findViewById<EditText>(R.id.opensub_key).text?.clear()
                findViewById<EditText>(R.id.wyzie_key).text?.clear()
            } catch (e: Exception) {
                status.text = e.message ?: getString(R.string.error_generic)
            }
        }
    }

    // ── This device ─────────────────────────────────────────────────────────

    /** Streamed pieces and player caches that [StreamDownloads.wipe] deletes. */
    private fun downloadDirs(): List<File> = listOfNotNull(
        File(filesDir, "pb-streams"),
        File(cacheDir, "pb-streams"),
        externalCacheDir?.let { File(it, "pb-streams") },
        File(cacheDir, "exoplayer"),
    )

    private fun refreshDownloadsSize() {
        val label = findViewById<TextView>(R.id.downloads_size)
        lifecycleScope.launch {
            val bytes = withContext(Dispatchers.IO) { downloadDirs().sumOf { it.sizeOnDisk() } }
            label.text = if (bytes <= 0L) {
                getString(R.string.downloads_none)
            } else {
                getString(R.string.downloads_size, Formatter.formatShortFileSize(this@SettingsActivity, bytes))
            }
        }
    }

    private fun clearDownloads() {
        val button = findViewById<TextView>(R.id.clear_now)
        button.isEnabled = false
        lifecycleScope.launch {
            val freed = withContext(Dispatchers.IO) {
                val before = downloadDirs().sumOf { it.sizeOnDisk() }
                // Settings isn't reachable while something plays, so no stream
                // is reading these files. Stops any torrent, then deletes.
                runCatching { StreamDownloads.wipe(applicationContext) }
                before
            }
            button.isEnabled = true
            Toast.makeText(
                this@SettingsActivity,
                getString(R.string.cleared_downloads, Formatter.formatShortFileSize(this@SettingsActivity, freed)),
                Toast.LENGTH_SHORT,
            ).show()
            refreshDownloadsSize()
        }
    }

    private fun dp(v: Int): Int = (v * resources.displayMetrics.density).toInt()
}

/** Total length of the files under this folder (a sparse torrent file counts its full length). */
private fun File.sizeOnDisk(): Long =
    if (!exists()) 0L else walkTopDown().filter { it.isFile }.sumOf { it.length() }
