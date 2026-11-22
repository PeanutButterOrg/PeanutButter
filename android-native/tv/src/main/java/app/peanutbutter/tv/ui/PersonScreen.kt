package app.peanutbutter.tv.ui

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.LocalBringIntoViewSpec
import androidx.compose.foundation.gestures.animateScrollBy
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
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.rounded.Person
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.focusRestorer
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.tv.material3.Icon
import app.peanutbutter.core.PersonCredit
import app.peanutbutter.core.PersonDetails
import app.peanutbutter.core.TitleItem
import app.peanutbutter.tv.ui.compose.NoScroll
import app.peanutbutter.tv.ui.compose.PbColors
import app.peanutbutter.tv.ui.compose.PbImage
import app.peanutbutter.tv.ui.compose.PbRadius
import app.peanutbutter.tv.ui.compose.PbSize
import app.peanutbutter.tv.ui.compose.PbSpace
import app.peanutbutter.tv.ui.compose.PbType
import app.peanutbutter.tv.ui.compose.PosterCard
import app.peanutbutter.tv.ui.compose.RowScroll
import app.peanutbutter.tv.ui.compose.ScoreChip
import app.peanutbutter.tv.ui.compose.pbClick
import app.peanutbutter.tv.ui.compose.pbFocusRing
import kotlinx.coroutines.launch

/** A cast or crew member's page; [PersonActivity] loads it. */
class PersonState {
    var name by mutableStateOf("")
    var person by mutableStateOf<PersonDetails?>(null)
    var error by mutableStateOf<String?>(null)
    /** Fetching a credit the catalog didn't have yet. */
    var opening by mutableStateOf(false)
}

private val gutter = PbSpace.gutterTv

/** One row of the page: a heading and its cards. */
private class CreditRow(val key: String, val title: String, val credits: List<PersonCredit>, val wide: Boolean = false)

/** Only what's out (older servers also send announced titles): a year, and not a future one. */
private fun PersonDetails.released(): PersonDetails {
    val thisYear = java.util.Calendar.getInstance().get(java.util.Calendar.YEAR)
    fun out(c: PersonCredit) = (c.year ?: Int.MAX_VALUE) <= thisYear
    return copy(acting = acting.filter(::out), crew = crew.filter(::out))
}

/**
 * Their best-known titles first (most TMDB votes, then popularity), then
 * what they acted in by kind, newest first, then their work behind the camera.
 */
private fun rowsFor(p: PersonDetails): List<CreditRow> {
    val all = (p.acting + p.crew).distinctBy { it.kind to it.tmdbId }
    val known = all
        .filter { it.voteCount > 0 || it.popularity > 0.0 }
        .sortedWith(compareByDescending<PersonCredit> { it.voteCount }.thenByDescending { it.popularity })
        .take(12)
    // Newest first; titles without a year go last (sortedBy keeps ties in order).
    fun newest(credits: List<PersonCredit>) = credits.sortedByDescending { it.year ?: -1 }
    val movies = newest(p.acting.filter { it.kind.equals("MOVIE", true) })
    val series = newest(p.acting.filter { !it.kind.equals("MOVIE", true) })
    val crew = newest(p.crew)
    return listOfNotNull(
        CreditRow("known", "Known for", known, wide = true).takeIf { known.size >= 3 },
        CreditRow("movies", "Movies", movies).takeIf { movies.isNotEmpty() },
        CreditRow("series", "Series", series).takeIf { series.isNotEmpty() },
        CreditRow("crew", "Behind the camera", crew).takeIf { crew.isNotEmpty() },
    )
}

/**
 * The person page, in the app's own look: their best-known title's art
 * behind a portrait, name, birth and bio, then rows like Home's.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun PersonScreen(state: PersonState, onBack: () -> Unit, onOpen: (PersonCredit) -> Unit) {
    val person = remember(state.person) { state.person?.released() }
    val rows = remember(person) { person?.let(::rowsFor).orEmpty() }
    val list = rememberLazyListState()
    val scope = rememberCoroutineScope()
    val density = LocalDensity.current
    val screenH = LocalConfiguration.current.screenHeightDp.dp
    val back = remember { FocusRequester() }
    val firstRow = remember { FocusRequester() }
    // Once, when the page first loads (more credits may arrive later).
    LaunchedEffect(person != null, state.error) {
        runCatching { if (rows.isNotEmpty()) firstRow.requestFocus() else back.requestFocus() }
    }
    fun reveal(index: Int) = scope.launch {
        if (index <= 1) {
            list.animateScrollToItem(0)
            // A long name or bio can push the first row's titles off the bottom.
            val info = list.layoutInfo
            info.visibleItemsInfo.firstOrNull { it.index == 1 }?.let { row ->
                val over = row.offset + row.size - info.viewportEndOffset
                if (over > 0) list.animateScrollBy(over.toFloat())
            }
        } else list.animateScrollToItem(index, -with(density) { (screenH * 0.12f).roundToPx() })
    }
    val heroArt = rows.firstOrNull { it.wide }?.credits?.firstOrNull { it.backdropUrl != null }
        ?: person?.let { p -> (p.acting + p.crew).firstOrNull { it.backdropUrl != null } }

    Box(Modifier.fillMaxSize().background(PbColors.ground)) {
        CompositionLocalProvider(LocalBringIntoViewSpec provides NoScroll) {
            LazyColumn(state = list, modifier = Modifier.fillMaxSize()) {
                item(key = "hero") { Hero(state, heroArt) }
                rows.forEachIndexed { i, row ->
                    item(key = row.key) {
                        CreditShelf(row, if (i == 0) firstRow else null, onOpen) { if (it) reveal(i + 1) }
                    }
                }
                state.error?.let { msg ->
                    item(key = "error") {
                        BasicText(
                            msg,
                            style = PbType.body.copy(color = PbColors.textMuted, textAlign = TextAlign.Center),
                            modifier = Modifier.fillMaxWidth().padding(48.dp),
                        )
                    }
                }
                item(key = "end") { Spacer(Modifier.height(56.dp)) }
            }
        }
        // Only over the hero: further down it would sit on the row headings
        // (the remote's Back still leaves).
        val atTop = list.firstVisibleItemIndex == 0 && list.firstVisibleItemScrollOffset < 40
        androidx.compose.animation.AnimatedVisibility(
            visible = atTop,
            enter = androidx.compose.animation.fadeIn(),
            exit = androidx.compose.animation.fadeOut(),
            modifier = Modifier.align(Alignment.TopStart),
        ) {
            BackButton(
                Modifier
                    .padding(start = 16.dp, top = 16.dp)
                    .focusRequester(back)
                    .focusProperties {
                        if (rows.isNotEmpty()) {
                            down = firstRow
                            right = firstRow
                        }
                    },
                onBack,
            )
        }
        if (state.opening) {
            Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.55f)), contentAlignment = Alignment.Center) {
                BasicText("Opening…", style = PbType.h2)
            }
        }
    }
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

/** Their best-known title's art, faded, behind portrait, name, facts and bio. */
@Composable
private fun Hero(state: PersonState, art: PersonCredit?) {
    val p = remember(state.person) { state.person?.released() }
    // As tall as its content, not a share of the screen: the first row's
    // titles must fit below it, and without art a tall hero is a black gap.
    Box(Modifier.fillMaxWidth()) {
        art?.backdropUrl?.let { url ->
            PbImage(url, Modifier.matchParentSize(), 1200.dp, 420.dp, alignment = Alignment.TopCenter)
        }
        Box(
            Modifier.matchParentSize().background(
                Brush.horizontalGradient(
                    0f to Color(0xFA0E0E12), 0.35f to Color(0xE60E0E12),
                    0.6f to Color(0x990E0E12), 0.85f to Color(0x330E0E12),
                ),
            ),
        )
        Box(
            Modifier.matchParentSize().background(
                Brush.verticalGradient(0.45f to Color.Transparent, 1f to PbColors.ground),
            ),
        )
        Row(
            verticalAlignment = Alignment.Top,
            modifier = Modifier.padding(start = gutter, end = gutter, top = 84.dp, bottom = 8.dp),
        ) {
            val shape = RoundedCornerShape(PbRadius.card + 4.dp)
            Box(
                Modifier
                    .size(150.dp, 225.dp)
                    .shadow(24.dp, shape)
                    .clip(shape)
                    .background(PbColors.surface),
                contentAlignment = Alignment.Center,
            ) {
                if (p?.profileUrl.isNullOrBlank()) {
                    Icon(Icons.Rounded.Person, null, tint = Color.White.copy(alpha = 0.24f), modifier = Modifier.size(56.dp))
                } else {
                    PbImage(p?.profileUrl, Modifier.fillMaxSize(), 150.dp, 225.dp, alignment = Alignment.TopCenter)
                }
            }
            Spacer(Modifier.width(28.dp))
            Column(Modifier.widthIn(max = 720.dp)) {
                p?.knownFor?.let(::designation)?.let {
                    BasicText(it.uppercase(), style = PbType.label.copy(color = PbColors.primary, letterSpacing = 1.1.sp))
                }
                BasicText(
                    p?.name ?: state.name,
                    maxLines = 2, overflow = TextOverflow.Ellipsis,
                    style = PbType.hero.copy(fontSize = 44.sp, lineHeight = 48.sp, letterSpacing = (-0.5).sp),
                )
                p?.let { person ->
                    val facts = facts(person)
                    if (facts.isNotEmpty()) {
                        Spacer(Modifier.height(2.dp))
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            facts.forEachIndexed { i, f ->
                                if (i > 0) {
                                    Box(Modifier.padding(horizontal = 9.dp).size(4.dp).background(Color.White.copy(alpha = 0.45f), CircleShape))
                                }
                                BasicText(f, maxLines = 1, style = PbType.meta.copy(fontSize = 15.sp, color = Color.White.copy(alpha = 0.82f)))
                            }
                        }
                    }
                }
                p?.biography?.let {
                    Spacer(Modifier.height(20.dp))
                    BasicText(
                        it, maxLines = 3, overflow = TextOverflow.Ellipsis,
                        style = PbType.body.copy(color = Color(0xFFD6DAE3), lineHeight = 23.sp),
                    )
                }
                when {
                    p == null && state.error == null -> {
                        Spacer(Modifier.height(12.dp))
                        BasicText("Loading…", style = PbType.body.copy(color = PbColors.textFaint))
                    }
                    p != null && p.checkingCredits > 0 -> {
                        Spacer(Modifier.height(10.dp))
                        BasicText("Checking more titles…", style = PbType.meta.copy(color = PbColors.textFaint))
                    }
                }
            }
        }
    }
}

/** TMDB's department ("Acting", "Directing") as what they are ("Actor", "Director"). */
private fun designation(department: String): String = when (department.trim().lowercase()) {
    "acting" -> "Actor"
    "directing" -> "Director"
    "writing" -> "Writer"
    "production" -> "Producer"
    "editing" -> "Editor"
    "camera" -> "Cinematographer"
    "sound" -> "Composer & sound"
    "art" -> "Production designer"
    "costume & make-up" -> "Costume & make-up"
    "visual effects" -> "Visual effects"
    "lighting" -> "Lighting"
    "creator" -> "Creator"
    else -> department
}

/** "Born 21 Jul 2005 (age 21)", "Melbourne, Australia", "41 titles". */
private fun facts(p: PersonDetails): List<String> {
    // SimpleDateFormat, not java.time: that needs Android 8 and TVs run 7.
    fun parse(d: String) = runCatching { java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.US).parse(d) }.getOrNull()
    fun show(d: java.util.Date) = java.text.SimpleDateFormat("d MMM yyyy", java.util.Locale.US).format(d)
    fun yearsBetween(a: java.util.Date, b: java.util.Date): Int {
        val ca = java.util.Calendar.getInstance().apply { time = a }
        val cb = java.util.Calendar.getInstance().apply { time = b }
        var years = cb.get(java.util.Calendar.YEAR) - ca.get(java.util.Calendar.YEAR)
        if (cb.get(java.util.Calendar.DAY_OF_YEAR) < ca.get(java.util.Calendar.DAY_OF_YEAR)) years--
        return years
    }
    val born = p.birthday?.let(::parse)
    val died = p.deathday?.let(::parse)
    val titles = (p.acting + p.crew).distinctBy { it.kind to it.tmdbId }.size
    return listOfNotNull(
        born?.let { b ->
            if (died != null) "${show(b)} – ${show(died)} (aged ${yearsBetween(b, died)})"
            else "Born ${show(b)} (age ${yearsBetween(b, java.util.Date())})"
        },
        p.placeOfBirth,
        "$titles title${if (titles == 1) "" else "s"}".takeIf { titles > 0 },
    )
}

@OptIn(ExperimentalFoundationApi::class, ExperimentalComposeUiApi::class)
@Composable
private fun CreditShelf(
    row: CreditRow,
    focus: FocusRequester?,
    onOpen: (PersonCredit) -> Unit,
    onFocus: (Boolean) -> Unit,
) {
    Column(Modifier.padding(top = 14.dp).onFocusChanged { onFocus(it.hasFocus) }) {
        Row(verticalAlignment = Alignment.Bottom, modifier = Modifier.padding(horizontal = gutter)) {
            BasicText(row.title, style = PbType.h2)
            Spacer(Modifier.width(10.dp))
            BasicText("${row.credits.size}", style = PbType.meta.copy(color = PbColors.textFaint))
        }
        val first = remember { FocusRequester() }
        CompositionLocalProvider(LocalBringIntoViewSpec provides RowScroll) {
            LazyRow(
                contentPadding = PaddingValues(horizontal = gutter, vertical = 14.dp),
                horizontalArrangement = Arrangement.spacedBy(if (row.wide) 16.dp else 14.dp),
                modifier = (if (focus != null) Modifier.focusRequester(focus) else Modifier).focusRestorer { first },
            ) {
                itemsIndexed(row.credits, key = { _, c -> "${c.kind}-${c.tmdbId}" }) { i, c ->
                    Box(if (i == 0) Modifier.focusRequester(first) else Modifier) {
                        if (row.wide) KnownForCard(c) { onOpen(c) } else CreditCard(c, PbSize.posterWidthTv) { onOpen(c) }
                    }
                }
            }
        }
    }
}

/** A credit as a TitleItem, for the poster card (outside the catalog: a stand-in id). */
private fun PersonCredit.asTitle() = TitleItem(
    id = titleId ?: "tmdb-$kind-$tmdbId",
    kind = kind,
    title = title,
    year = year,
    posterUrl = posterUrl,
    backdropUrl = backdropUrl,
    tmdbVoteAverage = voteAverage,
)

private fun PersonCredit.caption() = listOfNotNull(year?.toString(), role).joinToString(" · ")

@Composable
private fun CreditCard(credit: PersonCredit, width: Dp, onClick: () -> Unit) {
    Column(Modifier.width(width)) {
        PosterCard(credit.asTitle(), width, onClick)
        Spacer(Modifier.height(8.dp))
        BasicText(
            credit.title, maxLines = 1, overflow = TextOverflow.Ellipsis,
            style = PbType.body.copy(fontSize = 14.sp, fontWeight = FontWeight.W600),
        )
        val caption = credit.caption()
        if (caption.isNotEmpty()) {
            BasicText(
                caption, maxLines = 1, overflow = TextOverflow.Ellipsis,
                style = PbType.body.copy(fontSize = 13.sp, color = Color.White.copy(alpha = 0.54f)),
            )
        }
    }
}

/** Known for: the title's wide art with its name, year and their role on it. */
@Composable
private fun KnownForCard(credit: PersonCredit, onClick: () -> Unit) {
    var focused by remember { mutableStateOf(false) }
    val width = PbSize.wideCardWidthTv
    val height = width * 9f / 16f
    val shape = RoundedCornerShape(PbRadius.card)
    Box(
        Modifier
            .size(width, height)
            .pbFocusRing(focused, RoundedCornerShape(PbRadius.card + 3.dp))
            .pbClick({ focused = it }, onClick)
            .clip(shape)
            .background(PbColors.surface),
    ) {
        PbImage(credit.backdropUrl ?: credit.posterUrl, Modifier.fillMaxSize(), width, height)
        Box(Modifier.fillMaxSize().background(Brush.verticalGradient(0.35f to Color.Transparent, 1f to Color(0xE6000000))))
        Box(Modifier.align(Alignment.TopStart).padding(8.dp)) { ScoreChip(credit.asTitle()) }
        Column(Modifier.align(Alignment.BottomStart).padding(start = 12.dp, end = 12.dp, bottom = 12.dp)) {
            BasicText(credit.title, maxLines = 1, overflow = TextOverflow.Ellipsis, style = PbType.title)
            val caption = credit.caption()
            if (caption.isNotEmpty()) {
                BasicText(
                    caption, maxLines = 1, overflow = TextOverflow.Ellipsis,
                    style = PbType.meta.copy(color = PbColors.textMuted),
                )
            }
        }
    }
}
