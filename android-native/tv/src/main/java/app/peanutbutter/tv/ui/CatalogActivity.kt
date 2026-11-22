package app.peanutbutter.tv.ui

import app.peanutbutter.tv.ui.compose.setPbContent
import android.content.Intent
import android.os.Bundle
import android.util.Log
import android.widget.Toast
import androidx.activity.compose.setContent
import androidx.fragment.app.FragmentActivity
import androidx.lifecycle.lifecycleScope
import app.peanutbutter.core.TitleItem
import app.peanutbutter.tv.R
import app.peanutbutter.tv.asTv
import kotlinx.coroutines.launch

/**
 * Explore and the See all pages, drawn like the desktop's ([CatalogScreen]):
 * the name with filter boxes top right, #1 featured, then a poster grid that
 * pages in as you scroll.
 */
class CatalogActivity : FragmentActivity(), CatalogActions {
    private val ui = CatalogState()
    private var kind: String? = null
    private var sort: String = "TRENDING"
    private var year: Int? = null
    private var ratingMin: Double? = null
    private var genre: String? = null
    private var service: String? = null
    private var page = 1
    private var loading = false
    private var hasNext = true
    private var loadGen = 0
    /** Explore's own name; null on See all pages. */
    private var explore: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        sort = intent.getStringExtra(EXTRA_SORT)?.takeIf { it.isNotBlank() } ?: "TRENDING"
        kind = intent.getStringExtra(EXTRA_KIND)?.takeIf { it.isNotBlank() }
        explore = if (intent.getBooleanExtra(EXTRA_EXPLORE, false)) intent.getStringExtra(EXTRA_TITLE) else null
        // Explore: a Type picker in place of the sort (it's always trending first).
        if (explore != null) {
            ui.filters += CatalogFilter("kind", getString(R.string.filter_movies_and_series))
        } else {
            ui.filters += CatalogFilter("sort", "")
        }
        ui.filters += CatalogFilter("year", getString(R.string.filter_any_year))
        ui.filters += CatalogFilter("rating", getString(R.string.filter_any_rating))
        ui.filters += CatalogFilter("genre", getString(R.string.filter_all_genres))
        ui.filters += CatalogFilter("service", getString(R.string.filter_all_services)).apply { visible = false }
        refreshHeading()
        if (sort == "TRENDING") showServiceFilterIfAny()
        setPbContent { CatalogScreen(ui, this) }
        loadMore()
    }

    private fun filter(key: String) = ui.filters.first { it.key == key }

    private fun refreshHeading() {
        ui.heading = explore ?: heading(sort, kind)
        val label = SORTS.firstOrNull { it.first == sort }?.second?.let { getString(it) } ?: sort
        ui.filters.firstOrNull { it.key == "sort" }?.label = getString(R.string.sort_value, label)
        // Your own lists stay a plain grid; browse lists get the featured top.
        ui.featured = sort !in setOf("CONTINUE_WATCHING", "FAVORITES", "WATCHED")
        ui.eyebrow = if (explore != null) "#1 trending" else "#1 in ${ui.heading}"
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
        // Sorts that aren't a list name read as a phrase ("Top rated series",
        // "Movies by year"), not "Rating series" / "Year movies".
        val kindTitle = kindLabel.replaceFirstChar { it.titlecase(java.util.Locale.US) }
        return when (sort) {
            "RATING" -> "Top rated $kindLabel"
            "YEAR" -> "$kindTitle by year"
            "TITLE" -> "$kindTitle A–Z"
            "ROTTEN_TOMATOES" -> "$kindTitle by Rotten Tomatoes"
            else -> "$sortLabel $kindLabel"
        }
    }

    // ---- CatalogActions ----

    override fun back() = finish()

    override fun open(item: TitleItem, play: Boolean) {
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

    override fun openFilter(key: String) {
        when (key) {
            "sort" -> showChoices(key, SORTS.map { it.first to getString(it.second) }, sort) { value ->
                if (value == sort) return@showChoices
                sort = value
                refreshHeading()
                // The Provider box belongs to Trending only.
                if (value == "TRENDING") showServiceFilterIfAny() else filter("service").visible = false
                reload()
            }
            "kind" -> {
                val options = listOf(
                    "" to getString(R.string.filter_movies_and_series),
                    "MOVIE" to getString(R.string.heading_movies).replaceFirstChar { it.titlecase(java.util.Locale.US) },
                    "SERIES" to getString(R.string.heading_series).replaceFirstChar { it.titlecase(java.util.Locale.US) },
                )
                showChoices(key, options, kind ?: "") { value ->
                    val next = value.ifBlank { null }
                    filter(key).label = options.first { it.first == value }.second
                    filter(key).active = next != null
                    if (next != kind) {
                        kind = next
                        reload()
                    }
                }
            }
            "year" -> {
                val now = java.util.Calendar.getInstance().get(java.util.Calendar.YEAR)
                val options = listOf("" to getString(R.string.filter_any_year)) +
                    (now downTo 1970).map { it.toString() to it.toString() }
                showChoices(key, options, year?.toString() ?: "") { value ->
                    val next = value.toIntOrNull()
                    filter(key).label = next?.toString() ?: getString(R.string.filter_any_year)
                    filter(key).active = next != null
                    if (next != year) {
                        year = next
                        reload()
                    }
                }
            }
            "rating" -> {
                val options = listOf("" to getString(R.string.filter_any_rating)) +
                    listOf(9, 8, 7, 6, 5).map { "$it" to "$it+" }
                showChoices(key, options, ratingMin?.toInt()?.toString() ?: "") { value ->
                    val next = value.toDoubleOrNull()
                    filter(key).label = if (next == null) getString(R.string.filter_any_rating) else "${next.toInt()}+"
                    filter(key).active = next != null
                    if (next != ratingMin) {
                        ratingMin = next
                        reload()
                    }
                }
            }
            "genre" -> lifecycleScope.launch {
                val names = runCatching { application.asTv().api.genres(kind) }.getOrDefault(emptyList())
                val options = listOf("" to getString(R.string.filter_all_genres)) + names.map { it to it }
                showChoices(key, options, genre ?: "") { value ->
                    val next = value.ifBlank { null }
                    filter(key).label = next ?: getString(R.string.filter_all_genres)
                    filter(key).active = next != null
                    if (next != genre) {
                        genre = next
                        reload()
                    }
                }
            }
            "service" -> lifecycleScope.launch {
                val services = runCatching { application.asTv().api.streamingServices(kind) }.getOrDefault(emptyList())
                val options = listOf("" to getString(R.string.filter_all_services)) + services.map { it.id to it.name }
                showChoices(key, options, service ?: "") { value ->
                    val next = value.ifBlank { null }
                    filter(key).label = services.firstOrNull { it.id == value }?.name ?: getString(R.string.filter_all_services)
                    filter(key).active = next != null
                    if (next != service) {
                        service = next
                        reload()
                    }
                }
            }
        }
    }

    private fun showChoices(key: String, options: List<Pair<String, String>>, current: String, onPick: (String) -> Unit) {
        ui.menu = FilterMenu(key, options, current, onPick)
    }

    /** Trending only: the Provider box shows when catalog add-ons supply services. */
    private fun showServiceFilterIfAny() {
        lifecycleScope.launch {
            val services = runCatching { application.asTv().api.streamingServices(kind) }.getOrDefault(emptyList())
            filter("service").visible = services.isNotEmpty() && sort == "TRENDING"
        }
    }

    private fun reload() {
        page = 1
        hasNext = true
        loadGen++
        loading = false
        ui.items.clear()
        ui.empty = false
        ui.done = false
        ui.loadingMore = false
        ui.reset++
        loadMore()
    }

    override fun loadMore() {
        if (loading || !hasNext) return
        loading = true
        // Full-screen busy on the first page, a spinner under the grid for the next ones.
        if (page == 1) ui.loading = true else ui.loadingMore = true
        val app = application.asTv()
        val pageToLoad = page
        val gen = loadGen
        val sortNow = sort
        lifecycleScope.launch {
            try {
                val result = app.api.catalog(
                    kind = kind,
                    sort = sortNow,
                    page = pageToLoad,
                    perPage = PER_PAGE,
                    genre = genre,
                    yearMin = year,
                    yearMax = year,
                    ratingMin = ratingMin,
                    // The Provider box only shows on Trending.
                    service = service.takeIf { sortNow == "TRENDING" },
                )
                if (gen != loadGen) return@launch
                val have = ui.items.map { it.id }.toHashSet()
                ui.items.addAll(result.items.filter { have.add(it.id) })
                hasNext = result.hasNextPage
                if (pageToLoad == 1) ui.empty = ui.items.isEmpty()
                ui.done = !hasNext && ui.items.isNotEmpty()
                // A short page: the server is still bringing titles in. Ask for it
                // again, or the ones landing in the gap are skipped.
                if (result.items.size >= PER_PAGE || !result.hasNextPage) page = pageToLoad + 1
            } catch (e: Exception) {
                Log.e(TAG, "catalog load failed kind=$kind sort=$sort", e)
                Toast.makeText(this@CatalogActivity, e.message ?: getString(R.string.error_generic), Toast.LENGTH_LONG).show()
                // Keep paging: the next scroll tries again.
            } finally {
                if (gen == loadGen) {
                    loading = false
                    ui.loading = false
                    ui.loadingMore = false
                }
            }
        }
    }

    companion object {
        private const val TAG = "CatalogActivity"
        private const val PER_PAGE = 48
        const val EXTRA_TITLE = "catalog_title"
        /** The Explore tab: its name as the heading, a Type picker, trending first. */
        const val EXTRA_EXPLORE = "catalog_explore"
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
