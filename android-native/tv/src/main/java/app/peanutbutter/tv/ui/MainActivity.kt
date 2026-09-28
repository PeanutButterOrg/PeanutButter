package app.peanutbutter.tv.ui

import android.content.Intent
import android.os.Bundle
import android.view.KeyEvent
import android.view.View
import android.widget.ImageButton
import android.widget.TextView
import android.widget.Toast
import androidx.activity.OnBackPressedCallback
import androidx.core.content.ContextCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.core.view.isVisible
import androidx.fragment.app.FragmentActivity
import androidx.lifecycle.lifecycleScope
import app.peanutbutter.tv.R
import app.peanutbutter.tv.asTv
import kotlinx.coroutines.launch

/**
 * Home host — fixed KindSwitch overlay (Flutter Scaffold.header);
 * FeaturedBanner + shelves scroll underneath in [MainFragment].
 */
class MainActivity : FragmentActivity() {
    private var selectedKind: String = "MOVIE"

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        WindowCompat.setDecorFitsSystemWindows(window, false)
        WindowInsetsControllerCompat(window, window.decorView).apply {
            hide(WindowInsetsCompat.Type.statusBars() or WindowInsetsCompat.Type.navigationBars())
            systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        }
        setContentView(R.layout.activity_main)

        if (savedInstanceState == null) {
            supportFragmentManager.beginTransaction()
                .replace(R.id.main_browse_fragment, MainFragment())
                .commitNow()
        } else {
            selectedKind = savedInstanceState.getString(STATE_KIND, "MOVIE")
        }

        wireHeader()
        loadHome()
        onBackPressedDispatcher.addCallback(this, object : OnBackPressedCallback(true) {
            override fun handleOnBackPressed() = onHomeBack()
        })
    }

    private fun onHomeBack() {
        if (!focusIsInHeader()) {
            (supportFragmentManager.findFragmentById(R.id.main_browse_fragment) as? MainFragment)
                ?.scrollToTop()
            val tab = if (selectedKind == "SERIES") R.id.kind_series else R.id.kind_movies
            findViewById<View>(tab).requestFocus()
            return
        }
        confirmExit()
    }

    private fun focusIsInHeader(): Boolean {
        val header = findViewById<View>(R.id.home_header)
        var node: View? = currentFocus
        while (node != null) {
            if (node === header) return true
            node = node.parent as? View
        }
        return false
    }

    private fun confirmExit() {
        showRoundDialog(
            activity = this,
            title = R.string.exit_app_title,
            message = R.string.exit_app_message,
            negative = R.string.stay,
            positive = R.string.exit_app,
            onPositive = { finish() },
        )
    }

    private fun wireHeader() {
        val movies = findViewById<TextView>(R.id.kind_movies)
        val series = findViewById<TextView>(R.id.kind_series)
        styleKind(movies, series, selectedKind)

        fun select(kind: String) {
            if (kind == selectedKind) return
            selectedKind = kind
            styleKind(movies, series, kind)
            loadHome()
        }

        movies.setOnClickListener { select("MOVIE") }
        series.setOnClickListener { select("SERIES") }
        movies.setOnKeyListener(activateKey { select("MOVIE") })
        series.setOnKeyListener(activateKey { select("SERIES") })

        fun open(intent: Intent) {
            startActivity(intent)
        }

        val fav = findViewById<ImageButton>(R.id.btn_favourites)
        val watched = findViewById<ImageButton>(R.id.btn_watched)
        val search = findViewById<ImageButton>(R.id.btn_search)
        val settings = findViewById<ImageButton>(R.id.btn_settings)

        fav.setOnClickListener {
            open(
                Intent(this, LibraryActivity::class.java)
                    .putExtra(LibraryActivity.EXTRA_MODE, LibraryActivity.MODE_FAVOURITES),
            )
        }
        watched.setOnClickListener {
            open(
                Intent(this, LibraryActivity::class.java)
                    .putExtra(LibraryActivity.EXTRA_MODE, LibraryActivity.MODE_WATCHED),
            )
        }
        search.setOnClickListener {
            open(Intent(this, SearchActivity::class.java))
        }
        settings.setOnClickListener {
            open(Intent(this, SettingsActivity::class.java))
        }
        // TV D-pad: ensure Select fires even if click delivery is flaky
        fav.setOnKeyListener(activateKey {
            open(
                Intent(this, LibraryActivity::class.java)
                    .putExtra(LibraryActivity.EXTRA_MODE, LibraryActivity.MODE_FAVOURITES),
            )
        })
        watched.setOnKeyListener(activateKey {
            open(
                Intent(this, LibraryActivity::class.java)
                    .putExtra(LibraryActivity.EXTRA_MODE, LibraryActivity.MODE_WATCHED),
            )
        })
        search.setOnKeyListener(activateKey {
            open(Intent(this, SearchActivity::class.java))
        })
        settings.setOnKeyListener(activateKey {
            open(Intent(this, SettingsActivity::class.java))
        })

        findViewById<View>(R.id.home_header).bringToFront()
        // Keep header above Leanback scroll content; never scroll with rows
        findViewById<View>(R.id.home_header).elevation = 24f
        findViewById<View>(R.id.main_browse_fragment).elevation = 0f
    }

    private fun styleKind(movies: TextView, series: TextView, selected: String) {
        val seed = ContextCompat.getColor(this, R.color.pb_seed)
        val muted = ContextCompat.getColor(this, R.color.pb_muted)
        movies.setTextColor(if (selected == "MOVIE") seed else muted)
        movies.setTypeface(null, if (selected == "MOVIE") android.graphics.Typeface.BOLD else android.graphics.Typeface.NORMAL)
        series.setTextColor(if (selected == "SERIES") seed else muted)
        series.setTypeface(null, if (selected == "SERIES") android.graphics.Typeface.BOLD else android.graphics.Typeface.NORMAL)
    }

    private fun activateKey(action: () -> Unit) = View.OnKeyListener { _, keyCode, event ->
        if (event.action == KeyEvent.ACTION_DOWN &&
            (keyCode == KeyEvent.KEYCODE_DPAD_CENTER || keyCode == KeyEvent.KEYCODE_ENTER)
        ) {
            action()
            true
        } else false
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        outState.putString(STATE_KIND, selectedKind)
    }

    private fun loadHome() {
        val app = application.asTv()
        findViewById<View>(R.id.loading_overlay).isVisible = true
        lifecycleScope.launch {
            try {
                val feed = app.api.homeFeed(selectedKind)
                val fragment = supportFragmentManager
                    .findFragmentById(R.id.main_browse_fragment) as? MainFragment
                fragment?.bindFeed(selectedKind, feed)
                findViewById<View>(R.id.loading_overlay).apply {
                    isVisible = false
                    isClickable = false
                    isFocusable = false
                }
            } catch (e: Exception) {
                android.util.Log.e("MainActivity", "loadHome failed", e)
                findViewById<View>(R.id.loading_overlay).apply {
                    isVisible = false
                    isClickable = false
                    isFocusable = false
                }
                Toast.makeText(
                    this@MainActivity,
                    e.message ?: getString(R.string.error_generic),
                    Toast.LENGTH_LONG,
                ).show()
            }
        }
    }

    companion object {
        private const val STATE_KIND = "kind"
    }
}
