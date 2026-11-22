package app.peanutbutter.tv.ui

import app.peanutbutter.tv.ui.compose.setPbContent
import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.widget.Toast
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import androidx.lifecycle.lifecycleScope
import app.peanutbutter.core.TitleItem
import app.peanutbutter.tv.R
import app.peanutbutter.tv.asTv
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * Search, drawn like the desktop's ([SearchScreen]): the field and Movies /
 * Series up top; recent searches before typing; then the top result featured
 * and the rest as a grid. Results follow the typing (a short pause, 2+
 * letters), as on desktop; the mic fills the field by voice.
 */
class SearchActivity : FragmentActivity(), SearchActions {
    private val ui = SearchState()
    private var searchJob: Job? = null
    private var searchToken = 0
    private var listening = false
    private var recognizer: SpeechRecognizer? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        ui.kind = savedInstanceState?.getString(STATE_KIND, "MOVIE") ?: "MOVIE"
        ui.recent.addAll(loadRecent())
        setPbContent { SearchScreen(ui, this) }
    }

    override fun onDestroy() {
        stopVoice()
        super.onDestroy()
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        outState.putString(STATE_KIND, ui.kind)
    }

    // ---- SearchActions ----

    override fun back() = finish()

    override fun setQuery(text: String) {
        ui.query = text
        runSearch(text, now = false)
    }

    override fun submit() {
        remember(ui.query)
        runSearch(ui.query, now = true)
    }

    override fun setKind(kind: String) {
        if (ui.kind == kind) return
        ui.kind = kind
        runSearch(ui.query, now = true)
    }

    override fun open(item: TitleItem, play: Boolean) {
        remember(ui.searched)
        startActivity(
            Intent(this, DetailsActivity::class.java)
                .putExtra(DetailsActivity.EXTRA_ID, item.id)
                .putExtra(DetailsActivity.EXTRA_TITLE, item.displayTitle)
                .putExtra(DetailsActivity.EXTRA_AUTOPLAY, play),
        )
    }

    override fun setOnList(item: TitleItem, on: Boolean, done: (Boolean) -> Unit) {
        val app = application.asTv()
        lifecycleScope.launch {
            val ok = runCatching { app.api.setFavorite(item.id, on) }.isSuccess
            if (ok) UserStateEdits.setFavorite(item.id, on)
            done(ok)
        }
    }

    /** Searches after a short pause in typing ([now]: at once), from 2 letters. */
    private fun runSearch(q: String, now: Boolean) {
        searchJob?.cancel()
        val token = ++searchToken
        val trimmed = q.trim()
        if (trimmed.length < MIN_LENGTH) {
            ui.results.clear()
            ui.searched = ""
            ui.error = null
            ui.loading = false
            return
        }
        val kind = ui.kind
        searchJob = lifecycleScope.launch {
            if (!now) delay(PAUSE_MS)
            if (token != searchToken) return@launch
            ui.loading = true
            ui.error = null
            try {
                val items = application.asTv().api.search(trimmed, kind)
                if (token != searchToken) return@launch
                ui.results.clear()
                ui.results.addAll(byRating(items))
                ui.searched = trimmed
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: Exception) {
                if (token != searchToken) return@launch
                ui.results.clear()
                ui.searched = trimmed
                ui.error = e.message ?: getString(R.string.error_generic)
            } finally {
                if (token == searchToken) ui.loading = false
            }
        }
    }

    /**
     * Highest TMDB rating first, as on desktop. A score from fewer than 50 votes
     * ranks after well-known titles; ties keep the server's order.
     */
    private fun byRating(items: List<TitleItem>): List<TitleItem> = items.withIndex().sortedWith(
        compareByDescending<IndexedValue<TitleItem>> {
            val r = it.value.tmdbVoteAverage ?: 0.0
            if ((it.value.tmdbVoteCount ?: 0) >= 50) r else r - 10
        }.thenBy { it.index },
    ).map { it.value }

    // ---- Recent searches (kept on this TV) ----

    private fun prefs() = getSharedPreferences(PREFS, MODE_PRIVATE)

    private fun loadRecent(): List<String> =
        prefs().getString(KEY_RECENT, null).orEmpty().split('\n').filter { it.isNotBlank() }

    private fun remember(query: String) {
        val q = query.trim()
        if (q.length < MIN_LENGTH) return
        val next = (listOf(q) + ui.recent.filter { !it.equals(q, ignoreCase = true) }).take(MAX_RECENT)
        ui.recent.clear()
        ui.recent.addAll(next)
        prefs().edit().putString(KEY_RECENT, next.joinToString("\n")).apply()
    }

    // ---- Voice ----

    private val micPermission = registerForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { granted ->
        if (granted) beginListening()
        else Toast.makeText(this, R.string.voice_permission, Toast.LENGTH_SHORT).show()
    }

    override fun mic() {
        if (listening) {
            stopVoice()
            return
        }
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            micPermission.launch(Manifest.permission.RECORD_AUDIO)
            return
        }
        beginListening()
    }

    private fun beginListening() {
        if (!SpeechRecognizer.isRecognitionAvailable(this)) {
            Toast.makeText(this, R.string.voice_unavailable, Toast.LENGTH_SHORT).show()
            return
        }
        ui.query = ""
        recognizer?.destroy()
        val speech = SpeechRecognizer.createSpeechRecognizer(this)
        recognizer = speech
        speech.setRecognitionListener(object : RecognitionListener {
            override fun onReadyForSpeech(params: Bundle?) = setMicListening(true)
            override fun onBeginningOfSpeech() = Unit
            override fun onRmsChanged(rmsdB: Float) = Unit
            override fun onBufferReceived(buffer: ByteArray?) = Unit
            override fun onEndOfSpeech() = Unit
            override fun onError(error: Int) = setMicListening(false)
            override fun onPartialResults(partial: Bundle?) {
                val text = partial
                    ?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                    ?.firstOrNull()
                    ?.trim()
                    .orEmpty()
                if (text.isNotEmpty()) showSpoken(text, search = false)
            }
            override fun onResults(results: Bundle?) {
                setMicListening(false)
                val spoken = results
                    ?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                    ?.firstOrNull()
                    ?.trim()
                    .orEmpty()
                if (spoken.isNotEmpty()) showSpoken(spoken, search = true)
            }
            override fun onEvent(eventType: Int, params: Bundle?) = Unit
        })
        speech.startListening(Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
        })
    }

    private fun showSpoken(text: String, search: Boolean) {
        ui.query = text
        if (search) {
            remember(text)
            runSearch(text, now = true)
        }
    }

    private fun setMicListening(active: Boolean) {
        listening = active
        ui.listening = active
    }

    private fun stopVoice() {
        val speech = recognizer
        recognizer = null
        speech?.setRecognitionListener(null)
        speech?.cancel()
        speech?.destroy()
        if (listening) setMicListening(false)
    }

    companion object {
        private const val STATE_KIND = "kind"
        private const val MIN_LENGTH = 2
        private const val PAUSE_MS = 450L
        private const val PREFS = "pb_search"
        private const val KEY_RECENT = "recent"
        private const val MAX_RECENT = 8
    }
}
