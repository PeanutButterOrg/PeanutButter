package app.peanutbutter.tv.launcher

import android.content.Intent
import android.os.Bundle
import android.util.TypedValue
import android.view.View
import android.view.ViewGroup
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import androidx.activity.OnBackPressedCallback
import androidx.core.content.ContextCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.core.widget.ImageViewCompat
import androidx.fragment.app.FragmentActivity
import androidx.lifecycle.lifecycleScope
import androidx.recyclerview.widget.RecyclerView
import app.peanutbutter.core.HomeFeed
import app.peanutbutter.core.TitleItem
import app.peanutbutter.tv.BuildConfig
import app.peanutbutter.tv.R
import app.peanutbutter.tv.asTv
import app.peanutbutter.tv.ui.DetailsActivity
import app.peanutbutter.tv.ui.PairingActivity
import app.peanutbutter.tv.ui.SearchActivity
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * The TV's Home screen (launcher flavor only). Header: clock, Home / Movies /
 * Series tabs and the compact control bar. Below: the open tab's sections —
 * hero carousel, Your apps (Home), and PeanutButter poster rows.
 */
class LauncherActivity : FragmentActivity() {
    private enum class Tab { HOME, MOVIES, SERIES }

    private lateinit var apps: AppsRow
    private lateinit var content: HomeContent
    private lateinit var list: RecyclerView
    private val tabViews = mutableMapOf<Tab, TextView>()
    private var tab = Tab.HOME
    private var loadJob: Job? = null
    private var tabSwitch: Job? = null

    /** Last feeds per kind, so tab switches paint instantly. */
    private val feeds = mutableMapOf<String, HomeFeed>()
    private var offline = false

    /** PeanutButter server reachable? null = not paired / not checked yet. */
    private val serverOk: Boolean?
        get() = if (!application.asTv().session.isPaired || !checked) null else !offline
    private var checked = false

    private val netCallback = object : android.net.ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: android.net.Network) = runOnUiThread { refreshStatus(); if (offline) load() }
        override fun onLost(network: android.net.Network) = runOnUiThread { refreshStatus() }
    }
    private val btReceiver = object : android.content.BroadcastReceiver() {
        override fun onReceive(context: android.content.Context, intent: Intent) = refreshStatus()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        if (BuildConfig.DEBUG) keepCrashReport()
        super.onCreate(savedInstanceState)
        WindowCompat.setDecorFitsSystemWindows(window, false)
        WindowInsetsControllerCompat(window, window.decorView).apply {
            hide(WindowInsetsCompat.Type.statusBars() or WindowInsetsCompat.Type.navigationBars())
            systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        }
        setContentView(R.layout.activity_launcher)

        apps = AppsRow(this)
        content = HomeContent(this, apps, onTitle = { openTitle(it) }, onSeeAll = { openSeeAll(it) })
        list = findViewById<RecyclerView>(R.id.content).apply {
            layoutManager = content.layoutManager()
            adapter = content
            itemAnimator = null
        }
        bindTabs()
        bindControls()
        lockTopBarEdges()
        render()

        // Home is the bottom of the stack: Back goes to the top of the screen.
        onBackPressedDispatcher.addCallback(this, object : OnBackPressedCallback(true) {
            override fun handleOnBackPressed() = goTop()
        })
        if (savedInstanceState == null) {
            Motion.enter(listOf<android.view.View>(findViewById(R.id.header), list), startDelay = 60, step = 90)
        }
        // Start on the carousel (Android would otherwise start on the first tab).
        list.post { focusFirstSection(force = true) }
    }

    override fun onResume() {
        super.onResume()
        apps.reload()
        load()
        refreshStatus()
        TvControls.refreshInputs(this)
    }

    override fun onStart() {
        super.onStart()
        val cm = getSystemService(android.net.ConnectivityManager::class.java)
        runCatching { cm.registerDefaultNetworkCallback(netCallback) }
        registerReceiver(btReceiver, android.content.IntentFilter(android.bluetooth.BluetoothAdapter.ACTION_STATE_CHANGED))
    }

    override fun onStop() {
        val cm = getSystemService(android.net.ConnectivityManager::class.java)
        runCatching { cm.unregisterNetworkCallback(netCallback) }
        runCatching { unregisterReceiver(btReceiver) }
        super.onStop()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // Home pressed while already home: back to Home, top.
        if (tab != Tab.HOME) selectTab(Tab.HOME)
        goTop()
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == TvControls.REQ_BLUETOOTH) TvControls.showConnectivity(this, serverOk) { load() }
    }

    private var pendingFocus: (() -> Unit)? = null

    /** Run [focus] as soon as this window has focus again (right away if it has). */
    fun focusWhenBack(focus: () -> Unit) {
        if (hasWindowFocus()) list.post(focus) else pendingFocus = focus
    }

    /**
     * Up / Down between rows, done here rather than by Android's focus search:
     * that search can't see rows scrolled off-screen (Up from the apps row
     * did nothing) and picks odd neighbours. Each press moves exactly one row,
     * to the item closest to where focus was; Up from the carousel goes to
     * the open tab.
     */
    override fun dispatchKeyEvent(event: android.view.KeyEvent): Boolean {
        val up = event.keyCode == android.view.KeyEvent.KEYCODE_DPAD_UP
        val down = event.keyCode == android.view.KeyEvent.KEYCODE_DPAD_DOWN
        val focused = currentFocus
        if (event.action == android.view.KeyEvent.ACTION_DOWN && (up || down) && focused != null &&
            focused !== list && isInside(focused, list) && moveRow(focused, if (up) -1 else 1)
        ) {
            return true
        }
        return super.dispatchKeyEvent(event)
    }

    private fun isInside(view: View, parent: View): Boolean {
        var p = view.parent
        while (p is View) {
            if (p === parent) return true
            p = p.parent
        }
        return false
    }

    private fun moveRow(focused: View, step: Int): Boolean {
        val row = list.findContainingViewHolder(focused)?.bindingAdapterPosition ?: return false
        val target = row + step
        if (target < 0) {
            tabViews[tab]?.requestFocus()
            return true
        }
        if (target >= content.itemCount) return true // bottom: stay
        val loc = IntArray(2).also { focused.getLocationOnScreen(it) }
        val x = loc[0] + focused.width / 2
        // Bring the row in, then focus inside it once it is laid out.
        list.findViewHolderForAdapterPosition(target) ?: list.scrollToPosition(target)
        list.post { focusInRow(target, x) }
        return true
    }

    /** Focus the item in row [position] nearest to screen x [x] (waits for the row to be laid out). */
    private fun focusInRow(position: Int, x: Int, tries: Int = 12) {
        val holder = list.findViewHolderForAdapterPosition(position)
        val inner = holder?.itemView?.findViewById<RecyclerView>(R.id.launcher_row_list)
        if (holder == null || (inner != null && inner.childCount == 0)) {
            if (tries > 0) list.postDelayed({ focusInRow(position, x, tries - 1) }, 30)
            return
        }
        if (inner == null) {
            // The carousel row: its only child is the card.
            ((holder.itemView as? ViewGroup)?.getChildAt(0) ?: holder.itemView).requestFocus()
            return
        }
        val loc = IntArray(2)
        val best = (0 until inner.childCount).map { inner.getChildAt(it) }
            .filter { it.isFocusable }
            .minByOrNull { c -> c.getLocationOnScreen(loc); kotlin.math.abs(loc[0] + c.width / 2 - x) }
        (best ?: inner).requestFocus()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) pendingFocus?.let { f -> pendingFocus = null; list.post(f) }
    }

    /** Back: to the top, with focus on the open tab in the top bar. */
    private fun goTop() {
        if (findViewById<ViewGroup>(R.id.header).hasFocus()) return
        list.scrollToPosition(0)
        tabViews[tab]?.requestFocus()
    }

    /**
     * Focus the carousel; it may not be laid out yet right after a (re)render.
     * Never pulls focus out of the top bar unless asked ([force]: OK on a tab, Back).
     */
    private fun focusFirstSection(tries: Int = 10, force: Boolean = false) {
        if (!force && findViewById<View>(R.id.header).hasFocus()) return
        val row = list.findViewHolderForAdapterPosition(0)?.itemView
        if (row == null) {
            if (tries > 0) list.postDelayed({ focusFirstSection(tries - 1, force) }, 50)
            return
        }
        ((row as? ViewGroup)?.getChildAt(0) ?: row).requestFocus()
    }

    // --- header -------------------------------------------------------------

    private fun bindTabs() {
        val bar = findViewById<LinearLayout>(R.id.tabs)
        listOf(Tab.HOME to R.string.tab_home, Tab.MOVIES to R.string.tab_movies, Tab.SERIES to R.string.tab_series)
            .forEach { (t, label) ->
                val view = TextView(this).apply {
                    setText(label)
                    setTextColor(ContextCompat.getColorStateList(this@LauncherActivity, R.color.launcher_tab_fg))
                    setTextSize(TypedValue.COMPLEX_UNIT_SP, 17f)
                    setTypeface(typeface, android.graphics.Typeface.BOLD)
                    gravity = android.view.Gravity.CENTER
                    background = ContextCompat.getDrawable(this@LauncherActivity, R.drawable.launcher_tab_bg)
                    setPadding(dp(22), 0, dp(22), 0)
                    isFocusable = true
                    isFocusableInTouchMode = true
                    isSelected = t == tab
                    // Moving onto a tab opens it (after a short pause, so sweeping across stays smooth).
                    setOnFocusChangeListener { _, focused ->
                        Motion.liftNow(this, focused, 1.06f)
                        if (focused) {
                            tabSwitch?.cancel()
                            tabSwitch = lifecycleScope.launch {
                                delay(300)
                                selectTab(t)
                            }
                        }
                    }
                    setOnClickListener {
                        selectTab(t)
                        list.post { focusFirstSection(force = true) }
                    }
                }
                tabViews[t] = view
                bar.addView(view, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, dp(44)).apply {
                    if (bar.childCount > 0) marginStart = dp(6)
                })
            }
    }

    /** ◀ on the first tab and ▶ on the last control stay where they are. */
    private fun lockTopBarEdges() {
        tabViews[Tab.HOME]?.let { it.id = View.generateViewId(); it.nextFocusLeftId = it.id }
        val controls = findViewById<LinearLayout>(R.id.controls)
        // Each control sits in a holder (for its status dot); lock the button itself.
        (controls.getChildAt(controls.childCount - 1) as? ViewGroup)?.getChildAt(0)
            ?.let { it.id = View.generateViewId(); it.nextFocusRightId = it.id }
    }

    private fun selectTab(t: Tab) {
        if (t == tab) return
        tab = t
        tabViews.forEach { (key, v) -> v.isSelected = key == t }
        // Both feeds are already cached, so the new tab draws at once: the
        // carousel cross-fades to its own slides, no blank frame in between.
        list.scrollToPosition(0)
        render()
        if (feeds.isEmpty()) load()
    }

    private fun bindControls() {
        val bar = findViewById<LinearLayout>(R.id.controls)
        barButton(bar, intArrayOf(R.drawable.ic_search), R.string.search) {
            if (application.asTv().session.isPaired) {
                startActivity(Intent(this, SearchActivity::class.java))
            } else {
                startActivity(Intent(this, PairingActivity::class.java))
            }
        }
        barButton(bar, intArrayOf(R.drawable.ic_input), R.string.inputs) { TvControls.showInputs(this) }
        barButton(bar, intArrayOf(R.drawable.ic_volume), R.string.sound) { TvControls.showSound(this) }
        connectivity = barButton(bar, intArrayOf(R.drawable.ic_wifi), R.string.connectivity) {
            TvControls.showConnectivity(this, serverOk) { load() }
        }
        barButton(bar, intArrayOf(R.drawable.ic_settings), R.string.all_settings) { TvControls.showSettings(this) }
    }

    private var connectivity: View? = null

    /** Red dot on the Wi‑Fi button while network, server or Bluetooth has a problem. */
    private fun refreshStatus() {
        val button = connectivity ?: return
        val dot = button.findViewWithTag<View>(STATUS_DOT) ?: return
        val issues = TvControls.issues(this, serverOk)
        dot.animate().alpha(if (issues.isEmpty()) 0f else 1f).setDuration(200).start()
        button.contentDescription = (listOf(getString(R.string.connectivity)) + issues).joinToString(". ")
    }

    /** Round button in the control bar: fills white when focused (no outline). */
    private fun barButton(bar: LinearLayout, icons: IntArray, label: Int, onClick: () -> Unit): View {
        val fg = ContextCompat.getColorStateList(this, R.color.launcher_bar_fg)
        val button = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = android.view.Gravity.CENTER
            background = ContextCompat.getDrawable(this@LauncherActivity, R.drawable.launcher_bar_button)
            setPadding(dp(10), 0, dp(10), 0)
            minimumWidth = dp(40)
            isFocusable = true
            isFocusableInTouchMode = true
            contentDescription = getString(label)
            icons.forEachIndexed { i, icon ->
                addView(
                    ImageView(this@LauncherActivity).apply {
                        setImageResource(icon)
                        ImageViewCompat.setImageTintList(this, fg)
                        isDuplicateParentStateEnabled = true
                    },
                    LinearLayout.LayoutParams(dp(22), dp(22)).apply { if (i > 0) marginStart = dp(6) },
                )
            }
            // The white fill shows focus; no zoom, so the end buttons never poke out of the bar.
            setOnClickListener { onClick() }
        }
        // Status dot in the corner (only shown on the Wi‑Fi button, see refreshStatus).
        val holder = android.widget.FrameLayout(this).apply {
            clipChildren = false
            addView(button, android.widget.FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, dp(40)))
            addView(View(this@LauncherActivity).apply {
                tag = STATUS_DOT
                background = ContextCompat.getDrawable(this@LauncherActivity, R.drawable.launcher_status_dot)
                alpha = 0f
            }, android.widget.FrameLayout.LayoutParams(dp(10), dp(10), android.view.Gravity.TOP or android.view.Gravity.END).apply {
                topMargin = dp(4)
                marginEnd = dp(4)
            })
        }
        bar.addView(holder, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, dp(40)).apply {
            if (bar.childCount > 0) marginStart = dp(4)
        })
        return holder
    }

    // --- content ------------------------------------------------------------

    private fun load() {
        val app = application.asTv()
        if (!app.session.isPaired) {
            render()
            return
        }
        // Always both kinds: Home mixes them, and Movies / Series then switch instantly.
        loadJob?.cancel()
        loadJob = lifecycleScope.launch {
            try {
                val results = listOf("MOVIE", "SERIES").map { kind -> kind to async { app.api.homeFeed(kind) } }
                results.forEach { (kind, feed) -> feeds[kind] = feed.await() }
                offline = false
                // Every row's posters, so switching tabs never shows empty cards.
                Posters.preload(
                    this@LauncherActivity,
                    // First screenful of each row; the rest load as you scroll.
                    feeds.values.flatMap { f -> listOf(f.trending, f.popular, f.recent, f.continueWatching).flatMap { it.take(10) } }
                        .mapNotNull { it.posterUrl ?: it.backdropUrl },
                )
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
                offline = true
            }
            checked = true
            render()
            refreshStatus()
        }
    }

    private fun render() {
        val app = application.asTv()
        val sections = mutableListOf<Section>()
        if (!app.session.isPaired) {
            sections += Section.Hero(listOf(connectSlide()))
            if (tab == Tab.HOME) sections += Section.Apps
            content.submit(sections)
            return
        }
        val movies = feeds["MOVIE"]
        val series = feeds["SERIES"]
        when (tab) {
            Tab.HOME -> {
                val resume = (movies ?: series)?.continueWatching.orEmpty()
                val picks = resume.take(2).map { slide(it, resume = true) } +
                    interleave(movies?.trending.orEmpty().take(3), series?.trending.orEmpty().take(3))
                        .map { slide(it, resume = false) }
                sections += Section.Hero(picks.ifEmpty { listOf(if (offline) offlineSlide() else loadingSlide()) })
                sections += Section.Apps
                if (resume.isNotEmpty()) sections += Section.Posters(getString(R.string.row_continue), resume, "CONTINUE_WATCHING", null)
                movies?.trending?.takeIf { it.isNotEmpty() }
                    ?.let { sections += Section.Posters(getString(R.string.row_trending_movies), it, "TRENDING", "MOVIE") }
                series?.trending?.takeIf { it.isNotEmpty() }
                    ?.let { sections += Section.Posters(getString(R.string.row_trending_series), it, "TRENDING", "SERIES") }
            }
            Tab.MOVIES, Tab.SERIES -> {
                val kind = if (tab == Tab.MOVIES) "MOVIE" else "SERIES"
                val feed = feeds[kind]
                val hero = feed?.trending.orEmpty().take(6).map { slide(it, resume = false) }
                sections += Section.Hero(hero.ifEmpty { listOf(if (offline) offlineSlide() else loadingSlide()) })
                if (feed != null) {
                    val resume = feed.continueWatching.filter { it.kind == kind }
                    if (resume.isNotEmpty()) sections += Section.Posters(getString(R.string.row_continue), resume, "CONTINUE_WATCHING", kind)
                    if (feed.trending.isNotEmpty()) sections += Section.Posters(getString(R.string.row_trending), feed.trending, "TRENDING", kind)
                    if (feed.popular.isNotEmpty()) sections += Section.Posters(getString(R.string.row_popular), feed.popular, "POPULARITY", kind)
                    if (feed.recent.isNotEmpty()) sections += Section.Posters(getString(R.string.row_recent), feed.recent, "DATE_ADDED", kind)
                }
            }
        }
        content.submit(sections)
    }

    private fun <T> interleave(a: List<T>, b: List<T>): List<T> =
        (0 until maxOf(a.size, b.size)).flatMap { listOfNotNull(a.getOrNull(it), b.getOrNull(it)) }

    private fun slide(item: TitleItem, resume: Boolean): HeroCarousel.Slide {
        val left = ((item.durationMs - item.positionMs) / 60_000).toInt()
        val kindLabel = getString(if (item.kind == "SERIES") R.string.kind_series else R.string.kind_movie)
        // One short line: year · length · rating · genre (whatever the title has).
        val runtime = item.runtimeMinutes?.takeIf { it > 0 }?.let { m -> if (m >= 60) "${m / 60}h ${m % 60}m" else "${m}m" }
        val rating = (item.tmdbVoteAverage ?: item.imdbRating)?.takeIf { it > 0 }?.let { "★ %.1f".format(it) }
        val meta = listOfNotNull(item.year?.toString(), runtime, rating, item.genres.firstOrNull()).joinToString("  ·  ")
        return HeroCarousel.Slide(
            key = item.id,
            kicker = if (resume) getString(R.string.hero_continue) else "${getString(R.string.hero_trending)}  ·  $kindLabel",
            title = item.displayTitle,
            subtitle = if (resume && left > 0) getString(R.string.hero_minutes_left, left) + "  ·  " + meta else meta,
            description = item.synopsis?.trim().orEmpty(),
            art = item.backdropUrl ?: item.posterUrl,
            progress = if (resume) HomeContent.progressPercentOf(item) else null,
        ) { openTitle(item) }
    }

    private fun connectSlide() = HeroCarousel.Slide(
        key = "connect",
        kicker = getString(R.string.hero_connect_kicker),
        title = getString(R.string.hero_connect_title),
        subtitle = getString(R.string.hero_connect_subtitle),
        art = null,
        appLogo = true,
    ) { startActivity(Intent(this, PairingActivity::class.java)) }

    private fun offlineSlide() = HeroCarousel.Slide(
        key = "offline",
        kicker = getString(R.string.hero_offline_kicker),
        title = getString(R.string.hero_connect_kicker),
        subtitle = getString(R.string.hero_offline_subtitle),
        art = null,
        appLogo = true,
    ) { load() }

    private fun loadingSlide() = HeroCarousel.Slide(
        key = "loading",
        kicker = getString(R.string.hero_connect_kicker),
        title = getString(R.string.loading),
        subtitle = "",
        art = null,
        appLogo = true,
    ) {}

    /** The full grid for a row — the TV app's "See all" screen. */
    private fun openSeeAll(row: Section.Posters) {
        val intent = Intent(this, app.peanutbutter.tv.ui.CatalogActivity::class.java)
            .putExtra(app.peanutbutter.tv.ui.CatalogActivity.EXTRA_TITLE, row.title)
            .putExtra(app.peanutbutter.tv.ui.CatalogActivity.EXTRA_SORT, row.sort)
        row.kind?.let { intent.putExtra(app.peanutbutter.tv.ui.CatalogActivity.EXTRA_KIND, it) }
        startActivity(intent)
    }

    private fun openTitle(item: TitleItem) {
        startActivity(
            Intent(this, DetailsActivity::class.java)
                .putExtra(DetailsActivity.EXTRA_ID, item.id)
                .putExtra(DetailsActivity.EXTRA_TITLE, item.displayTitle),
        )
    }

    private fun dp(v: Int) = (v * resources.displayMetrics.density).toInt()

    private companion object {
        const val STATUS_DOT = "status_dot"
    }

    /**
     * Debug builds: some TVs ship with logging switched off, so keep the last
     * crash in files/last-crash.txt (`adb shell run-as <pkg> cat files/last-crash.txt`).
     */
    private fun keepCrashReport() {
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        if (previous is CrashReport) return
        Thread.setDefaultUncaughtExceptionHandler(CrashReport(filesDir, previous))
    }

    private class CrashReport(
        private val dir: java.io.File,
        private val next: Thread.UncaughtExceptionHandler?,
    ) : Thread.UncaughtExceptionHandler {
        override fun uncaughtException(t: Thread, e: Throwable) {
            runCatching { java.io.File(dir, "last-crash.txt").writeText(e.stackTraceToString()) }
            next?.uncaughtException(t, e)
        }
    }
}
