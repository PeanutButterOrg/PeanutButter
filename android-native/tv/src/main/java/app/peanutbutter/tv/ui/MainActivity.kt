package app.peanutbutter.tv.ui

import android.content.Intent
import android.os.Bundle
import android.view.KeyEvent
import android.view.View
import android.widget.TextView
import android.widget.Toast
import androidx.activity.OnBackPressedCallback
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.core.view.isVisible
import androidx.fragment.app.FragmentActivity
import androidx.lifecycle.lifecycleScope
import app.peanutbutter.core.HomeFeed
import app.peanutbutter.core.HomeSections
import app.peanutbutter.tv.R
import app.peanutbutter.tv.asTv
import app.peanutbutter.tv.update.checkForTvUpdate
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.launch

/**
 * Home host — fixed top bar overlay (Home · Movies · Series · My List · Explore);
 * hero + shelves scroll underneath in [MainFragment].
 */
class MainActivity : FragmentActivity() {
    /** HOME, MOVIE or SERIES. */
    private var selectedKind: String = HomeSections.HOME
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
            selectedKind = savedInstanceState.getString(STATE_KIND, HomeSections.HOME)
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
        // New episodes of followed series, as notifications.
        lifecycleScope.launch { runCatching { app.peanutbutter.tv.EpisodeNotifier.deliver(this@MainActivity) } }
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
            findViewById<View>(tabFor(selectedKind)).requestFocus()
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

    private fun tabFor(section: String) = when (section) {
        "MOVIE" -> R.id.kind_movies
        "SERIES" -> R.id.kind_series
        else -> R.id.tab_home
    }

    private fun wireHeader() {
        findViewById<TextView>(R.id.brand).text = android.text.SpannableStringBuilder("Peanut").apply {
            append("Butter", android.text.style.ForegroundColorSpan(getColor(R.color.pbt_focus)), 0)
        }
        styleSections(selectedKind)

        fun select(section: String) {
            if (section == selectedKind) return
            selectedKind = section
            styleSections(section)
            // Instant swap from cache when available — no empty/placeholder flash.
            val cached = layoutFromCache(section)
            if (cached != null) {
                browseFragment()?.bindLayout(section, cached, jumpToHero = true, keepVisible = true)
                // Refresh quietly in the background — CW only, no second full rebuild.
                loadHome(showOverlay = false, jumpToHero = false, fromCache = true)
            } else {
                loadHome(showOverlay = true, jumpToHero = true)
            }
        }

        fun open(intent: Intent) {
            browseFragment()?.captureBrowseFocus()
            startActivity(intent)
        }

        fun library(mode: String) = Intent(this, LibraryActivity::class.java)
            .putExtra(LibraryActivity.EXTRA_MODE, mode)

        val actions = mapOf<Int, () -> Unit>(
            R.id.tab_home to { select(HomeSections.HOME) },
            R.id.kind_movies to { select("MOVIE") },
            R.id.kind_series to { select("SERIES") },
            R.id.tab_explore to {
                open(
                    Intent(this, CatalogActivity::class.java)
                        .putExtra(CatalogActivity.EXTRA_TITLE, getString(R.string.explore))
                        .putExtra(CatalogActivity.EXTRA_SORT, "POPULARITY"),
                )
            },
            R.id.btn_search to { open(Intent(this, SearchActivity::class.java)) },
            // The device square: My List, Watched and Settings; profiles later.
            R.id.btn_settings to {
                showRoundListDialog(
                    activity = this,
                    title = getString(R.string.this_device),
                    options = listOf(getString(R.string.my_list), getString(R.string.watched), getString(R.string.settings)),
                ) { pick ->
                    when (pick) {
                        0 -> open(library(LibraryActivity.MODE_FAVOURITES))
                        1 -> open(library(LibraryActivity.MODE_WATCHED))
                        else -> open(Intent(this, SettingsActivity::class.java))
                    }
                }
            },
        )
        for ((id, action) in actions) {
            val v = findViewById<View>(id)
            v.setOnClickListener { action() }
            // TV D-pad: ensure Select fires even if click delivery is flaky
            v.setOnKeyListener(activateKey(action))
        }

        findViewById<View>(R.id.home_header).bringToFront()
        // Keep header above Leanback scroll content; never scroll with rows
        findViewById<View>(R.id.home_header).elevation = 24f
        findViewById<View>(R.id.main_browse_fragment).elevation = 0f
        window.decorView.viewTreeObserver.addOnGlobalFocusChangeListener { _, _ -> updateHeaderScrim() }
    }

    private var headerScrolled = false

    /**
     * Light fade over the hero; once focus is down in the rows (which then sit
     * under the tabs), a near-solid bar so posters don't show through the
     * labels. Same as the desktop home header.
     */
    private fun updateHeaderScrim() {
        val scrolled = !focusIsInHeader() && (browseFragment()?.selectedPosition ?: 0) > 0
        if (scrolled == headerScrolled) return
        headerScrolled = scrolled
        findViewById<View>(R.id.home_header).setBackgroundResource(
            if (scrolled) R.drawable.home_header_solid else R.drawable.home_header_gradient,
        )
    }

    /** Selected section: white with the amber underline; the rest muted. */
    private fun styleSections(selected: String) {
        val on = getColor(R.color.pbt_text)
        val off = getColor(R.color.pbt_text_muted)
        for (id in listOf(R.id.tab_home, R.id.kind_movies, R.id.kind_series, R.id.tab_explore)) {
            val tab = findViewById<TextView>(id)
            val active = id == tabFor(selected)
            tab.setTextColor(if (active) on else off)
            tab.setCompoundDrawablesRelativeWithIntrinsicBounds(
                0, 0, 0, if (active) R.drawable.tab_underline else R.drawable.tab_underline_off,
            )
        }
    }

    /** The section's layout from cached feeds, or null if a feed it needs isn't in yet. */
    private fun layoutFromCache(section: String): app.peanutbutter.core.HomeLayout? {
        val movies = feedCache["MOVIE"]
        val series = feedCache["SERIES"]
        return when (section) {
            "MOVIE" -> movies?.let { HomeSections.build(section, it, null) }
            "SERIES" -> series?.let { HomeSections.build(section, null, it) }
            else -> if (movies != null && series != null) HomeSections.build(section, movies, series) else null
        }
    }

    /** Feeds a section needs: Home shows movies and series. */
    private fun kindsFor(section: String) =
        if (section == HomeSections.HOME) listOf("MOVIE", "SERIES") else listOf(section)

    private suspend fun fetchFeeds(section: String): app.peanutbutter.core.HomeLayout {
        val app = application.asTv()
        val feeds = kotlinx.coroutines.coroutineScope {
            kindsFor(section).map { kind -> kind to async { app.api.homeFeed(kind) } }
                .associate { (kind, job) -> kind to job.await() }
        }
        feedCache.putAll(feeds)
        return HomeSections.build(section, feeds["MOVIE"], feeds["SERIES"])
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
        val section = selectedKind
        if (showOverlay) setLoading(true)
        loadJob?.cancel()
        loadJob = lifecycleScope.launch {
            try {
                val layout = fetchFeeds(section)
                // Ignore stale responses if the user switched sections mid-flight.
                if (section != selectedKind) return@launch
                val fragment = browseFragment()
                val cw = layout.shelves.firstOrNull { it.sort == "CONTINUE_WATCHING" }?.items.orEmpty()
                if (fromCache) {
                    // Already painted from cache — update CW only (no wipe / blink).
                    val ok = fragment?.updateContinueWatching(cw) == true
                    if (!ok && cw.isNotEmpty()) {
                        fragment?.captureBrowseFocus()
                        fragment?.bindLayout(section, layout, restoreFocus = true)
                    }
                } else {
                    fragment?.bindLayout(section, layout, jumpToHero = jumpToHero)
                }
                // Warm the other feed so switching sections is instant next time.
                prefetchMissing()
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
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
                if (section == selectedKind) setLoading(false)
            }
        }
    }

    private fun softRefreshContinueWatching() {
        val section = selectedKind
        lifecycleScope.launch {
            try {
                // The player's last save may still be on its way.
                application.asTv().awaitWrites()
                val layout = fetchFeeds(section)
                if (section != selectedKind) return@launch
                val fragment = browseFragment() ?: return@launch
                val cw = layout.shelves.firstOrNull { it.sort == "CONTINUE_WATCHING" }?.items.orEmpty()
                val updated = fragment.updateContinueWatching(cw)
                if (!updated && cw.isNotEmpty()) {
                    // CW shelf appeared for the first time — rebuild but restore focus.
                    fragment.captureBrowseFocus()
                    fragment.bindLayout(section, layout, restoreFocus = true)
                }
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: Exception) {
                android.util.Log.w("MainActivity", "softRefresh failed", e)
            }
        }
    }

    private fun prefetchMissing() {
        val app = application.asTv()
        for (kind in listOf("MOVIE", "SERIES")) {
            if (feedCache.containsKey(kind)) continue
            lifecycleScope.launch {
                runCatching { app.api.homeFeed(kind) }.onSuccess { feedCache[kind] = it }
            }
        }
    }

    companion object {
        private const val STATE_KIND = "kind"
    }
}
