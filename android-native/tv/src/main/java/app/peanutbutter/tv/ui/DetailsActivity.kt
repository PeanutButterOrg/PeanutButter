package app.peanutbutter.tv.ui

import android.content.Intent
import android.content.res.ColorStateList
import android.os.Bundle
import android.util.Log
import android.view.KeyEvent
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.graphics.Rect
import android.widget.HorizontalScrollView
import android.widget.ImageButton
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.TextView
import android.widget.Toast
import androidx.core.content.ContextCompat
import androidx.core.view.isVisible
import androidx.fragment.app.FragmentActivity
import androidx.lifecycle.lifecycleScope
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import app.peanutbutter.core.Episode
import app.peanutbutter.core.Season
import app.peanutbutter.core.StreamQuality
import app.peanutbutter.core.StreamSource
import app.peanutbutter.core.TitleItem
import app.peanutbutter.core.seriesPlayTarget
import app.peanutbutter.tv.PbGlide
import app.peanutbutter.tv.R
import app.peanutbutter.tv.asTv
import app.peanutbutter.tv.player.PlayerActivity
import kotlinx.coroutines.launch

/** Flutter detail — hero + cast + seasons/episodes; series Play → S01E01. */
class DetailsActivity : FragmentActivity() {
    private var item: TitleItem? = null
    private var searching = false
    private var playSeason: Int? = null
    private var playEpisode: Int? = null
    private var playEpisodeId: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_details)
        val id = intent.getStringExtra(EXTRA_ID).orEmpty()
        setBusy(true)
        lifecycleScope.launch {
            var loadedOk = false
            try {
                val loaded = application.asTv().api.title(id)
                item = loaded
                bind(loaded)
                loadedOk = true
            } catch (e: Exception) {
                Toast.makeText(this@DetailsActivity, e.message, Toast.LENGTH_LONG).show()
            } finally {
                setBusy(false)
                if (loadedOk) findViewById<View>(R.id.btn_play).requestFocus()
            }
        }
    }

    private fun setBusy(show: Boolean) {
        val block = findViewById<View>(R.id.busy_block)
        block.isVisible = show
        findViewById<View>(R.id.action_row).isVisible = !show
        if (show) block.requestFocus()
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (findViewById<View>(R.id.busy_block).isVisible) return true
        return super.dispatchKeyEvent(event)
    }

    private fun bind(t: TitleItem) {
        val backdrop = findViewById<ImageView>(R.id.backdrop)
        val logo = findViewById<ImageView>(R.id.logo)
        val title = findViewById<TextView>(R.id.title)
        val eyebrow = findViewById<TextView>(R.id.eyebrow)
        val synopsis = findViewById<TextView>(R.id.synopsis)
        val chips = findViewById<LinearLayout>(R.id.meta_chips)
        val play = findViewById<View>(R.id.btn_play)
        val playLabel = findViewById<TextView>(R.id.btn_play_label)
        val fromStart = findViewById<TextView>(R.id.btn_from_start)
        val watchedBtn = findViewById<ImageButton>(R.id.btn_watched)
        val favBtn = findViewById<ImageButton>(R.id.btn_favorite)

        val isSeries = t.kind.equals("SERIES", true) ||
            t.kind.equals("TV", true) ||
            t.kind.equals("ANIME", true)

        eyebrow.text = when {
            isSeries && t.kind.equals("ANIME", true) -> "Anime"
            isSeries -> getString(R.string.series)
            else -> getString(R.string.movies)
        }
        title.text = t.title
        synopsis.text = t.synopsis.orEmpty()
        synopsis.isVisible = !t.synopsis.isNullOrBlank()

        PbGlide.backdrop(backdrop, t.backdropUrl ?: t.posterUrl)

        if (!t.logoUrl.isNullOrBlank()) {
            logo.isVisible = true
            title.isVisible = false
            PbGlide.logo(logo, t.logoUrl)
        } else {
            logo.isVisible = false
            title.isVisible = true
        }

        chips.removeAllViews()
        var first = true
        fun addPiece(block: () -> Unit) {
            if (!first) addDot(chips)
            first = false
            block()
        }
        t.displayScore?.let { score ->
            addPiece {
                val label = if (score.rtScore == null) "★ ${score.label} ${score.source}"
                else "${score.label} ${score.source}"
                addChip(chips, label, pill = false)
            }
        }
        t.year?.let { y -> addPiece { addMetaText(chips, y.toString()) } }
        t.runtimeMinutes?.takeIf { it > 0 }?.let { m ->
            addPiece {
                val label = when {
                    m < 60 -> "${m}m"
                    m % 60 == 0 -> "${m / 60}h"
                    else -> "${m / 60}h ${m % 60}m"
                }
                addMetaText(chips, label)
            }
        }
        t.genres.take(3).forEach { g -> addPiece { addChip(chips, g, pill = true) } }

        // Default series target = resume / next / S01E01
        if (isSeries) {
            val target = t.seriesPlayTarget()
            if (target != null) {
                playSeason = target.first.seasonNumber
                playEpisode = target.second.episodeNumber
                playEpisodeId = target.second.id
                playLabel.text = if (t.canResume && t.episodeId == target.second.id) {
                    getString(R.string.resume)
                } else {
                    getString(R.string.play)
                }
                fromStart.isVisible = t.canResume && t.episodeId == target.second.id
            } else {
                playSeason = 1
                playEpisode = 1
                playLabel.text = getString(R.string.play)
                fromStart.isVisible = false
            }
        } else {
            playSeason = null
            playEpisode = null
            playEpisodeId = null
            playLabel.text = if (t.canResume) getString(R.string.resume) else getString(R.string.play)
            fromStart.isVisible = t.canResume
        }

        play.setOnClickListener { openSources(fromBeginning = false) }
        fromStart.setOnClickListener { openSources(fromBeginning = true) }

        updateWatchedFav(t)
        watchedBtn.setOnClickListener { toggleWatched() }
        favBtn.setOnClickListener { toggleFavorite() }

        // Flutter order: cast → trailer → seasons (all visible, page scrolls)
        bindCastAndTrailer(t)
        bindSeasons(t, playableSeasons(t))

        // Size hero like Flutter HeroBannerFrame (~58% viewport, clamp 460–620)
        val hero = findViewById<View>(R.id.hero_frame)
        val dm = resources.displayMetrics
        val heroH = (dm.heightPixels * 0.58f).toInt().coerceIn(dp(460), dp(620))
        hero.layoutParams = hero.layoutParams.apply { height = heroH }

        Log.i(TAG, "bind kind=${t.kind} seasonsRaw=${t.seasons.size} people=${t.people.size}")
    }

    private fun playableSeasons(t: TitleItem): List<Season> =
        t.seasons.filter { s ->
            s.seasonNumber > 0 &&
                !s.name.orEmpty().contains("special", ignoreCase = true) &&
                s.episodes.isNotEmpty()
        }.sortedBy { it.seasonNumber }

    private fun bindCastAndTrailer(t: TitleItem) {
        val castHeading = findViewById<TextView>(R.id.cast_heading)
        val castList = findViewById<RecyclerView>(R.id.cast_list)
        val trailerHeading = findViewById<TextView>(R.id.trailer_heading)
        val trailerCard = findViewById<ViewGroup>(R.id.trailer_card)
        val trailerThumb = findViewById<ImageView>(R.id.trailer_thumb)

        if (t.people.isNotEmpty()) {
            castHeading.isVisible = true
            castList.isVisible = true
            castList.clipChildren = false
            castList.clipToPadding = false
            (castList.parent as? ViewGroup)?.let {
                it.clipChildren = false
                it.clipToPadding = false
            }
            castList.isHorizontalScrollBarEnabled = false
            castList.overScrollMode = View.OVER_SCROLL_NEVER
            castList.descendantFocusability = ViewGroup.FOCUS_AFTER_DESCENDANTS
            castList.layoutManager = LinearLayoutManager(this, LinearLayoutManager.HORIZONTAL, false)
            castList.adapter = PersonAdapter(t.people.take(24))
        } else {
            castHeading.isVisible = false
            castList.isVisible = false
        }

        val trailerWrap = findViewById<View>(R.id.trailer_wrap)
        val trailer = t.playableTrailers.firstOrNull()
        if (trailer != null) {
            trailerHeading.isVisible = true
            trailerWrap.isVisible = true
            trailerCard.clipToOutline = true
            trailerCard.stateListAnimator = null
            trailerCard.setOnFocusChangeListener { v, hasFocus ->
                PosterCardPresenter.applyFocusScaleElevate(v as ViewGroup, hasFocus)
            }
            PbGlide.thumb(trailerThumb, trailer.thumbnailUrl, wDp = 220, hDp = 124)
            trailerCard.setOnClickListener {
                startActivity(Intent(Intent.ACTION_VIEW, android.net.Uri.parse(trailer.watchUrl)))
            }
        } else {
            trailerHeading.isVisible = false
            trailerWrap.isVisible = false
        }
    }

    private fun bindSeasons(t: TitleItem, seasons: List<Season>) {
        val heading = findViewById<TextView>(R.id.seasons_heading)
        val container = findViewById<LinearLayout>(R.id.seasons_container)
        container.removeAllViews()
        heading.isVisible = false

        if (seasons.isEmpty()) {
            container.isVisible = false
            return
        }
        container.isVisible = true

        val progressId = t.episodeId
        val sections = seasons.map { season -> buildSeasonSection(season, progressId) }
        sections.forEachIndexed { index, section ->
            container.addView(
                section.header,
                LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.MATCH_PARENT,
                    LinearLayout.LayoutParams.WRAP_CONTENT,
                ).apply {
                    topMargin = if (index == 0) dp(8) else dp(14)
                },
            )
            container.addView(
                section.scroller,
                LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.MATCH_PARENT,
                    LinearLayout.LayoutParams.WRAP_CONTENT,
                ).apply { topMargin = dp(2) },
            )
        }
        sections.forEachIndexed { index, section ->
            val above = sections.getOrNull(index - 1)?.cards.orEmpty()
            val below = sections.getOrNull(index + 1)?.cards.orEmpty()
            section.cards.forEachIndexed { column, card ->
                card.nextFocusUpId = (above.getOrNull(column) ?: above.lastOrNull())?.id ?: View.NO_ID
                card.nextFocusDownId = (below.getOrNull(column) ?: below.firstOrNull())?.id ?: View.NO_ID
            }
        }
    }

    private fun buildSeasonSection(season: Season, progressId: String?): SeasonSection {
        val episodes = season.episodes.sortedBy { it.episodeNumber }
        val header = LayoutInflater.from(this).inflate(R.layout.item_season_section, null)
        header.id = View.generateViewId()
        bindSeasonHeader(header, season, episodes, containsResume = episodes.any { it.id == progressId })

        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            clipChildren = false
            clipToPadding = false
        }
        val cards = episodes.map { ep ->
            val card = LayoutInflater.from(this).inflate(R.layout.item_episode_card, row, false)
            card.id = View.generateViewId()
            bindEpisodeCard(card, season, ep)
            row.addView(card)
            card
        }
        val landing = cards.zip(episodes).firstOrNull { it.second.id == progressId }?.first
            ?: cards.zip(episodes).firstOrNull { !it.second.watched }?.first
            ?: cards.firstOrNull()
        landing?.let { card ->
            row.post {
                val scroller = row.parent as? HorizontalScrollView ?: return@post
                val x = card.left - (scroller.width - card.width) / 2
                scroller.scrollTo(x.coerceAtLeast(0), 0)
            }
        }
        return SeasonSection(header, CenterFocusScroll(this).apply { addView(row) }, cards, landing)
    }

    private fun bindSeasonHeader(
        header: View,
        season: Season,
        episodes: List<Episode>,
        containsResume: Boolean,
    ) {
        val title = header.findViewById<TextView>(R.id.season_title)
        val meta = header.findViewById<TextView>(R.id.season_meta)
        val check = header.findViewById<ImageView>(R.id.season_check)
        val progress = header.findViewById<ProgressBar>(R.id.season_progress)
        title.text = season.name?.takeIf { it.isNotBlank() }
            ?: getString(R.string.season_n, season.seasonNumber)

        val total = episodes.size
        val done = episodes.count { it.watched }
        val started = episodes.count { !it.watched && it.watchProgress > 0.02 }
        val complete = total > 0 && done == total
        val fraction = if (total == 0) {
            0.0
        } else {
            episodes.sumOf { ep ->
                when {
                    ep.watched -> 1.0
                    ep.watchProgress > 0.02 -> ep.watchProgress
                    else -> 0.0
                }
            } / total
        }

        meta.text = when {
            total == 0 -> getString(R.string.episodes_count, 0)
            done == 0 && started == 0 -> getString(R.string.episodes_count, total)
            started > 0 -> getString(R.string.episodes_progress, done, total, started)
            else -> getString(R.string.episodes_completed, done, total)
        }
        val accent = when {
            complete -> R.color.pb_completed
            containsResume || started > 0 -> R.color.pb_seed
            else -> R.color.pb_muted
        }
        meta.setTextColor(ContextCompat.getColor(this, accent))
        title.setTextColor(
            ContextCompat.getColor(
                this,
                if (containsResume && !complete) R.color.pb_seed else R.color.pb_white,
            ),
        )
        check.isVisible = complete
        if (fraction > 0.02) {
            progress.isVisible = true
            progress.progress = (fraction * 1000).toInt().coerceIn(20, 1000)
            progress.progressTintList = ColorStateList.valueOf(
                ContextCompat.getColor(this, if (complete) R.color.pb_completed else R.color.pb_seed),
            )
        } else {
            progress.isVisible = false
        }
    }

    private fun bindEpisodeCard(card: View, season: Season, ep: Episode) {
        val still = card.findViewById<ImageView>(R.id.episode_still)
        val code = card.findViewById<TextView>(R.id.episode_code)
        val name = card.findViewById<TextView>(R.id.episode_name)
        val progress = card.findViewById<ProgressBar>(R.id.episode_progress)
        val watchedMark = card.findViewById<ImageView>(R.id.episode_watched)

        code.text = getString(R.string.episode_code, season.seasonNumber, ep.episodeNumber)
        name.text = ep.titleLabel
        val started = !ep.watched && ep.watchProgress > 0.02
        watchedMark.isVisible = ep.watched
        when {
            ep.watched -> {
                name.setTextColor(ContextCompat.getColor(this, R.color.pb_white))
                progress.isVisible = true
                progress.progress = 100
                progress.progressTintList = ColorStateList.valueOf(
                    ContextCompat.getColor(this, R.color.pb_completed),
                )
            }
            started -> {
                name.setTextColor(ContextCompat.getColor(this, R.color.pb_seed))
                progress.isVisible = true
                progress.progress = (ep.watchProgress * 100).toInt().coerceIn(2, 100)
                progress.progressTintList = ColorStateList.valueOf(
                    ContextCompat.getColor(this, R.color.pb_seed),
                )
            }
            else -> {
                name.setTextColor(ContextCompat.getColor(this, R.color.pb_white))
                progress.isVisible = false
            }
        }
        PbGlide.thumb(still, ep.stillPath, wDp = 200, hDp = 112)
        card.setOnClickListener {
            playSeason = season.seasonNumber
            playEpisode = ep.episodeNumber
            playEpisodeId = ep.id
            val resumeHere = !ep.watched &&
                (ep.positionMs > 2000 || (item?.episodeId == ep.id && item?.canResume == true))
            openSources(fromBeginning = !resumeHere)
        }
    }

    private fun addDot(parent: LinearLayout) {
        parent.addView(
            View(this).apply {
                layoutParams = LinearLayout.LayoutParams(dp(3), dp(3)).apply {
                    marginStart = dp(8)
                    marginEnd = dp(8)
                    gravity = android.view.Gravity.CENTER_VERTICAL
                }
                background = getDrawable(R.drawable.meta_dot)
            },
        )
    }

    private fun addMetaText(parent: LinearLayout, text: String) {
        parent.addView(
            TextView(this).apply {
                this.text = text
                setTextColor(0xD1FFFFFF.toInt())
                textSize = 13f
                setTypeface(typeface, android.graphics.Typeface.BOLD)
            },
        )
    }

    private fun addChip(parent: LinearLayout, text: String, pill: Boolean) {
        parent.addView(
            TextView(this).apply {
                this.text = text
                setTextColor(getColor(R.color.pb_white))
                textSize = if (pill) 12f else 13f
                setTypeface(typeface, android.graphics.Typeface.BOLD)
                setPadding(
                    dp(if (pill) 8 else 0),
                    dp(if (pill) 3 else 0),
                    dp(if (pill) 8 else 0),
                    dp(if (pill) 3 else 0),
                )
                if (pill) background = getDrawable(R.drawable.meta_chip_bg)
            },
        )
    }

    private fun updateWatchedFav(t: TitleItem) {
        findViewById<ImageButton>(R.id.btn_watched).setImageResource(
            if (t.watched) R.drawable.ic_check else R.drawable.ic_check_outline,
        )
        findViewById<ImageButton>(R.id.btn_favorite).setImageResource(
            if (t.favorite) R.drawable.ic_favorite else R.drawable.ic_favorite_border,
        )
    }

    private fun toggleWatched() {
        val t = item ?: return
        lifecycleScope.launch {
            try {
                val next = !t.watched
                application.asTv().api.setWatched(t.id, next)
                item = t.copy(watched = next, positionMs = if (next) 0 else t.positionMs)
                updateWatchedFav(item!!)
            } catch (e: Exception) {
                Toast.makeText(this@DetailsActivity, e.message, Toast.LENGTH_SHORT).show()
            }
        }
    }

    private fun toggleFavorite() {
        val t = item ?: return
        lifecycleScope.launch {
            try {
                val next = !t.favorite
                application.asTv().api.setFavorite(t.id, next)
                item = t.copy(favorite = next)
                updateWatchedFav(item!!)
            } catch (e: Exception) {
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

        val query = if (season != null && episode != null) {
            String.format("%s S%02dE%02d", t.title, season, episode)
        } else {
            t.title
        }
        val wantResume = !fromBeginning && t.canResume &&
            (playEpisodeId == null || playEpisodeId == t.episodeId)
        Log.i(TAG, "openSources query=$query season=$season episode=$episode kind=${t.kind} resume=$wantResume")

        lifecycleScope.launch {
            try {
                val api = application.asTv().api
                if (wantResume) {
                    val bookmark = runCatching {
                        api.streamBookmark(t.id, season, episode)
                    }.getOrNull()
                    if (bookmark != null && bookmark.magnet.isNotBlank()) {
                        Toast.makeText(this@DetailsActivity, R.string.resuming_stream, Toast.LENGTH_SHORT).show()
                        startSavedStream(
                            t = t,
                            magnet = bookmark.magnet,
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
                val raw = api.lookupSources(
                    query = query,
                    kind = t.kind.ifBlank { "MOVIE" },
                    titleId = t.id,
                    season = season,
                    episode = episode,
                )
                val sources = StreamQuality.rankSources(
                    raw,
                    application.asTv().session.preferredQuality,
                )
                if (sources.isEmpty()) {
                    Toast.makeText(this@DetailsActivity, R.string.no_sources, Toast.LENGTH_LONG).show()
                    return@launch
                }
                SourcesDialog.show(
                    supportFragmentManager,
                    query,
                    sources,
                ) { source ->
                    setBusy(true)
                    lifecycleScope.launch {
                        try {
                            startSavedStream(
                                t = t,
                                magnet = source.magnet,
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
            } catch (e: Exception) {
                Toast.makeText(this@DetailsActivity, e.message, Toast.LENGTH_LONG).show()
            } finally {
                searching = false
                setBusy(false)
            }
        }
    }

    private suspend fun startSavedStream(
        t: TitleItem,
        magnet: String,
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
            String.format("%s S%02dE%02d", t.title, season, episode)
        } else t.title
        try {
            val started = api.startStream(
                magnet = magnet,
                title = label,
                titleId = t.id,
                seeders = seeders,
                peers = peers,
                season = season,
                episode = episode,
                fileIndex = fileIndex,
                resume = resume,
            )
            Log.i(TAG, "startStream id=${started.sessionId} status=${started.status} url=${started.streamUrl.take(80)}")
            if (started.sessionId.isBlank()) {
                Toast.makeText(this, R.string.stream_start_failed, Toast.LENGTH_LONG).show()
                return
            }
            val seek = when {
                !resume -> 0L
                resumeMs != null && resumeMs > 0 -> resumeMs
                else -> t.positionMs.coerceAtLeast(0)
            }
            startActivity(
                Intent(this, PlayerActivity::class.java)
                    .putExtra(PlayerActivity.EXTRA_TITLE, label)
                    .putExtra(PlayerActivity.EXTRA_SESSION, started.sessionId)
                    .putExtra(PlayerActivity.EXTRA_URL, api.playableStreamUrl(started.streamUrl))
                    .putExtra(PlayerActivity.EXTRA_POSTER, t.posterUrl)
                    .putExtra(PlayerActivity.EXTRA_BACKDROP, t.backdropUrl)
                    .putExtra(PlayerActivity.EXTRA_TITLE_ID, t.id)
                    .putExtra(PlayerActivity.EXTRA_EPISODE_ID, playEpisodeId)
                    .putExtra(PlayerActivity.EXTRA_KIND, t.kind)
                    .putExtra(PlayerActivity.EXTRA_SEASON, season ?: -1)
                    .putExtra(PlayerActivity.EXTRA_EPISODE, episode ?: -1)
                    .putExtra(PlayerActivity.EXTRA_RESUME_MS, seek),
            )
        } catch (e: Exception) {
            Log.e(TAG, "playSource failed", e)
            Toast.makeText(this, e.message, Toast.LENGTH_LONG).show()
        }
    }

    private fun dp(v: Int): Int = (v * resources.displayMetrics.density).toInt()

    private class PersonAdapter(
        private val people: List<app.peanutbutter.core.Person>,
    ) : RecyclerView.Adapter<PersonAdapter.VH>() {
        class VH(val root: View) : RecyclerView.ViewHolder(root)

        override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): VH {
            val v = LayoutInflater.from(parent.context)
                .inflate(R.layout.item_person_card, parent, false) as ViewGroup
            v.isFocusable = true
            v.isFocusableInTouchMode = true
            v.stateListAnimator = null
            v.clipChildren = false
            v.clipToPadding = false
            val face = v.findViewById<ViewGroup>(R.id.person_face)
            face.clipToOutline = true
            face.stateListAnimator = null
            face.elevation = 4f
            v.setOnFocusChangeListener { view, hasFocus ->
                PosterCardPresenter.applyFocusScaleElevate(
                    view.findViewById(R.id.person_face),
                    hasFocus,
                )
            }
            return VH(v)
        }

        override fun onBindViewHolder(holder: VH, position: Int) {
            val p = people[position]
            val root = holder.root
            val face = root.findViewById<ViewGroup>(R.id.person_face)
            if (!root.hasFocus()) {
                face.animate().cancel()
                face.scaleX = 1f
                face.scaleY = 1f
                face.elevation = 4f
            }
            val photo = root.findViewById<ImageView>(R.id.person_photo)
            root.findViewById<TextView>(R.id.person_name).text = p.name
            root.findViewById<TextView>(R.id.person_role).text = p.role
            PbGlide.thumb(photo, p.profileUrl, wDp = 104, hDp = 148)
        }

        override fun getItemCount(): Int = people.size
    }

    companion object {
        private const val TAG = "DetailsActivity"
        const val EXTRA_ID = "title_id"
        const val EXTRA_TITLE = "title_name"
    }
}

private class SeasonSection(
    val header: View,
    val scroller: HorizontalScrollView,
    val cards: List<View>,
    val landing: View?,
)

/** Keeps the focused episode card in the middle of its row and on screen vertically. */
private class CenterFocusScroll(
    context: android.content.Context,
) : HorizontalScrollView(context) {
    init {
        isHorizontalScrollBarEnabled = false
        isFocusable = false
        clipChildren = false
        clipToPadding = false
        val pad = resources.getDimensionPixelSize(R.dimen.shelf_inset)
        setPadding(pad, 0, pad, 0)
    }

    override fun requestChildRectangleOnScreen(
        child: View,
        rectangle: Rect,
        immediate: Boolean,
    ): Boolean {
        val target = child.left + rectangle.centerX() - width / 2
        val content = getChildAt(0)?.width ?: 0
        val max = (content - width).coerceAtLeast(0)
        val x = target.coerceIn(0, max)
        if (immediate) scrollTo(x, scrollY) else smoothScrollTo(x, scrollY)
        return super.requestChildRectangleOnScreen(child, rectangle, immediate)
    }
}
