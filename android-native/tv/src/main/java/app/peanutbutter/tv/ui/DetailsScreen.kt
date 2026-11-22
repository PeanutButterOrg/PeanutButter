package app.peanutbutter.tv.ui

import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.LocalBringIntoViewSpec
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.CheckCircleOutline
import androidx.compose.material.icons.rounded.Movie
import androidx.compose.material.icons.rounded.Notifications
import androidx.compose.material.icons.rounded.NotificationsNone
import androidx.compose.material.icons.rounded.Person
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.PlayCircle
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.focusRestorer
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.tv.material3.Icon
import app.peanutbutter.core.Episode
import app.peanutbutter.core.Person
import app.peanutbutter.core.Season
import app.peanutbutter.core.TitleItem
import app.peanutbutter.core.Trailer
import app.peanutbutter.core.TorrentFilePicker
import app.peanutbutter.core.seriesPlayTarget
import app.peanutbutter.tv.ui.compose.MetaRow
import app.peanutbutter.tv.ui.compose.NoScroll
import app.peanutbutter.tv.ui.compose.PbButton
import app.peanutbutter.tv.ui.compose.PbColors
import app.peanutbutter.tv.ui.compose.PbFitTitle
import app.peanutbutter.tv.ui.compose.PbImage
import app.peanutbutter.tv.ui.compose.PbRadius
import app.peanutbutter.tv.ui.compose.PbSize
import app.peanutbutter.tv.ui.compose.PbSpace
import app.peanutbutter.tv.ui.compose.PbType
import app.peanutbutter.tv.ui.compose.PosterCard
import app.peanutbutter.tv.ui.compose.RowScroll
import app.peanutbutter.tv.ui.compose.pbClick
import app.peanutbutter.tv.ui.compose.pbDrawScale
import app.peanutbutter.tv.ui.compose.pbFocusRing
import kotlinx.coroutines.launch

/** What the title page shows; [DetailsActivity] loads it and runs the actions. */
class DetailsState {
    var item by mutableStateOf<TitleItem?>(null)
    /** Looking up sources: a card covers the page (Back cancels). */
    var busy by mutableStateOf(false)
    /** null: this server can't follow series (the button is hidden). */
    var following by mutableStateOf<Boolean?>(null)
    var similar by mutableStateOf<List<TitleItem>>(emptyList())
    /** Bumped to put focus back on Play (after loading, or a cancelled search). */
    var focusPlay by mutableStateOf(0)
    /** Season picked in the Seasons row (null: the one with the episode in progress). */
    var season by mutableStateOf<Int?>(null)
}

interface DetailsActions {
    fun back()
    fun play(fromStart: Boolean)
    fun toggleFavorite()
    fun toggleWatched()
    fun toggleFollow()
    fun playEpisode(season: Season, episode: Episode)
    fun openTrailer(trailer: Trailer)
    fun openTitle(item: TitleItem)
    /** The More like this row is near its end: load the next page. */
    fun loadMoreSimilar()
    fun openPerson(person: Person)
}

private val gutter = PbSpace.gutterTv

private val TitleItem.isSeries: Boolean
    get() = kind.equals("SERIES", true) || kind.equals("TV", true) || kind.equals("ANIME", true)

/** Seasons worth listing: numbered, not specials, with episodes. */
fun playableSeasons(t: TitleItem): List<Season> = t.seasons.filter { s ->
    s.seasonNumber > 0 && !s.name.orEmpty().contains("special", true) && s.episodes.isNotEmpty()
}.sortedBy { it.seasonNumber }

/** The desktop's title page: hero, credits, cast, trailer, seasons and episodes, more like this. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun DetailsScreen(state: DetailsState, actions: DetailsActions) {
    val item = state.item
    val list = rememberLazyListState()
    val scope = rememberCoroutineScope()
    val density = LocalDensity.current
    val screenH = LocalConfiguration.current.screenHeightDp.dp
    val play = remember { FocusRequester() }
    // Each focused block sits about 18% down the screen (the desktop TV build's spot).
    fun reveal(index: Int) = scope.launch {
        if (index == 0) list.animateScrollToItem(0)
        else list.animateScrollToItem(index, -with(density) { (screenH * 0.18f).roundToPx() })
    }

    LaunchedEffect(state.focusPlay, item?.id) {
        if (item != null) runCatching { play.requestFocus() }
    }

    Box(Modifier.fillMaxSize().background(PbColors.ground)) {
        if (item != null) {
            CompositionLocalProvider(LocalBringIntoViewSpec provides NoScroll) {
                LazyColumn(state = list, modifier = Modifier.fillMaxSize()) {
                    sections(item, state, actions, play) { reveal(it) }
                }
            }
        }
        // Back floats over the page, so the D-pad finds nothing below it on
        // its own: Down and Right go to Play.
        BackButton(
            Modifier
                .align(Alignment.TopStart)
                .padding(start = 16.dp, top = 16.dp)
                .focusProperties {
                    down = play
                    right = play
                },
        ) { actions.back() }
        if (state.busy || item == null) BusyCard(if (item == null) null else "Finding sources…")
    }
}

/** One LazyColumn item per focusable block, so each can be scrolled into place. */
private fun androidx.compose.foundation.lazy.LazyListScope.sections(
    t: TitleItem,
    state: DetailsState,
    actions: DetailsActions,
    play: FocusRequester,
    reveal: (Int) -> Unit,
) {
    var index = 0
    val heroAt = index++
    item(key = "hero") { Hero(t, state, actions, play) { if (it) reveal(heroAt) } }
    if (t.people.isNotEmpty()) {
        item(key = "credits") { Credits(t.people) }
        index++
        val castAt = index++
        item(key = "cast") { CastRow(t.people.take(24), actions) { if (it) reveal(castAt) } }
    }
    val trailers = t.playableTrailers
    if (trailers.isNotEmpty()) {
        val at = index++
        item(key = "trailer") { TrailerRow(trailers, actions) { if (it) reveal(at) } }
    }
    val seasons = playableSeasons(t)
    if (seasons.isNotEmpty()) {
        val progressId = t.episodeId
        val picked = (state.season ?: seasons.indexOfFirst { s -> s.episodes.any { it.id == progressId } })
            .coerceIn(0, seasons.lastIndex)
        val season = seasons[picked]
        val episodes = TorrentFilePicker.inViewingOrder(seasons, season)
        val next = episodes.firstOrNull { it.id == progressId }
            ?: episodes.firstOrNull { !it.watched }
            ?: episodes.first()
        fun number(e: Episode) = TorrentFilePicker.viewingNumber(seasons, season.seasonNumber, e.episodeNumber)
        if (seasons.size > 1) {
            val at = index++
            item(key = "seasons") {
                SeasonsRow(seasons, picked, onPick = { state.season = it }) { if (it) reveal(at) }
            }
        }
        index++
        item(key = "episodes-head") {
            Heading("Episodes · ${season.label}", Modifier.padding(start = gutter, end = gutter, top = 16.dp, bottom = 12.dp))
        }
        val upAt = index++
        item(key = "upnext-${next.id}") {
            UpNextCard(next, number(next), t, onFocus = { if (it) reveal(upAt) }) { actions.playEpisode(season, next) }
        }
        episodes.filter { it.id != next.id }.forEach { e ->
            val at = index++
            item(key = "ep-${e.id}") {
                Box(Modifier.padding(horizontal = gutter)) {
                    EpisodeTile(e, number(e), onFocus = { if (it) reveal(at) }) { actions.playEpisode(season, e) }
                }
            }
        }
    }
    if (state.similar.isNotEmpty()) {
        val at = index++
        item(key = "similar") { SimilarRow(state.similar, actions) { if (it) reveal(at) } }
    }
    item(key = "end") { Spacer(Modifier.height(64.dp)) }
}

@Composable
private fun BackButton(modifier: Modifier, onClick: () -> Unit) {
    var focused by remember { mutableStateOf(false) }
    Box(
        contentAlignment = Alignment.Center,
        modifier = modifier
            .pbFocusRing(focused, CircleShape, 1.1f)
            .pbClick({ focused = it }, onClick)
            .size(48.dp)
            .background(Color(0xCC121218), CircleShape),
    ) { Icon(Icons.AutoMirrored.Rounded.ArrowBack, null, tint = PbColors.text, modifier = Modifier.size(26.dp)) }
}

@Composable
private fun BusyCard(text: String?) {
    Box(
        Modifier.fillMaxSize().background(if (text == null) PbColors.ground else Color.Black.copy(alpha = 0.55f)),
        contentAlignment = Alignment.Center,
    ) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Spinner()
            if (text != null) {
                Spacer(Modifier.height(16.dp))
                BasicText(text, style = PbType.title)
            }
        }
    }
}

@Composable
private fun Spinner() {
    val t = androidx.compose.animation.core.rememberInfiniteTransition(label = "spin")
    val angle by t.animateFloat(
        0f, 360f,
        androidx.compose.animation.core.infiniteRepeatable(tween(900, easing = androidx.compose.animation.core.LinearEasing)),
        label = "a",
    )
    androidx.compose.foundation.Canvas(Modifier.size(44.dp)) {
        drawArc(PbColors.primary, angle, 270f, false, style = androidx.compose.ui.graphics.drawscope.Stroke(3.dp.toPx(), cap = androidx.compose.ui.graphics.StrokeCap.Round))
    }
}

// ---- Hero -----------------------------------------------------------------

@OptIn(ExperimentalComposeUiApi::class)
@Composable
private fun Hero(t: TitleItem, state: DetailsState, actions: DetailsActions, play: FocusRequester, onFocus: (Boolean) -> Unit) {
    val h = LocalConfiguration.current.screenHeightDp
    val height = (h * 0.58f).coerceIn(460f, 620f).dp
    val series = t.isSeries
    // Resume shows for the episode (or film) in progress, with From start beside it.
    val target = if (series) t.seriesPlayTarget() else null
    val resume = if (series) t.canResume && target != null && t.episodeId == target.second.id else t.canResume
    Box(Modifier.fillMaxWidth().height(height)) {
        PbImage(t.backdropUrl ?: t.posterUrl, Modifier.fillMaxSize(), 960.dp, height, alignment = Alignment.TopCenter)
        Box(
            Modifier.fillMaxSize().background(
                Brush.horizontalGradient(
                    0f to Color(0xF50E0E12), 0.22f to Color(0xE60E0E12),
                    0.48f to Color(0x990E0E12), 0.72f to Color(0x000E0E12),
                ),
            ),
        )
        Box(
            Modifier.fillMaxSize().background(
                Brush.verticalGradient(
                    0.4f to Color.Transparent, 0.62f to Color(0x000E0E12),
                    0.82f to Color(0x660E0E12), 1f to PbColors.ground,
                ),
            ),
        )
        Column(Modifier.align(Alignment.BottomStart).padding(start = gutter, end = gutter, bottom = 36.dp)) {
            Column(Modifier.width(640.dp)) {
                val kind = when {
                    t.kind.equals("ANIME", true) -> "Anime"
                    series -> "Series"
                    else -> "Movie"
                }
                BasicText(
                    listOfNotNull(kind, t.year?.toString()).joinToString(" · ").uppercase(),
                    style = PbType.label.copy(color = PbColors.primary, letterSpacing = 1.1.sp),
                )
                PbFitTitle(t.displayTitle, PbType.hero.copy(letterSpacing = (-1).sp))
                // Eyebrow, title and facts sit tight so the synopsis gets a third line.
                Spacer(Modifier.height(2.dp))
                Box(Modifier.height(28.dp), contentAlignment = Alignment.CenterStart) { MetaRow(t) }
                Spacer(Modifier.height(10.dp))
                BasicText(
                    t.synopsis.orEmpty(), maxLines = 3, overflow = TextOverflow.Ellipsis,
                    style = PbType.body.copy(color = Color(0xFFD6DAE3), lineHeight = 23.sp),
                )
                Spacer(Modifier.height(16.dp))
            }
            Row(
                horizontalArrangement = Arrangement.spacedBy(10.dp),
                modifier = Modifier.focusRestorer { play },
            ) {
                PbButton(
                    if (resume) "Resume" else "Play", Icons.Rounded.PlayArrow, primary = true,
                    onClick = { actions.play(fromStart = false) },
                    modifier = Modifier.focusRequester(play), onFocus = onFocus,
                )
                if (resume) PbButton("From start", null, primary = false, onClick = { actions.play(fromStart = true) }, onFocus = onFocus)
                PbButton("My List", if (t.favorite) Icons.Rounded.Check else Icons.Rounded.Add, primary = false,
                    onClick = { actions.toggleFavorite() }, onFocus = onFocus)
                PbButton(
                    if (t.watched) "Watched" else "Mark watched",
                    if (t.watched) Icons.Rounded.CheckCircle else Icons.Rounded.CheckCircleOutline,
                    primary = false, onClick = { actions.toggleWatched() }, onFocus = onFocus,
                )
                state.following?.let { on ->
                    PbButton(
                        if (on) "Following" else "Follow",
                        if (on) Icons.Rounded.Notifications else Icons.Rounded.NotificationsNone,
                        primary = false, onClick = { actions.toggleFollow() }, onFocus = onFocus,
                    )
                }
            }
        }
    }
}

/** "Cast: …", "Director: …", "Writers: …" under the hero. */
@Composable
private fun Credits(people: List<Person>) {
    fun names(max: Int, test: (Person) -> Boolean) = people.filter(test).map { it.name }.distinct().take(max)
    val lines = listOf(
        "Cast" to names(5) { it.department.equals("acting", true) || it.department.equals("cast", true) || it.character != null },
        "Director" to names(2) { it.job.equals("director", true) },
        "Writers" to names(3) { it.department.equals("writing", true) || it.job.equals("writer", true) || it.job.equals("screenplay", true) },
    ).filter { it.second.isNotEmpty() }
    if (lines.isEmpty()) return
    Column(Modifier.padding(start = gutter, end = gutter, top = 4.dp, bottom = 8.dp)) {
        lines.forEach { (label, list) ->
            BasicText(
                buildAnnotatedString {
                    withStyle(SpanStyle(color = PbColors.textFaint)) { append("$label: ") }
                    withStyle(SpanStyle(color = PbColors.text)) { append(list.joinToString(", ")) }
                },
                maxLines = 1, overflow = TextOverflow.Ellipsis, style = PbType.meta,
                modifier = Modifier.padding(bottom = 4.dp),
            )
        }
    }
}

@Composable
private fun Heading(text: String, modifier: Modifier = Modifier) {
    BasicText(text, style = PbType.h2, modifier = modifier)
}

// ---- Rows -----------------------------------------------------------------

@OptIn(ExperimentalFoundationApi::class, ExperimentalComposeUiApi::class)
@Composable
private fun <T> Shelf(
    title: String,
    items: List<T>,
    gap: Dp,
    onFocus: (Boolean) -> Unit,
    /** Called as the last few cards come into view (to load more). */
    onNearEnd: (() -> Unit)? = null,
    content: @Composable (T) -> Unit,
) {
    Column(Modifier.padding(top = 12.dp).onFocusChanged { onFocus(it.hasFocus) }) {
        Heading(title, Modifier.padding(horizontal = gutter))
        val first = remember { FocusRequester() }
        CompositionLocalProvider(LocalBringIntoViewSpec provides RowScroll) {
            LazyRow(
                contentPadding = PaddingValues(horizontal = gutter, vertical = 16.dp),
                horizontalArrangement = Arrangement.spacedBy(gap),
                modifier = Modifier.focusRestorer { first },
            ) {
                itemsIndexed(items) { i, it ->
                    if (onNearEnd != null && i >= items.size - 6) LaunchedEffect(items.size) { onNearEnd() }
                    Box(if (i == 0) Modifier.focusRequester(first) else Modifier) { content(it) }
                }
            }
        }
    }
}

@Composable
private fun CastRow(people: List<Person>, actions: DetailsActions, onFocus: (Boolean) -> Unit) {
    Shelf("Cast & crew", people, 18.dp, onFocus) { person -> CastTile(person) { actions.openPerson(person) } }
}

@Composable
private fun CastTile(person: Person, onClick: () -> Unit) {
    var focused by remember { mutableStateOf(false) }
    val w = 104.dp
    val h = 148.dp
    Column(Modifier.width(w)) {
        Box(
            Modifier
                .size(w, h)
                .pbFocusRing(focused, RoundedCornerShape(13.dp), 1.08f)
                .pbClick({ focused = it }, onClick)
                .clip(RoundedCornerShape(10.dp))
                .background(Color(0xFF1C1C24)),
            contentAlignment = Alignment.Center,
        ) {
            if (person.profileUrl.isNullOrBlank()) {
                Icon(Icons.Rounded.Person, null, tint = Color.White.copy(alpha = 0.24f), modifier = Modifier.size(36.dp))
            } else {
                PbImage(person.profileUrl, Modifier.fillMaxSize(), w, h)
            }
        }
        Spacer(Modifier.height(8.dp))
        BasicText(person.name, maxLines = 1, overflow = TextOverflow.Ellipsis, style = PbType.body.copy(fontSize = 14.sp, fontWeight = FontWeight.W600))
        if (person.role.isNotBlank()) {
            BasicText(person.role, maxLines = 1, overflow = TextOverflow.Ellipsis, style = PbType.body.copy(fontSize = 13.sp, color = Color.White.copy(alpha = 0.54f)))
        }
    }
}

@Composable
private fun TrailerRow(trailers: List<Trailer>, actions: DetailsActions, onFocus: (Boolean) -> Unit) {
    Shelf("Trailer", trailers, 18.dp, onFocus) { trailer ->
        var focused by remember { mutableStateOf(false) }
        val shape = RoundedCornerShape(12.dp)
        Column(
            Modifier
                .width(240.dp)
                .pbFocusRing(focused, RoundedCornerShape(15.dp), 1.08f)
                .pbClick({ focused = it }, { actions.openTrailer(trailer) })
                .clip(shape)
                .background(PbColors.surface),
        ) {
            Box(Modifier.fillMaxWidth().height(124.dp), contentAlignment = Alignment.Center) {
                PbImage(trailer.thumbnailUrl, Modifier.fillMaxSize(), 240.dp, 124.dp)
                Box(Modifier.fillMaxSize().background(Color(0x59000000)))
                Icon(Icons.Rounded.PlayCircle, null, tint = Color.White, modifier = Modifier.size(52.dp))
            }
            BasicText(
                trailer.name, maxLines = 1, overflow = TextOverflow.Ellipsis, style = PbType.body.copy(fontSize = 14.sp),
                modifier = Modifier.padding(start = 10.dp, end = 10.dp, top = 6.dp, bottom = 8.dp),
            )
        }
    }
}

@Composable
private fun SimilarRow(items: List<TitleItem>, actions: DetailsActions, onFocus: (Boolean) -> Unit) {
    Box(Modifier.padding(top = 12.dp)) {
        Shelf("More like this", items, 14.dp, onFocus, onNearEnd = actions::loadMoreSimilar) { item ->
            PosterCard(item, PbSize.posterWidthTv, { actions.openTitle(item) })
        }
    }
}

// ---- Seasons and episodes --------------------------------------------------

@OptIn(ExperimentalFoundationApi::class, ExperimentalComposeUiApi::class)
@Composable
private fun SeasonsRow(seasons: List<Season>, selected: Int, onPick: (Int) -> Unit, onFocus: (Boolean) -> Unit) {
    Column(Modifier.padding(top = 16.dp).onFocusChanged { onFocus(it.hasFocus) }) {
        Heading("Seasons", Modifier.padding(horizontal = gutter))
        val first = remember { FocusRequester() }
        CompositionLocalProvider(LocalBringIntoViewSpec provides RowScroll) {
            LazyRow(
                contentPadding = PaddingValues(horizontal = gutter, vertical = 14.dp),
                horizontalArrangement = Arrangement.spacedBy(12.dp),
                modifier = Modifier.focusRestorer { first },
            ) {
                itemsIndexed(seasons) { i, s ->
                    Box(if (i == 0) Modifier.focusRequester(first) else Modifier) {
                        SeasonCard(s, seasons, i == selected) { onPick(i) }
                    }
                }
            }
        }
    }
}

@Composable
private fun SeasonCard(season: Season, all: List<Season>, selected: Boolean, onClick: () -> Unit) {
    var focused by remember { mutableStateOf(false) }
    val w = 120.dp
    val eps = TorrentFilePicker.inViewingOrder(all, season)
    val done = eps.count { it.watched }
    val ring = RoundedCornerShape(PbRadius.card + 3.dp)
    Column(Modifier.width(w)) {
        Box(
            Modifier
                .size(w, w * 1.5f)
                .pbFocusRing(focused, ring)
                .pbClick({ focused = it }, onClick)
                .border(PbSize.focusRing, if (selected && !focused) PbColors.primary else Color.Transparent, ring)
                .padding(PbSize.focusRing)
                .clip(RoundedCornerShape(PbRadius.card))
                .background(Brush.linearGradient(listOf(Color(0xFF2A2D37), PbColors.surface))),
            contentAlignment = Alignment.Center,
        ) {
            if (season.posterPath.isNullOrBlank()) {
                BasicText(season.label.uppercase(), style = PbType.h2.copy(fontSize = 20.sp), modifier = Modifier.padding(8.dp))
            } else {
                PbImage(season.posterPath, Modifier.fillMaxSize(), w, w * 1.5f)
            }
        }
        Spacer(Modifier.height(8.dp))
        BasicText(season.label, maxLines = 1, overflow = TextOverflow.Ellipsis,
            style = PbType.button.copy(color = if (selected) PbColors.primary else PbColors.text))
        BasicText(
            if (done == 0) "${eps.size} episodes" else "$done of ${eps.size} watched",
            style = PbType.meta.copy(fontSize = 13.sp, color = if (done == eps.size && eps.isNotEmpty()) PbColors.good else PbColors.textMuted),
        )
    }
}

private fun Episode.started() = !watched && (positionMs > 2000 || progressPercent > 0)

private fun Episode.sub(): String = listOfNotNull(
    runtime?.takeIf { it > 0 }?.let { if (it < 60) "${it}m" else if (it % 60 == 0) "${it / 60}h" else "${it / 60}h ${it % 60}m" },
    when {
        watched -> "Watched"
        started() -> "${(progressPercent * 100).toInt().coerceIn(0, 100)}% watched"
        else -> null
    },
).joinToString(" · ")

@Composable
private fun Still(e: Episode, width: Dp, radius: Dp) {
    Box(
        Modifier.size(width, width * 9f / 16f).clip(RoundedCornerShape(radius)).background(PbColors.surfaceRaised),
        contentAlignment = Alignment.Center,
    ) {
        if (e.stillPath.isNullOrBlank()) {
            Icon(Icons.Rounded.Movie, null, tint = PbColors.textFaint, modifier = Modifier.size(28.dp))
        } else {
            PbImage(e.stillPath, Modifier.fillMaxSize(), width, width * 9f / 16f)
        }
        if (e.started()) {
            Box(Modifier.align(Alignment.BottomStart).fillMaxWidth().height(4.dp).background(Color.Black.copy(alpha = 0.45f))) {
                Box(Modifier.fillMaxWidth(e.progressPercent.toFloat().coerceIn(0.02f, 1f)).height(4.dp).background(PbColors.primary))
            }
        }
        if (e.watched) {
            Icon(Icons.Rounded.CheckCircle, null, tint = PbColors.good,
                modifier = Modifier.align(Alignment.TopEnd).padding(6.dp).size(18.dp))
        }
    }
}

/** Up next: the episode to watch, big, with a Play button. */
@Composable
private fun UpNextCard(e: Episode, number: Int, t: TitleItem, onFocus: (Boolean) -> Unit, onPlay: () -> Unit) {
    val started = e.started() || (t.episodeId == e.id && t.canResume)
    val shape = RoundedCornerShape(PbRadius.panel + 4.dp)
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .padding(start = gutter, end = gutter, bottom = 12.dp)
            .fillMaxWidth()
            .background(Brush.linearGradient(listOf(Color(0xFF1C1D25), PbColors.surface)), shape)
            .border(1.dp, PbColors.line, shape)
            .padding(14.dp),
    ) {
        Still(e, 340.dp, PbRadius.panel - 4.dp)
        Spacer(Modifier.width(24.dp))
        Column(Modifier.weight(1f)) {
            BasicText(
                "${if (started) "CONTINUE" else "UP NEXT"} · EPISODE $number",
                style = PbType.label.copy(color = PbColors.primary, letterSpacing = 1.1.sp),
            )
            Spacer(Modifier.height(6.dp))
            BasicText(e.name ?: "Episode $number", maxLines = 2, overflow = TextOverflow.Ellipsis, style = PbType.h1.copy(fontSize = 28.sp))
            if (e.sub().isNotEmpty()) {
                Spacer(Modifier.height(4.dp))
                BasicText(e.sub(), style = PbType.meta)
            }
            if (!e.overview.isNullOrBlank()) {
                Spacer(Modifier.height(8.dp))
                BasicText(e.overview!!, maxLines = 3, overflow = TextOverflow.Ellipsis,
                    style = PbType.body.copy(color = Color(0xFFD6DAE3), lineHeight = 23.sp))
            }
            Spacer(Modifier.height(14.dp))
            PbButton(if (started) "Resume" else "Play", Icons.Rounded.PlayArrow, primary = true, onClick = onPlay, onFocus = onFocus)
        }
    }
}

@Composable
private fun EpisodeTile(e: Episode, number: Int, onFocus: (Boolean) -> Unit, onPlay: () -> Unit) {
    var focused by remember { mutableStateOf(false) }
    val started = e.started()
    val shape = RoundedCornerShape(PbRadius.card)
    val scale by animateFloatAsState(if (focused) 1.01f else 1f, tween(140), label = "ep")
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .padding(bottom = 6.dp)
            .fillMaxWidth()
            .pbDrawScale(scale)
            .pbClick({ focused = it; onFocus(it) }, onPlay)
            .background(if (focused) PbColors.surfaceRaised else Color.Transparent, shape)
            .border(PbSize.focusRing, if (focused) PbColors.focus else Color.Transparent, shape)
            .padding(horizontal = 10.dp, vertical = 10.dp),
    ) {
        Still(e, 150.dp, PbRadius.card - 2.dp)
        Spacer(Modifier.width(16.dp))
        Column(Modifier.weight(1f)) {
            BasicText("$number. ${e.name ?: "Episode"}", maxLines = 1, overflow = TextOverflow.Ellipsis,
                style = PbType.title.copy(color = if (started) PbColors.primary else PbColors.text))
            if (e.sub().isNotEmpty()) BasicText(e.sub(), style = PbType.meta)
            if (!e.overview.isNullOrBlank()) {
                Spacer(Modifier.height(4.dp))
                BasicText(e.overview!!, maxLines = 2, overflow = TextOverflow.Ellipsis,
                    style = PbType.meta.copy(color = PbColors.textFaint, lineHeight = 21.sp))
            }
        }
        Spacer(Modifier.width(12.dp))
        Box(
            contentAlignment = Alignment.Center,
            modifier = Modifier.size(42.dp).background(
                if (started || focused) PbColors.primary else Color.White.copy(alpha = 0.10f), CircleShape,
            ),
        ) {
            Icon(Icons.Rounded.PlayArrow, null,
                tint = if (started || focused) PbColors.onPrimary else PbColors.text, modifier = Modifier.size(24.dp))
        }
    }
}
