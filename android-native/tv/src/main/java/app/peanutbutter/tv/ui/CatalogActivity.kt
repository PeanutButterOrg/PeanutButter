package app.peanutbutter.tv.ui

import android.app.AlertDialog
import android.content.Intent
import android.os.Bundle
import android.util.Log
import android.view.KeyEvent
import android.view.View
import android.view.ViewGroup
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import androidx.activity.OnBackPressedCallback
import androidx.core.view.isVisible
import androidx.leanback.app.VerticalGridSupportFragment
import androidx.leanback.widget.ArrayObjectAdapter
import androidx.leanback.widget.FocusHighlight
import androidx.leanback.widget.VerticalGridPresenter
import androidx.leanback.widget.VerticalGridView
import androidx.lifecycle.lifecycleScope
import app.peanutbutter.core.TitleItem
import app.peanutbutter.tv.R
import app.peanutbutter.tv.asTv
import kotlinx.coroutines.launch

class CatalogActivity : androidx.fragment.app.FragmentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_browse_host)
        if (savedInstanceState == null) {
            supportFragmentManager.beginTransaction()
                .replace(R.id.browse_host, CatalogFragment())
                .commitNow()
        }
        findViewById<View>(R.id.catalog_header).isVisible = true
        val sort = intent.getStringExtra(EXTRA_SORT)?.takeIf { it.isNotBlank() } ?: "TRENDING"
        val kind = intent.getStringExtra(EXTRA_KIND)?.takeIf { it.isNotBlank() }
        refreshHeading(sort, kind)
        findViewById<TextView>(R.id.filter_sort).setOnClickListener { pickSort(sort, kind) }
        findViewById<TextView>(R.id.filter_year).setOnClickListener { pickYear() }
        findViewById<TextView>(R.id.filter_rating).setOnClickListener { pickRating() }
        findViewById<TextView>(R.id.filter_genre).setOnClickListener { pickGenre() }
        val downToGrid = View.OnKeyListener { _, keyCode, event ->
            if (event.action == KeyEvent.ACTION_DOWN && keyCode == KeyEvent.KEYCODE_DPAD_DOWN) {
                catalog()?.view?.findViewById<View>(androidx.leanback.R.id.browse_grid)?.requestFocus() == true
            } else {
                false
            }
        }
        listOf(R.id.filter_sort, R.id.filter_year, R.id.filter_rating, R.id.filter_genre).forEach {
            findViewById<View>(it).setOnKeyListener(downToGrid)
        }
        onBackPressedDispatcher.addCallback(this, object : OnBackPressedCallback(true) {
            override fun handleOnBackPressed() {
                val focused = currentFocus
                if (focused != null && focused.rootView !== window.decorView) {
                    isEnabled = false
                    onBackPressedDispatcher.onBackPressed()
                    isEnabled = true
                    return
                }
                val sortButton = findViewById<View>(R.id.filter_sort)
                if (currentFocus !== sortButton) {
                    catalog()?.view?.findViewById<VerticalGridView>(androidx.leanback.R.id.browse_grid)
                        ?.setSelectedPosition(0)
                    sortButton.requestFocus()
                } else {
                    finish()
                }
            }
        })
    }

    private fun catalog(): CatalogFragment? =
        supportFragmentManager.findFragmentById(R.id.browse_host) as? CatalogFragment

    private fun refreshHeading(sort: String, kind: String?) {
        findViewById<TextView>(R.id.catalog_heading).text = heading(sort, kind)
        val label = SORTS.firstOrNull { it.first == sort }?.second?.let { getString(it) } ?: sort
        findViewById<TextView>(R.id.filter_sort).text = getString(R.string.sort_value, label)
    }

    private fun heading(sort: String, kind: String?): String {
        val sortLabel = SORTS.firstOrNull { it.first == sort }?.second?.let { getString(it) } ?: getString(R.string.see_all)
        if (sort == "CONTINUE_WATCHING" && kind == null) return sortLabel
        val kindLabel = when (kind) {
            "MOVIE" -> getString(R.string.heading_movies)
            "SERIES" -> getString(R.string.heading_series)
            "ANIME" -> getString(R.string.heading_anime)
            else -> getString(R.string.heading_titles)
        }
        return "$sortLabel $kindLabel"
    }

    private fun pickSort(current: String, kind: String?) {
        showChoices(getString(R.string.sort), SORTS.map { it.first to getString(it.second) }) { key ->
            refreshHeading(key, kind)
            catalog()?.applySort(key)
            findViewById<TextView>(R.id.filter_sort).setOnClickListener { pickSort(key, kind) }
        }
    }

    private fun pickYear() {
        val now = java.util.Calendar.getInstance().get(java.util.Calendar.YEAR)
        val options = ArrayList<Pair<String, String>>()
        options += "" to getString(R.string.filter_any_year)
        for (year in now downTo 1970) options += year.toString() to year.toString()
        showChoices(getString(R.string.filter_year), options) { value ->
            val year = value.toIntOrNull()
            findViewById<TextView>(R.id.filter_year).text =
                year?.toString() ?: getString(R.string.filter_year)
            catalog()?.applyYear(year)
        }
    }

    private fun pickRating() {
        val options = listOf(
            "" to getString(R.string.filter_any_rating),
            "9" to "9+",
            "8" to "8+",
            "7" to "7+",
            "6" to "6+",
            "5" to "5+",
        )
        showChoices(getString(R.string.filter_rating), options) { value ->
            val min = value.toDoubleOrNull()
            findViewById<TextView>(R.id.filter_rating).text =
                if (min == null) getString(R.string.filter_rating) else "${min.toInt()}+"
            catalog()?.applyRating(min)
        }
    }

    private fun pickGenre() {
        lifecycleScope.launch {
            val names = runCatching { application.asTv().api.genres() }.getOrDefault(emptyList())
            val options = listOf("" to getString(R.string.filter_all_genres)) + names.map { it to it }
            showChoices(getString(R.string.filter_genre), options) { value ->
                findViewById<TextView>(R.id.filter_genre).text =
                    value.ifBlank { getString(R.string.filter_genre) }
                catalog()?.applyGenre(value.ifBlank { null })
            }
        }
    }

    private fun showChoices(title: String, options: List<Pair<String, String>>, onPick: (String) -> Unit) {
        val col = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            val pad = (16 * resources.displayMetrics.density).toInt()
            setPadding(pad, pad / 2, pad, pad / 2)
        }
        val dialog = AlertDialog.Builder(this)
            .setTitle(title)
            .setView(ScrollView(this).apply {
                addView(col, ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
            })
            .setNegativeButton(android.R.string.cancel, null)
            .create()
        options.forEachIndexed { index, (value, label) ->
            val row = TextView(this).apply {
                text = label
                textSize = 16f
                setTextColor(getColor(R.color.pb_white))
                val py = (12 * resources.displayMetrics.density).toInt()
                setPadding(py, py, py, py)
                isFocusable = true
                background = getDrawable(R.drawable.kind_tab_bg)
                setOnClickListener {
                    dialog.dismiss()
                    onPick(value)
                }
            }
            val lp = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT)
            if (index > 0) lp.topMargin = (8 * resources.displayMetrics.density).toInt()
            col.addView(row, lp)
        }
        dialog.setOnShowListener { (col.getChildAt(0) as? TextView)?.requestFocus() }
        dialog.show()
    }

    fun setLoading(loading: Boolean) {
        findViewById<View>(R.id.loading_overlay).apply {
            isVisible = loading
            isClickable = loading
            isFocusable = loading
        }
    }

    companion object {
        const val EXTRA_TITLE = "catalog_title"
        const val EXTRA_KIND = "catalog_kind"
        const val EXTRA_SORT = "catalog_sort"

        val SORTS = listOf(
            "TRENDING" to R.string.trending,
            "POPULARITY" to R.string.popular,
            "DATE_ADDED" to R.string.last_added,
            "CONTINUE_WATCHING" to R.string.continue_watching,
            "YEAR" to R.string.sort_year,
            "RATING" to R.string.sort_rating,
            "ROTTEN_TOMATOES" to R.string.sort_rt,
            "TITLE" to R.string.sort_title,
        )
    }
}

class CatalogFragment : VerticalGridSupportFragment() {
    private lateinit var gridAdapter: ArrayObjectAdapter
    private val loaded = ArrayList<TitleItem>()
    private var columns = 0
    private var cardWidth = 0
    private var cardHeight = 0
    private var kind: String? = null
    private var sort: String = "TRENDING"
    private var year: Int? = null
    private var ratingMin: Double? = null
    private var genre: String? = null
    private var page = 1
    private var loading = false
    private var hasNext = true
    private var loadGen = 0

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val intent = requireActivity().intent
        showTitle(false)
        kind = intent.getStringExtra(CatalogActivity.EXTRA_KIND)?.takeIf { it.isNotBlank() }
        sort = intent.getStringExtra(CatalogActivity.EXTRA_SORT)?.takeIf { it.isNotBlank() } ?: "TRENDING"

        val dm = resources.displayMetrics
        val density = dm.density
        val padH = resources.getDimensionPixelSize(R.dimen.shelf_inset)
        val padV = (8 * density).toInt()
        val gap = (8 * density).toInt()
        val chrome = (52 * density).toInt()
        applyFit(
            GridMetrics.fit(
                dm.widthPixels,
                (dm.heightPixels - chrome).coerceAtLeast(1),
                padH,
                padV,
                gap,
            ),
        )

        setOnItemViewClickedListener { _, item, _, _ ->
            if (item is TitleItem) {
                startActivity(
                    Intent(requireContext(), DetailsActivity::class.java)
                        .putExtra(DetailsActivity.EXTRA_ID, item.id)
                        .putExtra(DetailsActivity.EXTRA_TITLE, item.title),
                )
            }
        }

        setOnItemViewSelectedListener { _, item, _, _ ->
            if (item == null) return@setOnItemViewSelectedListener
            val idx = gridAdapter.indexOf(item)
            if (idx >= 0 && hasNext && !loading && idx >= gridAdapter.size() - 8) {
                loadMore()
            }
        }

        loadMore()
    }

    fun applySort(next: String) {
        if (next == sort) return
        sort = next
        reload()
    }

    fun applyYear(next: Int?) {
        if (next == year) return
        year = next
        reload()
    }

    fun applyRating(next: Double?) {
        if (next == ratingMin) return
        ratingMin = next
        reload()
    }

    fun applyGenre(next: String?) {
        if (next == genre) return
        genre = next
        reload()
    }

    private fun reload() {
        page = 1
        hasNext = true
        loadGen++
        loading = false
        loaded.clear()
        gridAdapter.clear()
        loadMore()
    }

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        super.onViewCreated(view, savedInstanceState)
        view.post { refit(view) }
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
                if (event.action == KeyEvent.ACTION_DOWN && event.keyCode == KeyEvent.KEYCODE_DPAD_UP) {
                    if (grid.selectedPosition < columns.coerceAtLeast(1)) {
                        val sort = activity?.findViewById<View>(R.id.filter_sort)
                        if (sort != null && sort.isVisible) {
                            sort.requestFocus()
                            return@setOnKeyInterceptListener true
                        }
                    }
                }
                false
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
        loaded.forEach { gridAdapter.add(it) }
    }

    private fun loadMore() {
        if (loading || !hasNext) return
        loading = true
        val host = activity as? CatalogActivity
        // Full-screen busy only on first page
        if (page == 1) host?.setLoading(true)
        val app = requireActivity().application.asTv()
        val pageToLoad = page
        val gen = loadGen
        val sortNow = sort
        lifecycleScope.launch {
            try {
                val result = app.api.catalog(
                    kind = kind,
                    sort = sortNow,
                    page = pageToLoad,
                    perPage = 48,
                    genre = genre,
                    yearMin = year,
                    yearMax = year,
                    ratingMin = ratingMin,
                )
                if (gen != loadGen) return@launch
                result.items.forEach {
                    loaded.add(it)
                    gridAdapter.add(it)
                }
                hasNext = result.hasNextPage
                page = pageToLoad + 1
            } catch (e: Exception) {
                Log.e(TAG, "catalog load failed kind=$kind sort=$sort", e)
                Toast.makeText(
                    requireContext(),
                    e.message ?: getString(R.string.error_generic),
                    Toast.LENGTH_LONG,
                ).show()
                hasNext = false
            } finally {
                if (gen == loadGen) {
                    loading = false
                    host?.setLoading(false)
                }
            }
        }
    }

    companion object {
        private const val TAG = "CatalogFragment"
    }
}
