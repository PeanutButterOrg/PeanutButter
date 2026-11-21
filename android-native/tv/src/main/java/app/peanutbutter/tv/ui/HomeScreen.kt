package app.peanutbutter.tv.ui

import androidx.compose.animation.Crossfade
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.BringIntoViewSpec
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
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.Favorite
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material.icons.rounded.Person
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material.icons.rounded.VideoLibrary
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.scale
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.focusRestorer
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.tv.material3.Icon
import app.peanutbutter.core.HomeLayout
import app.peanutbutter.core.HomeSections
import app.peanutbutter.core.HomeShelf
import app.peanutbutter.core.ShelfStyle
import app.peanutbutter.core.TitleItem
import app.peanutbutter.tv.ui.compose.MetaRow
import app.peanutbutter.tv.ui.compose.PbButton
import app.peanutbutter.tv.ui.compose.PbColors
import app.peanutbutter.tv.ui.compose.PbImage
import app.peanutbutter.tv.ui.compose.PbLogo
import app.peanutbutter.tv.ui.compose.PbRadius
import app.peanutbutter.tv.ui.compose.PbSize
import app.peanutbutter.tv.ui.compose.PbSpace
import app.peanutbutter.tv.ui.compose.PbType
import app.peanutbutter.tv.ui.compose.PosterCard
import app.peanutbutter.tv.ui.compose.Top10Tile
import app.peanutbutter.tv.ui.compose.WideCard
import app.peanutbutter.tv.ui.compose.pbClick
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** What the home screen shows; [MainActivity] loads it. */
class HomeState {
    var section by mutableStateOf(HomeSections.HOME)
    var layout by mutableStateOf<HomeLayout?>(null)
    var loading by mutableStateOf(true)
    /** The screen is in front (the hero only turns then). */
    var active by mutableStateOf(true)
    /** My List taps not yet in the feed (title id -> on the list). */
    val listed = mutableStateMapOf<String, Boolean>()
    /** Set when the top bar holds focus (Back then asks to exit). */
    var inTopBar by mutableStateOf(false)
    /** Bumped by Back: scroll to the top and focus the section's tab. */
    var toTop by mutableIntStateOf(0)
}

interface HomeActions {
    fun select(section: String)
    fun openDetails(item: TitleItem, play: Boolean = false)
    fun openShelf(shelf: HomeShelf)
    fun openExplore()
    fun openSearch()
    fun openFavourites()
    fun openWatched()
    fun openSettings()
    fun setOnList(item: TitleItem, on: Boolean, done: (Boolean) -> Unit)
}

private val gutter = PbSpace.gutterTv
private val posterWidth = PbSize.posterWidthTv
private val gap = 16.dp

/** Flutter's TV home: fixed top bar over the hero carousel and shelves. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun HomeScreen(state: HomeState, actions: HomeActions) {
    val list = rememberLazyListState()
    val scope = rememberCoroutineScope()
    val topBarPx = with(LocalDensity.current) { PbSize.topBarHeightTv.roundToPx() }
    val tabs = remember { List(3) { FocusRequester() } }
    val play = remember { FocusRequester() }
    var focusedOnce by remember { mutableStateOf(false) }

    LaunchedEffect(state.toTop) {
        if (state.toTop == 0) return@LaunchedEffect
        list.animateScrollToItem(0)
        tabs[tabIndex(state.section)].requestFocus()
    }

    Box(Modifier.fillMaxSize().background(PbColors.ground)) {
        val layout = state.layout
        // Vertical scrolling is ours (a focused row's name sits under the top
        // bar); rows keep the focused card about 42% in, like the desktop TV build.
        CompositionLocalProvider(LocalBringIntoViewSpec provides NoScroll) {
            LazyColumn(state = list, modifier = Modifier.fillMaxSize()) {
                if (layout != null && layout.hero.isNotEmpty()) {
                    item(key = "hero-${state.section}") {
                        Hero(
                            state, layout, actions, play, tabs[tabIndex(state.section)],
                            onFocus = { if (it) scope.launch { list.animateScrollToItem(0) } },
                        )
                    }
                }
                val shelves = layout?.shelves.orEmpty().filter { it.items.isNotEmpty() }
                itemsIndexed(shelves, key = { _, s -> "${state.section}-${s.title}" }) { i, shelf ->
                    val index = i + if (layout?.hero.isNullOrEmpty()) 0 else 1
                    Shelf(shelf, actions) { focused ->
                        if (focused) scope.launch { list.animateScrollToItem(index, -topBarPx) }
                    }
                }
                item { Spacer(Modifier.height(64.dp)) }
            }
        }
        val scrolled = list.firstVisibleItemIndex > 0 || list.firstVisibleItemScrollOffset > 120
        TopBar(state, actions, tabs, scrolled, down = if (layout?.hero.isNullOrEmpty()) FocusRequester.Default else play)
        if (state.loading) {
            Box(Modifier.fillMaxSize().padding(top = PbSize.topBarHeightTv).background(PbColors.ground))
        }
    }

    LaunchedEffect(state.layout) {
        if (!focusedOnce && state.layout?.hero?.isNotEmpty() == true) {
            focusedOnce = true
            delay(50)
            runCatching { play.requestFocus() }
        }
    }
}

private fun tabIndex(section: String) = when (section) {
    "MOVIE" -> 1
    "SERIES" -> 2
    else -> 0
}

@OptIn(ExperimentalFoundationApi::class)
private val NoScroll = object : BringIntoViewSpec {
    override fun calculateScrollDistance(offset: Float, size: Float, containerSize: Float) = 0f
}

@OptIn(ExperimentalFoundationApi::class)
private val RowScroll = object : BringIntoViewSpec {
    override fun calculateScrollDistance(offset: Float, size: Float, containerSize: Float) =
        offset - (containerSize - size) * 0.42f
}

// ---- Top bar --------------------------------------------------------------

@OptIn(ExperimentalComposeUiApi::class)
@Composable
private fun TopBar(
    state: HomeState,
    actions: HomeActions,
    tabs: List<FocusRequester>,
    scrolled: Boolean,
    down: FocusRequester,
) {
    // The bar sits over the hero, so Down is routed: geometric search from it found nothing.
    val toContent = Modifier.focusProperties { this.down = down }
    val scrim by animateFloatAsState(if (scrolled) 1f else 0f, tween(180), label = "scrim")
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .height(PbSize.topBarHeightTv)
            .background(
                Brush.verticalGradient(
                    listOf(
                        PbColors.ground.copy(alpha = 0.85f + 0.15f * scrim),
                        PbColors.ground.copy(alpha = scrim),
                    ),
                ),
            )
            .onFocusChanged { state.inTopBar = it.hasFocus }
            .focusRestorer { tabs[tabIndex(state.section)] }
            .padding(horizontal = gutter),
    ) {
        PbLogo()
        Spacer(Modifier.width(36.dp))
        Tab("Home", state.section == HomeSections.HOME, toContent.focusRequester(tabs[0])) { actions.select(HomeSections.HOME) }
        Tab("Movies", state.section == "MOVIE", toContent.focusRequester(tabs[1])) { actions.select("MOVIE") }
        Tab("Series", state.section == "SERIES", toContent.focusRequester(tabs[2])) { actions.select("SERIES") }
        Tab("Explore", false, toContent) { actions.openExplore() }
        Spacer(Modifier.weight(1f))
        HeaderIcon(Icons.Rounded.Favorite, toContent) { actions.openFavourites() }
        HeaderIcon(Icons.Rounded.VideoLibrary, toContent) { actions.openWatched() }
        HeaderIcon(Icons.Rounded.Search, toContent) { actions.openSearch() }
        Spacer(Modifier.width(12.dp))
        DeviceSquare(toContent) { actions.openSettings() }
    }
}

/** A section label; the selected one is white with an amber underline. */
@Composable
private fun Tab(label: String, selected: Boolean, modifier: Modifier = Modifier, onClick: () -> Unit) {
    var focused by remember { mutableStateOf(false) }
    val pill = RoundedCornerShape(PbRadius.pill)
    val line by animateDpAsState(if (selected) 22.dp else 0.dp, tween(120), label = "tab")
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        modifier = modifier
            .padding(end = 8.dp)
            .pbClick({ focused = it }, onClick)
            .border(PbSize.focusRing, if (focused) PbColors.focus else Color.Transparent, pill)
            .padding(horizontal = 14.dp, vertical = 8.dp),
    ) {
        BasicText(
            label,
            style = PbType.button.copy(fontSize = 17.sp, color = if (selected || focused) PbColors.text else PbColors.textMuted),
        )
        Spacer(Modifier.height(5.dp))
        Box(Modifier.width(line).height(2.dp).background(PbColors.primary, RoundedCornerShape(2.dp)))
    }
}

@Composable
private fun HeaderIcon(icon: ImageVector, modifier: Modifier, onClick: () -> Unit) {
    var focused by remember { mutableStateOf(false) }
    val scale by animateFloatAsState(if (focused) 1.1f else 1f, tween(120), label = "icon")
    Box(
        contentAlignment = Alignment.Center,
        modifier = modifier
            .scale(scale)
            .size(48.dp)
            .pbClick({ focused = it }, onClick)
            .background(if (focused) PbColors.focus.copy(alpha = 0.22f) else Color.Transparent, CircleShape)
            .border(if (focused) 2.dp else 0.dp, if (focused) PbColors.focus else Color.Transparent, CircleShape),
    ) {
        Icon(icon, null, tint = PbColors.text, modifier = Modifier.size(28.dp))
    }
}

/** The device square: opens Settings. */
@Composable
private fun DeviceSquare(modifier: Modifier, onClick: () -> Unit) {
    var focused by remember { mutableStateOf(false) }
    val shape = RoundedCornerShape(9.dp)
    val scale by animateFloatAsState(if (focused) 1.1f else 1f, tween(120), label = "square")
    Box(
        contentAlignment = Alignment.Center,
        modifier = modifier
            .scale(scale)
            .size(38.dp)
            .pbClick({ focused = it }, onClick)
            .background(Brush.linearGradient(listOf(Color(0xFFF0BC72), PbColors.primary)), shape)
            .border(if (focused) PbSize.focusRing else 0.dp, if (focused) PbColors.focus else Color.Transparent, shape),
    ) {
        Icon(Icons.Rounded.Person, null, tint = PbColors.onPrimary, modifier = Modifier.size(24.dp))
    }
}

// ---- Hero -----------------------------------------------------------------

@OptIn(ExperimentalComposeUiApi::class)
@Composable
private fun Hero(
    state: HomeState,
    layout: HomeLayout,
    actions: HomeActions,
    play: FocusRequester,
    tab: FocusRequester,
    onFocus: (Boolean) -> Unit,
) {
    var index by remember(layout) { mutableIntStateOf(0) }
    var touched by remember { mutableIntStateOf(0) }
    val items = layout.hero
    val item = items[index % items.size]
    // A new slide every 8 s; moving between the buttons gives it a fresh 8 s.
    LaunchedEffect(layout, index, touched, state.active) {
        if (!state.active || items.size < 2) return@LaunchedEffect
        delay(8_000)
        index = (index + 1) % items.size
    }
    val heroHeight = heroHeight()
    Box(Modifier.fillMaxWidth().height(heroHeight)) {
            Crossfade(item, animationSpec = tween(900), label = "hero") { slide ->
                PbImage(
                    slide.backdropUrl?.takeIf { it.isNotBlank() } ?: slide.posterUrl,
                    Modifier.fillMaxSize(),
                    widthDp = 960.dp,
                    heightDp = heroHeight,
                    alignment = Alignment.TopCenter,
                )
            }
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
            Column(
                Modifier
                    .align(Alignment.BottomStart)
                    .padding(start = gutter, bottom = 36.dp)
                    .width(560.dp),
            ) {
                Crossfade(item, animationSpec = tween(450), label = "copy") { slide ->
                    val eyebrow = layout.eyebrows.getOrNull(items.indexOf(slide)) ?: "Trending now"
                    HeroCopy(slide, eyebrow)
                }
                Spacer(Modifier.height(4.dp))
                val onList = state.listed[item.id] ?: UserStateEdits.apply(item).favorite
                Row(
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                    modifier = Modifier
                        .focusProperties { up = tab }
                        .focusRestorer { play },
                ) {
                    val focus: (Boolean) -> Unit = { if (it) touched++; onFocus(it) }
                    PbButton("Play", Icons.Rounded.PlayArrow, primary = true, onClick = { actions.openDetails(item, play = true) },
                        modifier = Modifier.focusRequester(play), onFocus = focus)
                    PbButton("My List", if (onList) Icons.Rounded.Check else Icons.Rounded.Add, primary = false,
                        onClick = {
                            val next = !onList
                            state.listed[item.id] = next
                            actions.setOnList(item, next) { ok -> if (!ok) state.listed[item.id] = !next }
                        },
                        onFocus = focus)
                    PbButton("More info", Icons.Outlined.Info, primary = false, onClick = { actions.openDetails(item) }, onFocus = focus)
                }
                Spacer(Modifier.height(8.dp))
            }
    }
}

/** Flutter HeroBannerFrame on TV: 58% of the screen, 460–620. */
@Composable
private fun heroHeight(): Dp {
    val h = androidx.compose.ui.platform.LocalConfiguration.current.screenHeightDp
    return (h * 0.58f).coerceIn(460f, 620f).dp
}

@Composable
private fun HeroCopy(item: TitleItem, eyebrow: String) {
    Column {
        BasicText(
            eyebrow.uppercase(),
            style = PbType.label.copy(color = PbColors.primary, letterSpacing = 1.1.sp),
        )
        Spacer(Modifier.height(8.dp))
        BasicText(
            item.displayTitle,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
            style = PbType.hero.copy(lineHeight = 46.sp, letterSpacing = (-1).sp),
        )
        Spacer(Modifier.height(12.dp))
        Box(Modifier.height(28.dp), contentAlignment = Alignment.CenterStart) { MetaRow(item) }
        Spacer(Modifier.height(12.dp))
        BasicText(
            item.synopsis.orEmpty(),
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
            style = PbType.body.copy(color = Color(0xFFD6DAE3), lineHeight = 23.sp),
            modifier = Modifier.height(48.dp),
        )
        Spacer(Modifier.height(12.dp))
    }
}

// ---- Shelves --------------------------------------------------------------

@OptIn(ExperimentalFoundationApi::class, ExperimentalComposeUiApi::class)
@Composable
private fun Shelf(shelf: HomeShelf, actions: HomeActions, onFocus: (Boolean) -> Unit) {
    // "See all" is reached with Up from its own row, so Down goes card to card.
    var rowFocused by remember { mutableStateOf(false) }
    Column(
        Modifier
            .padding(top = 10.dp)
            .onFocusChanged {
                rowFocused = it.hasFocus
                onFocus(it.hasFocus)
            },
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.padding(start = gutter, end = gutter - 12.dp),
        ) {
            BasicText(shelf.title, style = PbType.h2)
            Spacer(Modifier.width(6.dp))
            SeeAll(rowFocused) { actions.openShelf(shelf) }
        }
        val items = shelf.items.take(18)
        val first = remember { FocusRequester() }
        CompositionLocalProvider(LocalBringIntoViewSpec provides RowScroll) {
            LazyRow(
                contentPadding = PaddingValues(horizontal = gutter, vertical = 14.dp),
                horizontalArrangement = Arrangement.spacedBy(if (shelf.style == ShelfStyle.TOP10) gap * 0.6f else gap),
                modifier = Modifier.focusRestorer { first },
            ) {
                itemsIndexed(items, key = { _, it -> it.id }) { i, item ->
                    val mod = if (i == 0) Modifier.focusRequester(first) else Modifier
                    Box(mod) {
                        when (shelf.style) {
                            ShelfStyle.TOP10 -> Top10Tile(i + 1, item, posterWidth, { actions.openDetails(item) })
                            ShelfStyle.WIDE -> WideCard(item, PbSize.wideCardWidthTv, { actions.openDetails(item) })
                            ShelfStyle.POSTER -> PosterCard(item, posterWidth, { actions.openDetails(item) })
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun SeeAll(reachable: Boolean, onClick: () -> Unit) {
    var focused by remember { mutableStateOf(false) }
    val pill = RoundedCornerShape(PbRadius.pill)
    BasicText(
        "See all",
        style = PbType.meta.copy(fontWeight = FontWeight.W600, color = if (focused) PbColors.text else PbColors.textMuted),
        modifier = Modifier
            .focusProperties { canFocus = reachable }
            .pbClick({ focused = it }, onClick)
            .background(if (focused) PbColors.focusSoft else Color.Transparent, pill)
            .border(if (focused) 2.dp else 0.dp, if (focused) PbColors.focus else Color.Transparent, pill)
            .padding(horizontal = 12.dp, vertical = 6.dp),
    )
}
