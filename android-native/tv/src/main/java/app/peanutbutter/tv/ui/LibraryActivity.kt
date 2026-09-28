package app.peanutbutter.tv.ui

import android.content.Intent
import android.os.Bundle
import android.view.View
import android.widget.TextView
import android.widget.Toast
import androidx.core.view.isVisible
import androidx.leanback.app.VerticalGridSupportFragment
import androidx.leanback.widget.ArrayObjectAdapter
import androidx.leanback.widget.FocusHighlight
import androidx.leanback.widget.VerticalGridPresenter
import androidx.lifecycle.lifecycleScope
import app.peanutbutter.core.TitleItem
import app.peanutbutter.tv.R
import app.peanutbutter.tv.asTv
import kotlinx.coroutines.async
import kotlinx.coroutines.launch

/** Favourites / Watched — catalog sort FAVORITES or WATCHED. */
class LibraryActivity : androidx.fragment.app.FragmentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_browse_host)
        findViewById<android.widget.TextView>(R.id.loading_label).setText(R.string.loading_library)
        if (savedInstanceState == null) {
            supportFragmentManager.beginTransaction()
                .replace(R.id.browse_host, LibraryFragment())
                .commitNow()
        }
    }

    fun setLoading(loading: Boolean) {
        findViewById<View>(R.id.loading_overlay).apply {
            isVisible = loading
            isClickable = loading
            isFocusable = loading
        }
    }

    companion object {
        const val EXTRA_MODE = "mode"
        const val MODE_FAVOURITES = "favourites"
        const val MODE_WATCHED = "watched"
    }
}

class LibraryFragment : VerticalGridSupportFragment() {
    private lateinit var gridAdapter: ArrayObjectAdapter

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val mode = requireActivity().intent.getStringExtra(LibraryActivity.EXTRA_MODE)
            ?: LibraryActivity.MODE_FAVOURITES
        val sort = if (mode == LibraryActivity.MODE_WATCHED) "WATCHED" else "FAVORITES"
        showTitle(false)
        val host = activity as? LibraryActivity
        host?.findViewById<View>(R.id.catalog_header)?.isVisible = true
        host?.findViewById<TextView>(R.id.catalog_heading)?.text = if (mode == LibraryActivity.MODE_WATCHED) {
            getString(R.string.watched)
        } else {
            getString(R.string.favourites)
        }
        host?.findViewById<View>(R.id.filter_sort)?.isVisible = false
        host?.findViewById<View>(R.id.filter_year)?.isVisible = false
        host?.findViewById<View>(R.id.filter_rating)?.isVisible = false
        host?.findViewById<View>(R.id.filter_genre)?.isVisible = false

        GridMetrics.ensure(requireContext())
        gridPresenter = VerticalGridPresenter(FocusHighlight.ZOOM_FACTOR_NONE, false).apply {
            numberOfColumns = GridMetrics.columns
            shadowEnabled = false
        }
        gridAdapter = ArrayObjectAdapter(
            PosterCardPresenter(GridMetrics.cardWidthPx, GridMetrics.cardHeightPx),
        )
        adapter = gridAdapter

        setOnItemViewClickedListener { _, item, _, _ ->
            if (item is TitleItem) {
                startActivity(
                    Intent(requireContext(), DetailsActivity::class.java)
                        .putExtra(DetailsActivity.EXTRA_ID, item.id)
                        .putExtra(DetailsActivity.EXTRA_TITLE, item.title),
                )
            }
        }

        host?.setLoading(true)
        val app = requireActivity().application.asTv()
        lifecycleScope.launch {
            try {
                val movies = async { app.api.catalog(kind = "MOVIE", sort = sort, perPage = 48) }
                val series = async { app.api.catalog(kind = "SERIES", sort = sort, perPage = 48) }
                (movies.await().items + series.await().items).forEach { gridAdapter.add(it) }
                view?.post {
                    view?.findViewById<androidx.leanback.widget.VerticalGridView>(
                        androidx.leanback.R.id.browse_grid,
                    )?.pinPosterGrid()
                }
            } catch (e: Exception) {
                Toast.makeText(requireContext(), e.message, Toast.LENGTH_LONG).show()
            } finally {
                host?.setLoading(false)
            }
        }
    }

    override fun onViewCreated(view: android.view.View, savedInstanceState: Bundle?) {
        super.onViewCreated(view, savedInstanceState)
        view.post {
            view.findViewById<androidx.leanback.widget.VerticalGridView>(
                androidx.leanback.R.id.browse_grid,
            )?.pinPosterGrid()
        }
    }
}
