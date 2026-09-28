package app.peanutbutter.core

import android.content.Context
import androidx.preference.PreferenceManager

/** Persisted pairing: server base URL + 6-digit API token. */
class SessionStore(context: Context) {
    private val prefs = PreferenceManager.getDefaultSharedPreferences(context.applicationContext)

    var serverUrl: String
        get() = prefs.getString(KEY_URL, "")?.trim().orEmpty()
        set(value) = prefs.edit().putString(KEY_URL, value.trim().trimEnd('/')).apply()

    var apiToken: String
        get() = normalizeToken(prefs.getString(KEY_TOKEN, "").orEmpty())
        set(value) = prefs.edit().putString(KEY_TOKEN, normalizeToken(value)).apply()

    val isPaired: Boolean
        get() = serverUrl.isNotBlank() && apiToken.isNotBlank()

    var preferredQuality: String
        get() = StreamQuality.normalize(prefs.getString(KEY_QUALITY, "1080p"))
        set(value) = prefs.edit().putString(KEY_QUALITY, StreamQuality.normalize(value)).apply()

    /** `exo` (Media3, default) or `vlc` (LibVLC). */
    var playbackEngine: String
        get() = normalizePlayer(prefs.getString(KEY_PLAYER, PLAYER_EXO))
        set(value) = prefs.edit().putString(KEY_PLAYER, normalizePlayer(value)).apply()

    /** Fit, fill, stretch, 16:9, or 4:3. */
    var aspectRatio: String
        get() = normalizeAspect(prefs.getString(KEY_ASPECT, ASPECT_FIT))
        set(value) = prefs.edit().putString(KEY_ASPECT, normalizeAspect(value)).apply()

    /** Delete streamed downloads when the app leaves the foreground. */
    var clearCacheOnExit: Boolean
        get() = prefs.getBoolean(KEY_CLEAR_CACHE, true)
        set(value) = prefs.edit().putBoolean(KEY_CLEAR_CACHE, value).apply()

    /** Empty set means every language (same as the other apps). */
    var preferredLanguages: Set<String>
        get() = ContentLanguages.normalize(
            prefs.getString(KEY_LANGS, "").orEmpty().split(','),
        )
        set(value) {
            val next = ContentLanguages.normalize(value)
            prefs.edit().putString(KEY_LANGS, next.joinToString(",")).apply()
        }

    fun clear() {
        prefs.edit().remove(KEY_URL).remove(KEY_TOKEN).apply()
    }

    companion object {
        private const val KEY_URL = "pb_server_url"
        private const val KEY_TOKEN = "pb_api_token"
        private const val KEY_QUALITY = "pb_stream_quality"
        private const val KEY_LANGS = "pb_preferred_languages"
        private const val KEY_PLAYER = "pb_playback_engine"
        private const val KEY_ASPECT = "pb_aspect_ratio"
        private const val KEY_CLEAR_CACHE = "pb_clear_cache_on_exit"

        const val PLAYER_EXO = "exo"
        const val PLAYER_VLC = "vlc"

        const val ASPECT_FIT = "fit"
        const val ASPECT_ORIGINAL = "original"
        const val ASPECT_FILL = "fill"
        const val ASPECT_STRETCH = "stretch"
        const val ASPECT_16_9 = "16:9"
        const val ASPECT_4_3 = "4:3"

        fun normalizeAspect(raw: String?): String = when (raw) {
            ASPECT_ORIGINAL, ASPECT_FILL, ASPECT_STRETCH, ASPECT_16_9, ASPECT_4_3 -> raw
            else -> ASPECT_FIT
        }

        fun normalizePlayer(raw: String?): String = if (raw == PLAYER_VLC) PLAYER_VLC else PLAYER_EXO

        fun normalizeToken(raw: String): String {
            val digits = raw.replace(Regex("[^0-9]"), "")
            return if (digits.length == 6) digits else raw.trim()
        }
    }
}
