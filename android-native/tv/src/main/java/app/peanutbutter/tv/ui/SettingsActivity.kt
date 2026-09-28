package app.peanutbutter.tv.ui

import android.content.Intent
import android.os.Bundle
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
import app.peanutbutter.core.StreamQuality
import app.peanutbutter.tv.R
import app.peanutbutter.tv.asTv
import kotlinx.coroutines.launch

/** Flutter Settings: quality, languages, server/Jackett, disconnect. */
class SettingsActivity : FragmentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_settings)
        val app = application.asTv()

        findViewById<TextView>(R.id.server_url).text =
            app.session.serverUrl.ifBlank { getString(R.string.not_paired) }

        bindQualityChips(app.session.preferredQuality)
        bindLanguageChips(app.session.preferredLanguages)
        bindPlayerChips(app.session.playbackEngine)
        bindOpenSubtitles(enabled = false)
        bindClearCache(app.session.clearCacheOnExit)
        findViewById<TextView>(R.id.opensub_save).setOnClickListener { saveOpenSubtitles() }
        findViewById<EditText>(R.id.opensub_key).closeKeyboardOnIme()

        findViewById<TextView>(R.id.disconnect).setOnClickListener {
            app.session.clear()
            startActivity(
                Intent(this, PairingActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK),
            )
            finish()
        }

        val overlay = findViewById<View>(R.id.loading_overlay)
        overlay.isVisible = true
        lifecycleScope.launch {
            try {
                val info = app.api.serverInfo()
                findViewById<TextView>(R.id.server_info).text =
                    getString(R.string.server_info_line, info.version, info.totalTitles)
                val jackett = findViewById<TextView>(R.id.jackett_status)
                val langs = ContentLanguages.normalize(info.preferredLanguages)
                app.session.preferredLanguages = langs
                bindLanguageChips(langs)
                bindOpenSubtitles(info.opensubtitlesEnabled)
                if (info.opensubtitlesConfigured) {
                    findViewById<EditText>(R.id.opensub_key).hint =
                        getString(R.string.subs_key_hint) + " — paste to replace"
                }
                if (info.jackettConfigured) {
                    jackett.text = getString(R.string.jackett_ok)
                    jackett.setTextColor(ContextCompat.getColor(this@SettingsActivity, R.color.pb_completed))
                } else {
                    jackett.text = getString(R.string.jackett_missing)
                    jackett.setTextColor(ContextCompat.getColor(this@SettingsActivity, R.color.pb_muted))
                }
            } catch (e: Exception) {
                Toast.makeText(this@SettingsActivity, e.message, Toast.LENGTH_LONG).show()
            } finally {
                overlay.isVisible = false
                overlay.isClickable = false
                overlay.isFocusable = false
            }
        }
    }

    private fun bindQualityChips(selected: String) {
        val chips = findViewById<LinearLayout>(R.id.quality_chips)
        val valueLabel = findViewById<TextView>(R.id.quality_value)
        chips.removeAllViews()
        val current = StreamQuality.normalize(selected)

        fun refresh() {
            chips.removeAllViews()
            StreamQuality.OPTIONS.forEachIndexed { index, (value, label) ->
                val chip = TextView(this).apply {
                    text = label
                    textSize = 14f
                    setPadding(dp(18), dp(10), dp(18), dp(10))
                    isFocusable = true
                    isFocusableInTouchMode = true
                    background = getDrawable(R.drawable.kind_tab_bg)
                    val on = value == current
                    setTextColor(
                        ContextCompat.getColor(
                            this@SettingsActivity,
                            if (on) R.color.pb_seed else R.color.pb_muted,
                        ),
                    )
                    setTypeface(null, if (on) android.graphics.Typeface.BOLD else android.graphics.Typeface.NORMAL)
                    val lp = LinearLayout.LayoutParams(
                        LinearLayout.LayoutParams.WRAP_CONTENT,
                        LinearLayout.LayoutParams.WRAP_CONTENT,
                    )
                    if (index > 0) lp.marginStart = dp(10)
                    layoutParams = lp
                    setOnClickListener {
                        application.asTv().session.preferredQuality = value
                        bindQualityChips(value)
                    }
                }
                chips.addView(chip)
            }
            val label = StreamQuality.OPTIONS.firstOrNull { it.first == current }?.second ?: current
            valueLabel.text = getString(R.string.quality_selected, label)
        }
        refresh()
    }

    private fun bindPlayerChips(selected: String) {
        val chips = findViewById<LinearLayout>(R.id.player_chips)
        val valueLabel = findViewById<TextView>(R.id.player_value)
        val current = SessionStore.normalizePlayer(selected)
        chips.removeAllViews()
        val options = listOf(
            SessionStore.PLAYER_EXO to getString(R.string.player_exo),
            SessionStore.PLAYER_VLC to getString(R.string.player_vlc),
        )
        options.forEachIndexed { index, (value, label) ->
            val on = value == current
            val chip = TextView(this).apply {
                text = label
                textSize = 14f
                setPadding(dp(18), dp(10), dp(18), dp(10))
                isFocusable = true
                isFocusableInTouchMode = true
                background = getDrawable(R.drawable.kind_tab_bg)
                setTextColor(
                    ContextCompat.getColor(
                        this@SettingsActivity,
                        if (on) R.color.pb_seed else R.color.pb_muted,
                    ),
                )
                setTypeface(null, if (on) android.graphics.Typeface.BOLD else android.graphics.Typeface.NORMAL)
                val lp = LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.WRAP_CONTENT,
                    LinearLayout.LayoutParams.WRAP_CONTENT,
                )
                if (index > 0) lp.marginStart = dp(10)
                layoutParams = lp
                setOnClickListener {
                    application.asTv().session.playbackEngine = value
                    bindPlayerChips(value)
                }
            }
            chips.addView(chip)
        }
        val label = options.firstOrNull { it.first == current }?.second ?: current
        valueLabel.text = getString(R.string.player_selected, label)
    }

    private fun bindClearCache(enabled: Boolean) {
        val chips = findViewById<LinearLayout>(R.id.clear_cache_chips)
        chips.removeAllViews()
        listOf(false to getString(R.string.opensubtitles_off), true to getString(R.string.opensubtitles_on))
            .forEachIndexed { index, (value, label) ->
                val on = value == enabled
                val chip = TextView(this).apply {
                    text = label
                    textSize = 14f
                    setPadding(dp(18), dp(10), dp(18), dp(10))
                    isFocusable = true
                    isFocusableInTouchMode = true
                    background = getDrawable(R.drawable.kind_tab_bg)
                    setTextColor(ContextCompat.getColor(this@SettingsActivity, if (on) R.color.pb_seed else R.color.pb_muted))
                    setTypeface(null, if (on) android.graphics.Typeface.BOLD else android.graphics.Typeface.NORMAL)
                    val lp = LinearLayout.LayoutParams(
                        LinearLayout.LayoutParams.WRAP_CONTENT,
                        LinearLayout.LayoutParams.WRAP_CONTENT,
                    )
                    if (index > 0) lp.marginStart = dp(10)
                    layoutParams = lp
                    setOnClickListener {
                        application.asTv().session.clearCacheOnExit = value
                        bindClearCache(value)
                    }
                }
                chips.addView(chip)
            }
    }

    private var opensubEnabled = false

    private fun bindOpenSubtitles(enabled: Boolean) {
        opensubEnabled = enabled
        val chips = findViewById<LinearLayout>(R.id.opensub_chips)
        val key = findViewById<EditText>(R.id.opensub_key)
        chips.removeAllViews()
        listOf(false to getString(R.string.opensubtitles_off), true to getString(R.string.opensubtitles_on))
            .forEachIndexed { index, (value, label) ->
                val on = value == opensubEnabled
                val chip = TextView(this).apply {
                    text = label
                    textSize = 14f
                    setPadding(dp(18), dp(10), dp(18), dp(10))
                    isFocusable = true
                    isFocusableInTouchMode = true
                    background = getDrawable(R.drawable.kind_tab_bg)
                    setTextColor(ContextCompat.getColor(this@SettingsActivity, if (on) R.color.pb_seed else R.color.pb_muted))
                    setTypeface(null, if (on) android.graphics.Typeface.BOLD else android.graphics.Typeface.NORMAL)
                    val lp = LinearLayout.LayoutParams(
                        LinearLayout.LayoutParams.WRAP_CONTENT,
                        LinearLayout.LayoutParams.WRAP_CONTENT,
                    )
                    if (index > 0) lp.marginStart = dp(10)
                    layoutParams = lp
                    setOnClickListener { bindOpenSubtitles(value) }
                }
                chips.addView(chip)
            }
        key.isVisible = opensubEnabled
    }

    private fun saveOpenSubtitles() {
        val key = findViewById<EditText>(R.id.opensub_key).text?.toString()?.trim().orEmpty()
        val status = findViewById<TextView>(R.id.opensub_status)
        lifecycleScope.launch {
            try {
                application.asTv().api.updateOpenSubtitles(opensubEnabled, key.ifBlank { null })
                status.text = getString(R.string.opensubtitles_saved)
                findViewById<EditText>(R.id.opensub_key).text?.clear()
            } catch (e: Exception) {
                status.text = e.message ?: getString(R.string.error_generic)
            }
        }
    }

    private fun bindLanguageChips(selected: Set<String>) {
        val chips = findViewById<LinearLayout>(R.id.language_chips)
        val valueLabel = findViewById<TextView>(R.id.language_value)
        val current = ContentLanguages.normalize(selected)
        chips.removeAllViews()
        val options = listOf("" to getString(R.string.languages_all)) + ContentLanguages.OPTIONS
        options.forEachIndexed { index, (code, label) ->
            val on = if (code.isEmpty()) current.isEmpty() else code in current
            val chip = TextView(this).apply {
                text = label
                textSize = 14f
                setPadding(dp(18), dp(10), dp(18), dp(10))
                isFocusable = true
                isFocusableInTouchMode = true
                background = getDrawable(R.drawable.kind_tab_bg)
                setTextColor(
                    ContextCompat.getColor(
                        this@SettingsActivity,
                        if (on) R.color.pb_seed else R.color.pb_muted,
                    ),
                )
                setTypeface(null, if (on) android.graphics.Typeface.BOLD else android.graphics.Typeface.NORMAL)
                val lp = LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.WRAP_CONTENT,
                    LinearLayout.LayoutParams.WRAP_CONTENT,
                )
                if (index > 0) lp.marginStart = dp(10)
                layoutParams = lp
                setOnClickListener {
                    val next = if (code.isEmpty()) {
                        emptySet()
                    } else {
                        current.toMutableSet().apply {
                            if (code in this) remove(code) else add(code)
                        }
                    }
                    val app = application.asTv()
                    app.session.preferredLanguages = next
                    lifecycleScope.launch {
                        runCatching { app.api.updatePreferredLanguages(next.toList()) }
                            .onFailure { err ->
                                Toast.makeText(this@SettingsActivity, err.message, Toast.LENGTH_SHORT).show()
                            }
                    }
                    bindLanguageChips(next)
                }
            }
            chips.addView(chip)
        }
        valueLabel.text = if (current.isEmpty()) {
            getString(R.string.languages_all)
        } else {
            getString(R.string.languages_selected, current.joinToString(", ").uppercase())
        }
    }

    private fun dp(v: Int): Int = (v * resources.displayMetrics.density).toInt()
}
