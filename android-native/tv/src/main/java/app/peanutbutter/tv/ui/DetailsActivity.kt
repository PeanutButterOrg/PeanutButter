package app.peanutbutter.tv.ui

import app.peanutbutter.tv.ui.compose.setPbContent
import android.content.Intent
import android.os.Bundle
import android.util.Log
import android.view.KeyEvent
import android.widget.Toast
import androidx.activity.compose.setContent
import androidx.fragment.app.FragmentActivity
import androidx.lifecycle.lifecycleScope
import app.peanutbutter.core.AppLog
import app.peanutbutter.core.Episode
import app.peanutbutter.core.Season
import app.peanutbutter.core.StreamQuality
import app.peanutbutter.core.Person
import app.peanutbutter.core.TitleItem
import app.peanutbutter.core.Trailer
import app.peanutbutter.core.TorrentFilePicker
import app.peanutbutter.core.seriesPlayTarget
import app.peanutbutter.tv.R
import app.peanutbutter.tv.asTv
import app.peanutbutter.tv.player.PlayerActivity
import app.peanutbutter.tv.player.PlayerActivity.Companion.putStreamSource
import kotlinx.coroutines.launch

/**
 * The title page, drawn like the desktop's ([DetailsScreen]): hero, credits,
 * cast, trailer, seasons and episodes, more like this. This activity loads the
 * title and finds and starts streams.
 */
class DetailsActivity : FragmentActivity(), DetailsActions {
    private val ui = DetailsState()
    private var item: TitleItem?
        get() = ui.item
        set(value) {
            ui.item = value
        }
    private var searching = false
    private var lastPlayerLaunchMs = 0L
    private var searchJob: kotlinx.coroutines.Job? = null
    private var playSeason: Int? = null
    private var playEpisode: Int? = null
    private var playEpisodeId: String? = null

    /** The player saved progress: show it (and the next episode to play) on return. */
    private var reloadOnReturn = false

    override fun onResume() {
        super.onResume()
        if (!reloadOnReturn) return
        reloadOnReturn = false
        val id = intent.getStringExtra(EXTRA_ID).orEmpty()
        val app = application.asTv()
        lifecycleScope.launch {
            try {
                app.awaitWrites()
                item = app.api.title(id)
            } catch (e: Exception) {
                AppLog.i("DetailsActivity", "refresh after player failed: ${e.message}")
            }
        }
    }

    override fun onStop() {
        // Left for the trailer app or Home while Play was still looking up
        // sources: don't open a player over whatever is on screen now.
        searchJob?.cancel()
        searchJob = null
        super.onStop()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Start the torrent engine while the user reads the page, not after Play.
        app.peanutbutter.core.TorrentClient.prewarm(this)
        setPbContent { DetailsScreen(ui, this) }
        val id = intent.getStringExtra(EXTRA_ID).orEmpty()
        lifecycleScope.launch {
            try {
                val loaded = application.asTv().api.title(id)
                item = loaded
                loadExtras(loaded)
                // Play on the home hero: press Play once the page is up (not on rotate/recreate).
                if (savedInstanceState == null && intent.getBooleanExtra(EXTRA_AUTOPLAY, false)) {
                    intent.removeExtra(EXTRA_AUTOPLAY)
                    play(fromStart = false)
                }
            } catch (e: Exception) {
                Toast.makeText(this@DetailsActivity, e.message, Toast.LENGTH_LONG).show()
                finish()
            }
        }
    }

    /** Follow state (series) and More like this. */
    private fun loadExtras(t: TitleItem) {
        val api = application.asTv().api
        if (t.kind.equals("SERIES", true) || t.kind.equals("TV", true) || t.kind.equals("ANIME", true)) {
            lifecycleScope.launch { ui.following = runCatching { api.isFollowing(t.id) }.getOrNull() }
        }
        similarPage = 0
        similarHasMore = true
        ui.similar = emptyList()
        loadMoreSimilar()
    }

    // More like this, a page at a time until the list ends.
    private var similarPage = 0
    private var similarHasMore = true
    private var similarLoading = false

    override fun loadMoreSimilar() {
        val t = item ?: return
        if (similarLoading || !similarHasMore) return
        similarLoading = true
        val page = similarPage + 1
        lifecycleScope.launch {
            val (items, more) = application.asTv().api.similarPage(t.id, page)
            similarLoading = false
            if (isFinishing || item?.id != t.id) return@launch
            similarPage = page
            similarHasMore = more
            val seen = ui.similar.mapTo(HashSet()) { it.id }
            ui.similar = ui.similar + items.filter { it.id != t.id && seen.add(it.id) }
            // A page that was all filtered out: keep going while there is more.
            if (items.isEmpty() && more) loadMoreSimilar()
        }
    }

    override fun openPerson(person: Person) {
        val id = person.tmdbPersonId
        if (id == null) {
            Toast.makeText(this, R.string.person_needs_server, Toast.LENGTH_LONG).show()
            return
        }
        startActivity(
            Intent(this, PersonActivity::class.java)
                .putExtra(PersonActivity.EXTRA_TMDB_ID, id)
                .putExtra(PersonActivity.EXTRA_NAME, person.name),
        )
    }

    private fun setBusy(show: Boolean) {
        ui.busy = show
        if (!show) ui.focusPlay++
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (ui.busy) {
            // Source searches can take a minute: Back cancels instead of being swallowed.
            if (event.keyCode == KeyEvent.KEYCODE_BACK && event.action == KeyEvent.ACTION_UP) {
                searchJob?.cancel()
                searchJob = null
                searching = false
                setBusy(false)
            }
            return true
        }
        return super.dispatchKeyEvent(event)
    }

    // ---- DetailsActions ----

    override fun back() = finish()

    override fun play(fromStart: Boolean) {
        val t = item ?: return
        val series = t.kind.equals("SERIES", true) || t.kind.equals("TV", true) || t.kind.equals("ANIME", true)
        if (series) {
            // Default series target = resume / next / S01E01.
            val target = t.seriesPlayTarget()
            playSeason = target?.first?.seasonNumber ?: 1
            playEpisode = target?.second?.episodeNumber ?: 1
            playEpisodeId = target?.second?.id
        } else {
            playSeason = null
            playEpisode = null
            playEpisodeId = null
        }
        openSources(fromBeginning = fromStart)
    }

    override fun playEpisode(season: Season, episode: Episode) {
        playSeason = season.seasonNumber
        playEpisode = episode.episodeNumber
        playEpisodeId = episode.id
        val t = item
        val resumeHere = !episode.watched &&
            (episode.positionMs > 2000 || (t?.episodeId == episode.id && t.canResume))
        openSources(fromBeginning = !resumeHere)
    }

    override fun openTrailer(trailer: Trailer) {
        // Play is starting: the trailer app would end up behind a second video.
        if (searching) return
        runCatching { startActivity(Intent(Intent.ACTION_VIEW, android.net.Uri.parse(trailer.watchUrl))) }
    }

    override fun openTitle(item: TitleItem) {
        startActivity(
            Intent(this, DetailsActivity::class.java)
                .putExtra(EXTRA_ID, item.id)
                .putExtra(EXTRA_TITLE, item.displayTitle),
        )
    }

    override fun toggleFollow() {
        val t = item ?: return
        toggleFollow(t.id)
    }

    override fun toggleWatched() {
        val t = item ?: return
        val next = !t.watched
        item = t.copy(watched = next, positionMs = if (next) 0 else t.positionMs)
        UserStateEdits.setWatched(t.id, next)
        lifecycleScope.launch {
            try {
                application.asTv().api.setWatched(t.id, next)
            } catch (e: Exception) {
                item = t
                UserStateEdits.setWatched(t.id, t.watched)
                Toast.makeText(this@DetailsActivity, e.message, Toast.LENGTH_SHORT).show()
            }
        }
    }

    private fun toggleFollow(titleId: String) {
        val next = ui.following != true
        ui.following = next
        if (next && android.os.Build.VERSION.SDK_INT >= 33 &&
            !app.peanutbutter.tv.EpisodeNotifier.canNotify(this)
        ) {
            requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), 41)
        }
        lifecycleScope.launch {
            try {
                application.asTv().api.setFollow(titleId, next)
                Toast.makeText(
                    this@DetailsActivity,
                    if (next) R.string.notify_on else R.string.notify_off,
                    Toast.LENGTH_SHORT,
                ).show()
            } catch (e: Exception) {
                ui.following = !next
                Toast.makeText(this@DetailsActivity, e.message, Toast.LENGTH_SHORT).show()
            }
        }
    }

    override fun toggleFavorite() {
        val t = item ?: return
        val next = !t.favorite
        item = t.copy(favorite = next)
        UserStateEdits.setFavorite(t.id, next)
        lifecycleScope.launch {
            try {
                application.asTv().api.setFavorite(t.id, next)
            } catch (e: Exception) {
                item = t
                UserStateEdits.setFavorite(t.id, t.favorite)
                Toast.makeText(this@DetailsActivity, e.message, Toast.LENGTH_SHORT).show()
            }
        }
    }

    private fun openSources(fromBeginning: Boolean) {
        val t = item ?: return
        if (searching) return
        searching = true
        setBusy(true)

        val isSeries = t.kind.equals("SERIES", true) ||
            t.kind.equals("TV", true) ||
            t.kind.equals("ANIME", true)

        // Series Play must always target an episode (Flutter playEpisode / S01E01).
        var season = playSeason
        var episode = playEpisode
        if (isSeries && (season == null || episode == null)) {
            val target = t.seriesPlayTarget()
            if (target != null) {
                season = target.first.seasonNumber
                episode = target.second.episodeNumber
                playSeason = season
                playEpisode = episode
                playEpisodeId = target.second.id
            } else {
                season = 1
                episode = 1
                playSeason = 1
                playEpisode = 1
            }
        }

        // Releases may number the episode differently (see releaseEpisode):
        // search for the number they use.
        val searchEpisode = if (season != null && episode != null) {
            TorrentFilePicker.releaseEpisode(t.seasons, season, episode) ?: episode
        } else {
            episode
        }
        val query = if (season != null && searchEpisode != null) {
            String.format(java.util.Locale.US, "%s S%02dE%02d", t.displayTitle, season, searchEpisode)
        } else {
            t.displayTitle
        }
        val wantResume = !fromBeginning && t.canResume &&
            (playEpisodeId == null || playEpisodeId == t.episodeId)
        Log.i(TAG, "openSources query=$query season=$season episode=$episode kind=${t.kind} resume=$wantResume")

        searchJob = lifecycleScope.launch {
            try {
                val api = application.asTv().api
                if (wantResume) {
                    val bookmark = runCatching {
                        api.streamBookmark(t.id, season, episode)
                    }.getOrNull()
                    if (bookmark != null && bookmark.magnet.isNotBlank()) {
                        Toast.makeText(this@DetailsActivity, R.string.resuming_stream, Toast.LENGTH_SHORT).show()
                        // A saved direct link (add-on HTTP stream) is replayed as a link.
                        val savedDirect = bookmark.magnet.takeIf {
                            it.startsWith("http://", true) || it.startsWith("https://", true)
                        }
                        startSavedStream(
                            t = t,
                            magnet = bookmark.magnet,
                            directUrl = savedDirect,
                            seeders = 0,
                            peers = 0,
                            resume = true,
                            season = season,
                            episode = episode,
                            fileIndex = bookmark.fileIndex,
                            resumeMs = t.positionMs.coerceAtLeast(bookmark.resumePosition.toLong()),
                        )
                        return@launch
                    }
                }
                // Merged from every server source and ranked by the server.
                val sources = api.lookupSources(
                    query = query,
                    kind = t.kind.ifBlank { "MOVIE" },
                    titleId = t.id,
                    season = season,
                    episode = searchEpisode,
                )
                if (sources.isEmpty()) {
                    Toast.makeText(this@DetailsActivity, R.string.no_sources, Toast.LENGTH_LONG).show()
                    return@launch
                }
                SourcesDialog.show(
                    this@DetailsActivity,
                    // The episode the user chose, even when the search used the release's number.
                    t.displayTitle,
                    sources,
                    subtitle = if (season != null && episode != null) "Season $season · Episode $episode"
                    else if (t.kind.equals("MOVIE", true)) "Movie" else "Series",
                    posterUrl = t.posterUrl,
                    onRefresh = {
                        StreamQuality.rankSources(
                            api.streamingSearch(
                                query = query,
                                kind = t.kind.ifBlank { "MOVIE" },
                                titleId = t.id,
                                season = season,
                                episode = searchEpisode,
                                live = true,
                            ),
                        )
                    },
                ) { source ->
                    setBusy(true)
                    lifecycleScope.launch {
                        try {
                            startSavedStream(
                                t = t,
                                magnet = source.magnet,
                                directUrl = source.url.takeIf { source.isHttp },
                                headers = source.headers,
                                seeders = source.seeders,
                                peers = source.peers,
                                resume = wantResume,
                                season = season,
                                episode = episode,
                            )
                        } finally {
                            setBusy(false)
                        }
                    }
                }
            } catch (t: kotlinx.coroutines.CancellationException) {
                throw t
            } catch (t: Throwable) {
                Log.e(TAG, "openSources failed", t)
                Toast.makeText(
                    this@DetailsActivity,
                    t.message?.takeIf { it.isNotBlank() } ?: getString(R.string.stream_start_failed),
                    Toast.LENGTH_LONG,
                ).show()
            } finally {
                searching = false
                setBusy(false)
            }
        }
    }

    private suspend fun startSavedStream(
        t: TitleItem,
        magnet: String,
        directUrl: String? = null,
        headers: Map<String, String> = emptyMap(),
        seeders: Int,
        peers: Int,
        resume: Boolean,
        season: Int?,
        episode: Int?,
        fileIndex: Int? = null,
        resumeMs: Long? = null,
    ) {
        val api = application.asTv().api
        val label = if (season != null && episode != null) {
            String.format(java.util.Locale.US, "%s S%02dE%02d", t.displayTitle, season, episode)
        } else t.displayTitle
        try {
            // Flutter parity: open the player immediately; torrent starts there.
            // Waiting for peers on DetailsActivity was killing this screen on TV.
            // A double press must not stack two players.
            val now = android.os.SystemClock.elapsedRealtime()
            if (now - lastPlayerLaunchMs < 2_000L) return
            lastPlayerLaunchMs = now
            AppLog.i(TAG, "launch player ${if (directUrl != null) "direct link" else "magnet=${magnet.take(48)}…"}")
            val seek = when {
                !resume -> 0L
                resumeMs != null && resumeMs > 0 -> resumeMs
                else -> t.positionMs.coerceAtLeast(0)
            }
            reloadOnReturn = true
            startActivity(
                Intent(this, PlayerActivity::class.java)
                    .putExtra(PlayerActivity.EXTRA_TITLE, label)
                    .putStreamSource(magnet, directUrl, headers)
                    .putExtra(PlayerActivity.EXTRA_FILE_INDEX, fileIndex ?: -1)
                    .putExtra(PlayerActivity.EXTRA_POSTER, t.posterUrl)
                    .putExtra(PlayerActivity.EXTRA_BACKDROP, t.backdropUrl)
                    .putExtra(PlayerActivity.EXTRA_TITLE_ID, t.id)
                    .putExtra(PlayerActivity.EXTRA_EPISODE_ID, playEpisodeId)
                    .putExtra(PlayerActivity.EXTRA_KIND, t.kind)
                    .putExtra(PlayerActivity.EXTRA_SEASON, season ?: -1)
                    .putExtra(PlayerActivity.EXTRA_EPISODE, episode ?: -1)
                    .putExtra(
                        PlayerActivity.EXTRA_FILE_EPISODE,
                        if (season != null && episode != null) {
                            TorrentFilePicker.releaseEpisode(t.seasons, season, episode) ?: -1
                        } else {
                            -1
                        },
                    )
                    .putExtra(PlayerActivity.EXTRA_RESUME_MS, seek)
                    .putExtra(
                        PlayerActivity.EXTRA_DURATION_MS,
                        when {
                            t.durationMs > 0L -> t.durationMs
                            (t.runtimeMinutes ?: 0) > 0 -> t.runtimeMinutes!! * 60_000L
                            else -> 0L
                        },
                    ),
            )
        } catch (t: Throwable) {
            AppLog.e(TAG, "playSource failed", t)
            Toast.makeText(
                this,
                t.message?.takeIf { it.isNotBlank() } ?: getString(R.string.stream_start_failed),
                Toast.LENGTH_LONG,
            ).show()
        }
    }

    companion object {
        private const val TAG = "DetailsActivity"
        const val EXTRA_ID = "title_id"
        const val EXTRA_TITLE = "title_name"
        const val EXTRA_AUTOPLAY = "autoplay"
    }
}
