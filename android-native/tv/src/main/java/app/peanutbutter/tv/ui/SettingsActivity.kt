package app.peanutbutter.tv.ui

import app.peanutbutter.tv.ui.compose.setPbContent
import android.content.Intent
import android.os.Bundle
import android.text.format.Formatter
import android.widget.Toast
import androidx.activity.compose.setContent
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
 * Settings, drawn like the desktop's ([SettingsScreen]): Playback, Library &
 * sources, Subtitles, This device, About, then Disconnect. The TV adds its
 * player choice and Check for updates.
 */
class SettingsActivity : FragmentActivity(), SettingsActions {
    private val session get() = application.asTv().session
    private val ui = SettingsState()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        ui.serverUrl = session.serverUrl
        ui.quality = StreamQuality.normalize(session.preferredQuality)
        ui.player = SessionStore.normalizePlayer(session.playbackEngine)
        ui.languages = session.preferredLanguages
        ui.clearOnExit = session.clearCacheOnExit
        ui.appVersion = runCatching { packageManager.getPackageInfo(packageName, 0).versionName }.getOrNull() ?: "–"
        val choices = SettingsChoices(
            qualities = StreamQuality.OPTIONS,
            players = listOf(
                SessionStore.PLAYER_EXO to getString(R.string.player_exo),
                SessionStore.PLAYER_VLC to getString(R.string.player_vlc),
            ),
            languages = ContentLanguages.OPTIONS,
        )
        setPbContent { SettingsScreen(ui, choices, this) }
        refreshDownloadsSize()
        loadServerInfo()
    }

    private fun loadServerInfo() {
        val app = application.asTv()
        lifecycleScope.launch {
            try {
                val info = app.api.serverInfo()
                ui.serverVersion = info.version
                ui.totalTitles = info.totalTitles
                ui.sourcesReady = info.jackettConfigured
                session.preferredLanguages = ContentLanguages.normalize(info.preferredLanguages)
                ui.languages = session.preferredLanguages
                ui.opensubEnabled = info.opensubtitlesEnabled
                ui.opensubConfigured = info.opensubtitlesConfigured
                ui.wyzieConfigured = info.wyzieConfigured
                ui.subtitlesConfigured = info.subtitlesConfigured
            } catch (e: Exception) {
                ui.serverVersion = getString(R.string.error_generic)
                Toast.makeText(this@SettingsActivity, e.message, Toast.LENGTH_LONG).show()
            }
        }
    }

    // ---- SettingsActions ----

    override fun back() = finish()

    override fun setQuality(value: String) {
        session.preferredQuality = value
        ui.quality = value
    }

    override fun setPlayer(value: String) {
        session.playbackEngine = value
        ui.player = value
    }

    /** "" picks All languages; any other code is added or removed. Saved on the server. */
    override fun toggleLanguage(code: String) {
        val current = session.preferredLanguages
        val next = if (code.isEmpty()) {
            emptySet()
        } else {
            current.toMutableSet().apply { if (code in this) remove(code) else add(code) }
        }
        session.preferredLanguages = next
        ui.languages = next
        val app = application.asTv()
        lifecycleScope.launch {
            runCatching { app.api.updatePreferredLanguages(next.toList()) }
                .onFailure { err -> Toast.makeText(this@SettingsActivity, err.message, Toast.LENGTH_SHORT).show() }
        }
    }

    override fun setOpenSubtitles(on: Boolean) {
        ui.opensubEnabled = on
    }

    override fun saveSubtitles() {
        if (ui.saving) return
        val key = ui.opensubKey.trim()
        val wyzie = ui.wyzieKey.trim()
        ui.saving = true
        lifecycleScope.launch {
            try {
                application.asTv().api.updateSubtitleKeys(
                    opensubtitlesEnabled = ui.opensubEnabled,
                    opensubtitlesApiKey = key.ifBlank { null },
                    wyzieApiKey = wyzie.ifBlank { null },
                )
                ui.subsMessage = getString(R.string.opensubtitles_saved)
                if (key.isNotBlank()) ui.opensubConfigured = true
                if (wyzie.isNotBlank()) ui.wyzieConfigured = true
                ui.opensubKey = ""
                ui.wyzieKey = ""
            } catch (e: Exception) {
                ui.subsMessage = e.message ?: getString(R.string.error_generic)
            } finally {
                ui.saving = false
            }
        }
    }

    override fun setClearOnExit(on: Boolean) {
        session.clearCacheOnExit = on
        ui.clearOnExit = on
    }

    override fun checkUpdates() = checkForTvUpdate(this, manual = true)

    override fun disconnect() {
        session.clear()
        startActivity(
            Intent(this, PairingActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK),
        )
        finish()
    }

    // ---- This device ----

    /** Streamed pieces and player caches that [StreamDownloads.wipe] deletes. */
    private fun downloadDirs(): List<File> = listOfNotNull(
        File(filesDir, "pb-streams"),
        File(cacheDir, "pb-streams"),
        externalCacheDir?.let { File(it, "pb-streams") },
        File(cacheDir, "exoplayer"),
    )

    private fun refreshDownloadsSize() {
        lifecycleScope.launch {
            val bytes = withContext(Dispatchers.IO) { downloadDirs().sumOf { it.sizeOnDisk() } }
            ui.cacheMessage = if (bytes <= 0L) {
                getString(R.string.downloads_none)
            } else {
                getString(R.string.downloads_size, Formatter.formatShortFileSize(this@SettingsActivity, bytes))
            }
        }
    }

    override fun clearNow() {
        lifecycleScope.launch {
            val freed = withContext(Dispatchers.IO) {
                val before = downloadDirs().sumOf { it.sizeOnDisk() }
                // Settings isn't reachable while something plays, so no stream
                // is reading these files. Stops any torrent, then deletes.
                runCatching { StreamDownloads.wipe(applicationContext) }
                before
            }
            Toast.makeText(
                this@SettingsActivity,
                getString(R.string.cleared_downloads, Formatter.formatShortFileSize(this@SettingsActivity, freed)),
                Toast.LENGTH_SHORT,
            ).show()
            refreshDownloadsSize()
        }
    }
}

/**
 * Disk space the files under this folder actually use. Torrent files are
 * sparse: a partly downloaded video has its full length but only the
 * downloaded blocks allocated, and length() reported gigabytes that weren't
 * used (or cleared).
 */
private fun File.sizeOnDisk(): Long =
    if (!exists()) 0L else walkTopDown().filter { it.isFile }.sumOf { it.allocatedBytes() }

/** Allocated blocks (st_blocks counts 512-byte units); apparent length if stat fails. */
internal fun File.allocatedBytes(): Long =
    runCatching { android.system.Os.stat(path).st_blocks * 512L }.getOrElse { length() }
