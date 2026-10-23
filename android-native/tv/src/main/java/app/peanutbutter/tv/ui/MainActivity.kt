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
import app.peanutbutter.core.HomeFeed
import app.peanutbutter.tv.R
import app.peanutbutter.tv.asTv
import app.peanutbutter.tv.update.checkForTvUpdate
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

/**
 * Home host — fixed KindSwitch overlay (Flutter Scaffold.header);
 * FeaturedBanner + shelves scroll underneath in [MainFragment].
 */
class MainActivity : FragmentActivity() {
    private var selectedKind: String = "MOVIE"
    /** Skip the first onResume (onCreate already loads); soft-refresh CW after player. */
    private var refreshOnResume = false
    private val feedCache = LinkedHashMap<String, HomeFeed>()
    private var loadJob: Job? = null

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
        // Overlay must sit above the raised header so kind switches never flash shelves.
        findViewById<View>(R.id.loading_overlay).elevation = 32f
        loadHome(showOverlay = true, jumpToHero = true)
        // Once per launch, after the home feed has had a head start.
        window.decorView.postDelayed({ if (!isFinishing) checkForTvUpdate(this) }, 8_000)
        onBackPressedDispatcher.addCallback(this, object : OnBackPressedCallback(true) {
            override fun handleOnBackPressed() = onHomeBack()
        })
    }

    override fun onResume() {
        super.onResume()
        if (refreshOnResume) {
            // Keep shelves + focus — only refresh Continue watching in the background.
            softRefreshContinueWatching()
            browseFragment()?.restoreBrowseFocus()
        }
        refreshOnResume = true
    }

    private fun onHomeBack() {
        if (!focusIsInHeader()) {
            browseFragment()?.scrollToTop()
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
            // Instant swap from cache when available — no empty/placeholder flash.
            val cached = feedCache[kind]
            if (cached != null) {
                browseFragment()?.bindFeed(kind, cached, jumpToHero = true, keepVisible = true)
                // Refresh quietly in the background — CW only, no second full rebuild.
                loadHome(showOverlay = false, jumpToHero = false, fromCache = true)
            } else {
                loadHome(showOverlay = true, jumpToHero = true)
            }
        }

        movies.setOnClickListener { select("MOVIE") }
        series.setOnClickListener { select("SERIES") }
        movies.setOnKeyListener(activateKey { select("MOVIE") })
        series.setOnKeyListener(activateKey { select("SERIES") })

        fun open(intent: Intent) {
            browseFragment()?.captureBrowseFocus()
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

    private fun browseFragment(): MainFragment? =
        supportFragmentManager.findFragmentById(R.id.main_browse_fragment) as? MainFragment

    private fun setLoading(visible: Boolean) {
        findViewById<View>(R.id.loading_overlay).apply {
            isVisible = visible
            isClickable = visible
            isFocusable = visible
            if (visible) bringToFront()
        }
    }

    private fun loadHome(
        showOverlay: Boolean,
        jumpToHero: Boolean,
        fromCache: Boolean = false,
    ) {
        val app = application.asTv()
        val kind = selectedKind
        if (showOverlay) setLoading(true)
        loadJob?.cancel()
        loadJob = lifecycleScope.launch {
            try {
                val feed = app.api.homeFeed(kind)
                feedCache[kind] = feed
                // Ignore stale responses if the user switched tabs mid-flight.
                if (kind != selectedKind) return@launch
                val fragment = browseFragment()
                if (fromCache) {
                    // Already painted from cache — update CW only (no wipe / blink).
                    val ok = fragment?.updateContinueWatching(feed.continueWatching) == true
                    if (!ok && feed.continueWatching.isNotEmpty()) {
                        fragment?.captureBrowseFocus()
                        fragment?.bindFeed(kind, feed, restoreFocus = true)
                    }
                } else {
                    fragment?.bindFeed(kind, feed, jumpToHero = jumpToHero)
                }
                // Warm the other kind so Movie ↔ Series is instant next time.
                prefetchOtherKind(kind)
            } catch (e: Exception) {
                android.util.Log.e("MainActivity", "loadHome failed", e)
                if (showOverlay && !fromCache) {
                    Toast.makeText(
                        this@MainActivity,
                        e.message ?: getString(R.string.error_generic),
                        Toast.LENGTH_LONG,
                    ).show()
                }
            } finally {
                if (kind == selectedKind) setLoading(false)
            }
        }
    }

    private fun softRefreshContinueWatching() {
        val app = application.asTv()
        val kind = selectedKind
        lifecycleScope.launch {
            try {
                val feed = app.api.homeFeed(kind)
                feedCache[kind] = feed
                if (kind != selectedKind) return@launch
                val fragment = browseFragment() ?: return@launch
                val updated = fragment.updateContinueWatching(feed.continueWatching)
                if (!updated && feed.continueWatching.isNotEmpty()) {
                    // CW shelf appeared for the first time — rebuild but restore focus.
                    fragment.captureBrowseFocus()
                    fragment.bindFeed(kind, feed, restoreFocus = true)
                }
            } catch (e: Exception) {
                android.util.Log.w("MainActivity", "softRefresh failed", e)
            }
        }
    }

    private fun prefetchOtherKind(current: String) {
        val other = if (current == "MOVIE") "SERIES" else "MOVIE"
        if (feedCache.containsKey(other)) return
        val app = application.asTv()
        lifecycleScope.launch {
            runCatching { app.api.homeFeed(other) }
                .onSuccess { feedCache[other] = it }
        }
    }

    companion object {
        private const val STATE_KIND = "kind"
    }
}
