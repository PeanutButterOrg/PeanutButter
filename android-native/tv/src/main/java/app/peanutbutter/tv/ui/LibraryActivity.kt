package app.peanutbutter.tv.ui

import android.content.Intent
import android.os.Bundle
import android.widget.Toast
import androidx.activity.compose.setContent
import androidx.fragment.app.FragmentActivity
import androidx.lifecycle.lifecycleScope
import app.peanutbutter.tv.R
import app.peanutbutter.tv.asTv
import kotlinx.coroutines.async
import kotlinx.coroutines.launch

/** My List (favourites) and Watched, drawn like the desktop's ([LibraryScreen]). */
class LibraryActivity : FragmentActivity() {
    private val ui = LibraryState()
    private var sort = "FAVORITES"
    private var loadedOnce = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val watched = intent.getStringExtra(EXTRA_MODE) == MODE_WATCHED
        sort = if (watched) "WATCHED" else "FAVORITES"
        ui.title = getString(if (watched) R.string.watched else R.string.my_list)
        ui.emptyMessage = getString(if (watched) R.string.empty_watched else R.string.empty_favourites)
        ui.keepWatching = !watched
        setContent {
            LibraryScreen(ui, onBack = { finish() }) { item ->
                startActivity(
                    Intent(this, DetailsActivity::class.java)
                        .putExtra(DetailsActivity.EXTRA_ID, item.id)
                        .putExtra(DetailsActivity.EXTRA_TITLE, item.displayTitle),
                )
            }
        }
        reload(firstLoad = true)
    }

    override fun onResume() {
        super.onResume()
        // Back from a title page: it may have left the list (or been watched).
        if (loadedOnce) reload(firstLoad = false)
    }

    private fun reload(firstLoad: Boolean) {
        val app = application.asTv()
        if (firstLoad) ui.loading = true
        lifecycleScope.launch {
            try {
                val movies = async { app.api.catalog(kind = "MOVIE", sort = sort, perPage = 48) }
                val series = async { app.api.catalog(kind = "SERIES", sort = sort, perPage = 48) }
                val items = movies.await().items + series.await().items
                ui.items.clear()
                ui.items.addAll(items)
            } catch (e: Exception) {
                if (firstLoad) Toast.makeText(this@LibraryActivity, e.message, Toast.LENGTH_LONG).show()
            } finally {
                loadedOnce = true
                ui.loading = false
            }
        }
    }

    companion object {
        const val EXTRA_MODE = "mode"
        const val MODE_FAVOURITES = "favourites"
        const val MODE_WATCHED = "watched"
    }
}
