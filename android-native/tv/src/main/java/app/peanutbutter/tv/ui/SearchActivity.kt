package app.peanutbutter.tv.ui

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.view.KeyEvent
import android.view.View
import android.widget.EditText
import android.widget.ImageButton
import android.widget.ProgressBar
import android.widget.TextView
import android.widget.Toast
import androidx.activity.OnBackPressedCallback
import androidx.activity.result.contract.ActivityResultContracts
import android.content.res.ColorStateList
import androidx.core.content.ContextCompat
import androidx.core.view.isVisible
import androidx.fragment.app.FragmentActivity
import androidx.leanback.app.VerticalGridSupportFragment
import androidx.leanback.widget.ArrayObjectAdapter
import androidx.leanback.widget.FocusHighlight
import androidx.leanback.widget.VerticalGridPresenter
import androidx.leanback.widget.VerticalGridView
import androidx.lifecycle.lifecycleScope
import app.peanutbutter.core.TitleItem
import app.peanutbutter.tv.R
import app.peanutbutter.tv.asTv
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

/** Flutter SearchScreen — KindSwitch + field + sort chips + poster grid. */
class SearchActivity : FragmentActivity() {
    private var kind = "MOVIE"
    private var sortKey = "TRENDING"
    private var searchJob: Job? = null
    private var searchToken = 0
    private var gridFragment: SearchGridFragment? = null
    private var latestItems: List<TitleItem> = emptyList()
    private var listening = false
    private var recognizer: SpeechRecognizer? = null

    private val sortOptions = listOf(
        "TRENDING" to R.string.trending,
        "POPULARITY" to R.string.popular,
        "DATE_ADDED" to R.string.last_added,
        "YEAR" to R.string.sort_year,
        "RATING" to R.string.sort_rating,
        "ROTTEN_TOMATOES" to R.string.sort_rt,
        "TITLE" to R.string.sort_title,
    )

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_search)

        if (savedInstanceState == null) {
            gridFragment = SearchGridFragment()
            supportFragmentManager.beginTransaction()
                .replace(R.id.results, gridFragment!!)
                .commitNow()
        } else {
            gridFragment = supportFragmentManager.findFragmentById(R.id.results) as? SearchGridFragment
            kind = savedInstanceState.getString(STATE_KIND, "MOVIE")
            sortKey = savedInstanceState.getString(STATE_SORT, "TRENDING")
        }

        styleKind()
        findViewById<TextView>(R.id.kind_movies).setOnClickListener { setKind("MOVIE") }
        findViewById<TextView>(R.id.kind_series).setOnClickListener { setKind("SERIES") }
        findViewById<TextView>(R.id.kind_movies).setOnKeyListener(headerKeys(action = { setKind("MOVIE") }))
        findViewById<TextView>(R.id.kind_series).setOnKeyListener(headerKeys(action = { setKind("SERIES") }))

        findViewById<ImageButton>(R.id.btn_favourites).setOnClickListener {
            startActivity(
                Intent(this, LibraryActivity::class.java)
                    .putExtra(LibraryActivity.EXTRA_MODE, LibraryActivity.MODE_FAVOURITES),
            )
        }
        findViewById<ImageButton>(R.id.btn_settings).setOnClickListener {
            startActivity(Intent(this, SettingsActivity::class.java))
        }
        findViewById<ImageButton>(R.id.btn_mic).setOnClickListener { startVoiceSearch() }
        findViewById<ImageButton>(R.id.btn_mic).setOnKeyListener(headerKeys(onLeft = {
            findViewById<View>(R.id.query).requestFocus()
        }))
        listOf(R.id.filter_sort, R.id.btn_favourites, R.id.btn_settings).forEach {
            findViewById<View>(it).setOnKeyListener(headerKeys())
        }
        onBackPressedDispatcher.addCallback(this, object : OnBackPressedCallback(true) {
            override fun handleOnBackPressed() {
                if (listening) {
                    stopVoice()
                    return
                }
                val focused = currentFocus
                if (focused != null && focused.rootView !== window.decorView) {
                    isEnabled = false
                    onBackPressedDispatcher.onBackPressed()
                    isEnabled = true
                    return
                }
                val onSearch = focused?.id in HEADER_IDS
                if (!onSearch) {
                    findViewById<View>(R.id.query).requestFocus()
                } else {
                    finish()
                }
            }
        })

        buildSortChips()

        val query = findViewById<EditText>(R.id.query)
        query.closeKeyboardOnIme { runSearch(query.text?.toString().orEmpty()) }
        query.setOnKeyListener { _, keyCode, event ->
            if (event.action != KeyEvent.ACTION_DOWN) return@setOnKeyListener false
            when (keyCode) {
                KeyEvent.KEYCODE_DPAD_DOWN -> focusResults()
                KeyEvent.KEYCODE_DPAD_RIGHT -> {
                    val atEnd = query.selectionEnd >= (query.text?.length ?: 0)
                    if (atEnd) findViewById<View>(R.id.btn_mic).requestFocus() else false
                }
                else -> false
            }
        }
        query.requestFocus()
        updateIdle(true)
    }

    override fun onDestroy() {
        stopVoice()
        super.onDestroy()
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        outState.putString(STATE_KIND, kind)
        outState.putString(STATE_SORT, sortKey)
    }

    private fun buildSortChips() {
        val button = findViewById<TextView>(R.id.filter_sort)
        fun label(): String {
            val res = sortOptions.firstOrNull { it.first == sortKey }?.second ?: R.string.trending
            return getString(R.string.sort_value, getString(res))
        }
        button.text = label()
        button.setOnClickListener {
            val options = sortOptions.map { it.first to getString(it.second) }
            val col = android.widget.LinearLayout(this).apply {
                orientation = android.widget.LinearLayout.VERTICAL
                val pad = dp(16)
                setPadding(pad, pad / 2, pad, pad / 2)
            }
            val dialog = android.app.AlertDialog.Builder(this)
                .setTitle(R.string.sort)
                .setNegativeButton(android.R.string.cancel, null)
                .create()
            options.forEachIndexed { index, (key, text) ->
                val row = TextView(this).apply {
                    this.text = text
                    textSize = 16f
                    setTextColor(getColor(R.color.pb_white))
                    val py = dp(12)
                    setPadding(py, py, py, py)
                    isFocusable = true
                    background = getDrawable(R.drawable.kind_tab_bg)
                    setTypeface(null, if (key == sortKey) android.graphics.Typeface.BOLD else android.graphics.Typeface.NORMAL)
                    setOnClickListener {
                        dialog.dismiss()
                        selectSort(key)
                    }
                }
                val lp = android.widget.LinearLayout.LayoutParams(
                    android.widget.LinearLayout.LayoutParams.MATCH_PARENT,
                    android.widget.LinearLayout.LayoutParams.WRAP_CONTENT,
                )
                if (index > 0) lp.topMargin = dp(8)
                col.addView(row, lp)
            }
            dialog.setView(android.widget.ScrollView(this).apply { addView(col) })
            dialog.setOnShowListener { (col.getChildAt(0) as? TextView)?.requestFocus() }
            dialog.show()
        }
    }

    private fun selectSort(key: String) {
        if (sortKey == key) return
        sortKey = key
        val res = sortOptions.firstOrNull { it.first == sortKey }?.second ?: R.string.trending
        findViewById<TextView>(R.id.filter_sort).text = getString(R.string.sort_value, getString(res))
        applySortAndShow(latestItems)
    }

    private fun setKind(k: String) {
        if (kind == k) return
        kind = k
        styleKind()
        runSearch(findViewById<EditText>(R.id.query).text?.toString().orEmpty())
    }

    private fun styleKind() {
        val movies = findViewById<TextView>(R.id.kind_movies)
        val series = findViewById<TextView>(R.id.kind_series)
        val seed = ContextCompat.getColor(this, R.color.pb_seed)
        val muted = ContextCompat.getColor(this, R.color.pb_muted)
        movies.setTextColor(if (kind == "MOVIE") seed else muted)
        movies.setTypeface(null, if (kind == "MOVIE") android.graphics.Typeface.BOLD else android.graphics.Typeface.NORMAL)
        series.setTextColor(if (kind == "SERIES") seed else muted)
        series.setTypeface(null, if (kind == "SERIES") android.graphics.Typeface.BOLD else android.graphics.Typeface.NORMAL)
    }

    private fun runSearch(q: String) {
        searchJob?.cancel()
        val token = ++searchToken
        val trimmed = q.trim()
        val busy = findViewById<ProgressBar>(R.id.busy)
        val count = findViewById<TextView>(R.id.result_count)
        if (trimmed.length < 2) {
            latestItems = emptyList()
            gridFragment?.setItems(emptyList())
            count.text = ""
            updateIdle(true)
            return
        }
        updateIdle(false)
        searchJob = lifecycleScope.launch {
            if (token != searchToken) return@launch
            busy.isVisible = true
            try {
                val items = application.asTv().api.search(trimmed, kind)
                if (token != searchToken) return@launch
                latestItems = items
                applySortAndShow(items)
            } catch (e: Exception) {
                if (token != searchToken) return@launch
                Toast.makeText(this@SearchActivity, e.message, Toast.LENGTH_LONG).show()
            } finally {
                if (token == searchToken) busy.isVisible = false
            }
        }
    }

    private fun applySortAndShow(items: List<TitleItem>) {
        val sorted = when (sortKey) {
            "YEAR" -> items.sortedByDescending { it.year ?: 0 }
            "RATING" -> items.sortedByDescending { it.displayScore?.outOfTen ?: 0.0 }
            "TITLE" -> items.sortedBy { it.title.lowercase() }
            "POPULARITY" -> items.sortedByDescending { it.tmdbVoteAverage ?: it.imdbRating ?: 0.0 }
            "ROTTEN_TOMATOES" -> items.sortedByDescending { it.rtScore ?: 0 }
            "DATE_ADDED" -> items
            else -> items // TRENDING — server order
        }
        gridFragment?.setItems(sorted)
        findViewById<TextView>(R.id.result_count).text =
            if (sorted.isEmpty()) getString(R.string.search_empty)
            else getString(R.string.results_count, sorted.size)
        updateIdle(false)
    }

    private fun updateIdle(show: Boolean) {
        findViewById<View>(R.id.idle_state).isVisible = show
        findViewById<View>(R.id.results).isVisible = !show
    }

    private val micPermission = registerForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { granted ->
        if (granted) beginListening()
        else Toast.makeText(this, R.string.voice_permission, Toast.LENGTH_SHORT).show()
    }

    private fun startVoiceSearch() {
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
        findViewById<EditText>(R.id.query)?.apply {
            setText("")
            setSelection(0)
        }
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
        val query = findViewById<EditText>(R.id.query)
        query.setText(text)
        query.setSelection(text.length)
        if (search) {
            query.hideKeyboard()
            runSearch(text)
        }
    }

    private fun setMicListening(active: Boolean) {
        listening = active
        val mic = findViewById<ImageButton>(R.id.btn_mic) ?: return
        val query = findViewById<EditText>(R.id.query) ?: return
        mic.imageTintList = ColorStateList.valueOf(
            ContextCompat.getColor(this, if (active) R.color.pb_error else R.color.pb_white),
        )
        query.hint = getString(if (active) R.string.voice_listening else R.string.search_hint)
    }

    private fun stopVoice() {
        val speech = recognizer
        recognizer = null
        speech?.setRecognitionListener(null)
        speech?.cancel()
        speech?.destroy()
        if (listening) setMicListening(false)
    }

    private fun focusResults(): Boolean {
        if (!findViewById<View>(R.id.results).isVisible) return false
        val grid = gridFragment?.view?.findViewById<View>(androidx.leanback.R.id.browse_grid) ?: return false
        return grid.requestFocus()
    }

    private fun headerKeys(
        action: (() -> Unit)? = null,
        onLeft: (() -> Unit)? = null,
    ) = View.OnKeyListener { _, keyCode, event ->
        if (event.action != KeyEvent.ACTION_DOWN) return@OnKeyListener false
        when (keyCode) {
            KeyEvent.KEYCODE_DPAD_CENTER, KeyEvent.KEYCODE_ENTER -> {
                if (action == null) false else {
                    action()
                    true
                }
            }
            KeyEvent.KEYCODE_DPAD_LEFT -> {
                if (onLeft == null) false else {
                    onLeft()
                    true
                }
            }
            KeyEvent.KEYCODE_DPAD_DOWN -> focusResults()
            else -> false
        }
    }

    private fun dp(v: Int): Int = (v * resources.displayMetrics.density).toInt()

    companion object {
        private const val STATE_KIND = "kind"
        private const val STATE_SORT = "sort"
        private val HEADER_IDS = setOf(
            R.id.query,
            R.id.kind_movies,
            R.id.kind_series,
            R.id.filter_sort,
            R.id.btn_favourites,
            R.id.btn_settings,
            R.id.btn_mic,
        )
    }
}

class SearchGridFragment : VerticalGridSupportFragment() {
    private lateinit var gridAdapter: ArrayObjectAdapter
    private val pending = ArrayList<TitleItem>()
    private var columns = 0
    private var cardWidth = 0
    private var cardHeight = 0

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val dm = resources.displayMetrics
        val density = dm.density
        val padH = resources.getDimensionPixelSize(R.dimen.shelf_inset)
        val padV = (8 * density).toInt()
        val gap = (8 * density).toInt()
        val chrome = (120 * density).toInt()
        applyFit(GridMetrics.fit(dm.widthPixels, (dm.heightPixels - chrome).coerceAtLeast(1), padH, padV, gap))
        setOnItemViewClickedListener { _, item, _, _ ->
            if (item is TitleItem) {
                startActivity(
                    Intent(requireContext(), DetailsActivity::class.java)
                        .putExtra(DetailsActivity.EXTRA_ID, item.id)
                        .putExtra(DetailsActivity.EXTRA_TITLE, item.title),
                )
            }
        }
    }

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        super.onViewCreated(view, savedInstanceState)
        view.post { refit(view) }
    }

    fun setItems(items: List<TitleItem>) {
        pending.clear()
        pending.addAll(items)
        if (!::gridAdapter.isInitialized) return
        gridAdapter.clear()
        items.forEach { gridAdapter.add(it) }
    }

    private fun refit(view: View) {
        if (view.width <= 0 || view.height <= 0) {
            view.post { refit(view) }
            return
        }
        val density = resources.displayMetrics.density
        val padH = resources.getDimensionPixelSize(R.dimen.shelf_inset)
        val padV = (8 * density).toInt()
        val gap = (8 * density).toInt()
        val fit = GridMetrics.fit(view.width, view.height, padH, padV, gap)
        if (fit.columns != columns || fit.width != cardWidth || fit.height != cardHeight) {
            applyFit(fit)
        }
        view.post {
            val grid = view.findViewById<VerticalGridView>(androidx.leanback.R.id.browse_grid) ?: return@post
            grid.setNumColumns(columns)
            grid.pinPosterGrid()
            grid.setOnKeyInterceptListener { event ->
                if (event.action == KeyEvent.ACTION_DOWN &&
                    event.keyCode == KeyEvent.KEYCODE_DPAD_UP &&
                    grid.selectedPosition < columns
                ) {
                    activity?.findViewById<View>(R.id.query)?.requestFocus() == true
                } else {
                    false
                }
            }
        }
    }

    private fun applyFit(fit: PosterGridFit) {
        columns = fit.columns
        cardWidth = fit.width
        cardHeight = fit.height
        val live = view?.findViewById<VerticalGridView>(androidx.leanback.R.id.browse_grid)
        if (live == null) {
            gridPresenter = VerticalGridPresenter(FocusHighlight.ZOOM_FACTOR_NONE, false).apply {
                numberOfColumns = columns
                shadowEnabled = false
            }
        } else {
            (gridPresenter as? VerticalGridPresenter)?.numberOfColumns = columns
            live.setNumColumns(columns)
        }
        gridAdapter = ArrayObjectAdapter(PosterCardPresenter(cardWidth, cardHeight))
        adapter = gridAdapter
        pending.forEach { gridAdapter.add(it) }
    }
}
