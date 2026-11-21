package app.peanutbutter.tv.ui

import androidx.activity.compose.BackHandler
import androidx.compose.animation.core.animateFloat
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.itemsIndexed
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.ArrowDropDown
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.tv.material3.Icon
import app.peanutbutter.core.TitleItem
import app.peanutbutter.tv.ui.compose.MetaRow
import app.peanutbutter.tv.ui.compose.PbButton
import app.peanutbutter.tv.ui.compose.PbColors
import app.peanutbutter.tv.ui.compose.PbImage
import app.peanutbutter.tv.ui.compose.PbRadius
import app.peanutbutter.tv.ui.compose.PbSize
import app.peanutbutter.tv.ui.compose.PbSpace
import app.peanutbutter.tv.ui.compose.PbType
import app.peanutbutter.tv.ui.compose.PosterCard
import app.peanutbutter.tv.ui.compose.pbClick
import app.peanutbutter.tv.ui.compose.pbFocusRing
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.launch

/** A filter box in the header: its label, and amber once something's picked. */
class CatalogFilter(val key: String, label: String, active: Boolean = false) {
    var label by mutableStateOf(label)
    var active by mutableStateOf(active)
    var visible by mutableStateOf(true)
}

/** An open filter dropdown: its choices (value to label) and the picked value. */
class FilterMenu(val key: String, val options: List<Pair<String, String>>, val current: String, val onPick: (String) -> Unit)

/** Explore and every See all page; [CatalogActivity] loads it. */
class CatalogState {
    var heading by mutableStateOf("")
    val filters = mutableStateListOf<CatalogFilter>()
    val items = mutableStateListOf<TitleItem>()
    var loading by mutableStateOf(true)
    var loadingMore by mutableStateOf(false)
    var done by mutableStateOf(false)
    var empty by mutableStateOf(false)
    /** Browse lists open with #1 featured and #2–#4 beside it; your own lists don't. */
    var featured by mutableStateOf(true)
    /** "#1 trending" on Explore, "#1 in Popular movies" on See all pages. */
    var eyebrow by mutableStateOf("")
    var menu by mutableStateOf<FilterMenu?>(null)
    val listed = mutableStateMapOf<String, Boolean>()
    /** Bumped after a filter change: back to the top. */
    var reset by mutableIntStateOf(0)
}

interface CatalogActions {
    fun back()
    fun openFilter(key: String)
    fun open(item: TitleItem, play: Boolean = false)
    fun setOnList(item: TitleItem, on: Boolean, done: (Boolean) -> Unit)
    fun loadMore()
}

private val gutter = PbSpace.gutterTv
private val gap = 14.dp

/** The desktop's catalog: name left, filters top right, the #1 featured, then the grid. */
@Composable
fun CatalogScreen(state: CatalogState, actions: CatalogActions) {
    val grid = rememberLazyGridState()
    val scope = rememberCoroutineScope()
    val filterFocus = remember { mutableStateMapOf<String, FocusRequester>() }
    val firstFilter = state.filters.firstOrNull { it.visible }?.key
    var inHeader by remember { mutableStateOf(false) }
    var lastMenuKey by remember { mutableStateOf<String?>(null) }

    BackHandler(enabled = state.menu == null) {
        if (inHeader) actions.back()
        else scope.launch {
            grid.scrollToItem(0)
            firstFilter?.let { runCatching { filterFocus[it]?.requestFocus() } }
        }
    }

    LaunchedEffect(state.reset) { if (state.reset > 0) grid.scrollToItem(0) }

    // Load the next page as the end comes into view.
    LaunchedEffect(grid) {
        snapshotFlow { grid.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: 0 }
            .distinctUntilChanged()
            .collect { last -> if (last >= grid.layoutInfo.totalItemsCount - 12) actions.loadMore() }
    }

    // A menu closed: focus back on its box.
    LaunchedEffect(state.menu) {
        val open = state.menu
        if (open != null) lastMenuKey = open.key
        else lastMenuKey?.let { key -> runCatching { filterFocus[key]?.requestFocus() } }
    }

    Box(Modifier.fillMaxSize().background(PbColors.ground)) {
        Column(Modifier.fillMaxSize()) {
            Header(state, actions, filterFocus) { inHeader = it }
            BoxWithConstraints(Modifier.fillMaxSize()) {
                val width = maxWidth - gutter * 2
                val columns = ((width + gap) / (PbSize.posterWidthTv + gap)).toInt().coerceAtLeast(3)
                val cell = (width - gap * (columns - 1)) / columns
                val items = state.items
                val showFeature = state.featured && items.size >= 4
                when {
                    state.loading && items.isEmpty() -> Spinner(Modifier.align(Alignment.Center))
                    state.empty -> BasicText(
                        androidx.compose.ui.res.stringResource(app.peanutbutter.tv.R.string.empty_catalog),
                        style = PbType.body.copy(color = PbColors.textMuted, textAlign = TextAlign.Center),
                        modifier = Modifier.align(Alignment.Center).padding(horizontal = 96.dp),
                    )
                    else -> LazyVerticalGrid(
                        columns = GridCells.Fixed(columns),
                        state = grid,
                        contentPadding = PaddingValues(start = gutter, end = gutter, top = 10.dp, bottom = 32.dp),
                        horizontalArrangement = Arrangement.spacedBy(gap),
                        verticalArrangement = Arrangement.spacedBy(gap + 4.dp),
                        modifier = Modifier.fillMaxSize(),
                    ) {
                        if (showFeature) {
                            item(key = "feature", span = { GridItemSpan(maxLineSpan) }) {
                                FeatureRow(state, items.take(4), width, actions)
                            }
                        }
                        val grid = if (showFeature) items.drop(4) else items
                        itemsIndexed(grid, key = { _, it -> it.id }) { _, item ->
                            PosterCard(item, cell, { actions.open(item) })
                        }
                        if (state.loadingMore) {
                            item(key = "more", span = { GridItemSpan(maxLineSpan) }) {
                                Box(Modifier.fillMaxWidth().padding(16.dp), contentAlignment = Alignment.Center) { Spinner() }
                            }
                        } else if (state.done) {
                            item(key = "done", span = { GridItemSpan(maxLineSpan) }) {
                                BasicText(
                                    "That's everything in this category.",
                                    style = PbType.meta.copy(textAlign = TextAlign.Center),
                                    modifier = Modifier.fillMaxWidth().padding(top = 8.dp, bottom = 24.dp),
                                )
                            }
                        }
                    }
                }
            }
        }
        state.menu?.let { DropMenu(it) { state.menu = null } }
    }
}

@Composable
private fun Header(
    state: CatalogState,
    actions: CatalogActions,
    focus: MutableMap<String, FocusRequester>,
    onFocus: (Boolean) -> Unit,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .onFocusChanged { onFocus(it.hasFocus) }
            .padding(start = gutter - 12.dp, end = gutter, top = 20.dp, bottom = 10.dp),
    ) {
        var backFocused by remember { mutableStateOf(false) }
        Box(
            contentAlignment = Alignment.Center,
            modifier = Modifier
                .pbFocusRing(backFocused, CircleShape, 1.1f)
                .pbClick({ backFocused = it }, { actions.back() })
                .size(48.dp)
                .background(if (backFocused) PbColors.focusSoft else Color.Transparent, CircleShape),
        ) { Icon(Icons.AutoMirrored.Rounded.ArrowBack, null, tint = PbColors.text, modifier = Modifier.size(28.dp)) }
        Spacer(Modifier.width(8.dp))
        BasicText(
            state.heading, maxLines = 1, overflow = TextOverflow.Ellipsis,
            style = PbType.hero.copy(fontSize = 36.sp),
            modifier = Modifier.weight(1f),
        )
        Spacer(Modifier.width(20.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            state.filters.filter { it.visible }.forEach { f ->
                val requester = focus.getOrPut(f.key) { FocusRequester() }
                FilterBox(f, Modifier.focusRequester(requester)) { actions.openFilter(f.key) }
            }
        }
    }
}

/** Netflix's plain outlined picker box, amber once something's picked. */
@Composable
private fun FilterBox(filter: CatalogFilter, modifier: Modifier, onClick: () -> Unit) {
    var focused by remember { mutableStateOf(false) }
    val shape = RoundedCornerShape(3.dp)
    val fg = if (filter.active) PbColors.primary else PbColors.text
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = modifier
            .pbFocusRing(focused, RoundedCornerShape(5.dp), 1.04f)
            .pbClick({ focused = it }, onClick)
            .height(40.dp)
            .background(if (focused) PbColors.focusSoft else PbColors.ground, shape)
            .border(
                1.dp,
                when {
                    filter.active -> PbColors.primary
                    else -> PbColors.text.copy(alpha = 0.75f)
                },
                shape,
            )
            .padding(start = 14.dp, end = 6.dp),
    ) {
        BasicText(
            filter.label, maxLines = 1, overflow = TextOverflow.Ellipsis,
            style = PbType.body.copy(fontSize = 15.sp, fontWeight = FontWeight.W500, color = fg),
            modifier = Modifier.widthIn(max = 180.dp),
        )
        Spacer(Modifier.width(8.dp))
        Icon(Icons.Rounded.ArrowDropDown, null, tint = fg, modifier = Modifier.size(24.dp))
    }
}

/** The filter's dropdown: a black panel under the boxes, the pick in amber with a tick. */
@Composable
private fun DropMenu(menu: FilterMenu, close: () -> Unit) {
    BackHandler { close() }
    val picked = remember(menu) { FocusRequester() }
    val checked = menu.options.indexOfFirst { it.first == menu.current }.coerceAtLeast(0)
    LaunchedEffect(menu) { runCatching { picked.requestFocus() } }
    Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.35f))) {
        val shape = RoundedCornerShape(3.dp)
        LazyColumn(
            state = androidx.compose.foundation.lazy.rememberLazyListState((checked - 3).coerceAtLeast(0)),
            modifier = Modifier
                .align(Alignment.TopEnd)
                .padding(top = 76.dp, end = gutter)
                .widthIn(min = 220.dp, max = 320.dp)
                .heightIn(max = 300.dp)
                .background(Color(0xF2000000), shape)
                .border(1.dp, PbColors.text.copy(alpha = 0.35f), shape)
                .padding(vertical = 6.dp),
        ) {
            itemsIndexed(menu.options) { i, (value, label) ->
                var focused by remember { mutableStateOf(false) }
                val on = value == menu.current
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier
                        .then(if (i == checked) Modifier.focusRequester(picked) else Modifier)
                        .pbClick({ focused = it }, {
                            close()
                            menu.onPick(value)
                        })
                        .fillMaxWidth()
                        .height(44.dp)
                        .background(if (focused) PbColors.focusSoft else Color.Transparent)
                        .padding(horizontal = 16.dp),
                ) {
                    BasicText(
                        label, maxLines = 1, overflow = TextOverflow.Ellipsis,
                        style = PbType.body.copy(
                            fontSize = 16.sp,
                            color = if (on) PbColors.primary else PbColors.text,
                            fontWeight = if (on) FontWeight.W700 else FontWeight.W500,
                        ),
                        modifier = Modifier.weight(1f),
                    )
                    if (on) Icon(Icons.Rounded.Check, null, tint = PbColors.primary, modifier = Modifier.size(20.dp))
                }
            }
        }
    }
}

/** #1 as a featured card, #2–#4 beside it as posters (the desktop's top row). */
@Composable
private fun FeatureRow(state: CatalogState, top: List<TitleItem>, width: Dp, actions: CatalogActions) {
    val poster = ((width - gap * 3) / 5.6f).coerceIn(150.dp, 320.dp)
    val height = poster * 1.5f
    Row(Modifier.fillMaxWidth().height(height).padding(bottom = 4.dp), horizontalArrangement = Arrangement.spacedBy(gap)) {
        FeatureCard(state, top.first(), state.eyebrow, height, actions, Modifier.weight(1f))
        top.drop(1).forEach { item -> PosterCard(item, poster, { actions.open(item) }) }
    }
}

@Composable
private fun FeatureCard(
    state: CatalogState,
    item: TitleItem,
    eyebrow: String,
    height: Dp,
    actions: CatalogActions,
    modifier: Modifier,
) {
    val shape = RoundedCornerShape(PbRadius.panel + 4.dp)
    BoxWithConstraints(modifier.height(height).clip(shape).background(PbColors.ground)) {
        // The whole 16:9 backdrop on the right; the text side fades into it.
        val artW = minOf(height * 16f / 9f, maxWidth)
        PbImage(
            item.backdropUrl ?: item.posterUrl,
            Modifier.align(Alignment.CenterEnd).width(artW).height(height),
            artW, height,
        )
        Box(
            Modifier
                .align(Alignment.CenterStart)
                .width(maxWidth - artW * 0.55f)
                .height(height)
                .background(Brush.horizontalGradient(0f to PbColors.ground, 0.55f to PbColors.ground, 1f to Color(0x000E0E12))),
        )
        Box(Modifier.fillMaxSize().background(Brush.verticalGradient(0.5f to Color.Transparent, 1f to Color(0xB30E0E12))))
        Column(Modifier.align(Alignment.BottomStart).padding(start = 22.dp, end = 22.dp, bottom = 18.dp)) {
            BasicText(eyebrow.uppercase(), style = PbType.label.copy(color = PbColors.primary, letterSpacing = 1.1.sp))
            Spacer(Modifier.height(4.dp))
            BasicText(item.displayTitle, maxLines = 2, overflow = TextOverflow.Ellipsis,
                style = PbType.h1.copy(fontSize = 26.sp, lineHeight = 28.sp))
            Spacer(Modifier.height(8.dp))
            MetaRow(item, maxGenres = 1)
            Spacer(Modifier.height(12.dp))
            val onList = state.listed[item.id] ?: UserStateEdits.apply(item).favorite
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                PbButton("Play", Icons.Rounded.PlayArrow, primary = true, onClick = { actions.open(item, play = true) })
                PbButton(
                    "My List", if (onList) Icons.Rounded.Check else Icons.Rounded.Add, primary = false,
                    onClick = {
                        val next = !onList
                        state.listed[item.id] = next
                        actions.setOnList(item, next) { ok -> if (!ok) state.listed[item.id] = !next }
                    },
                )
                PbButton("More info", Icons.Outlined.Info, primary = false, onClick = { actions.open(item) })
            }
        }
    }
}

@Composable
private fun Spinner(modifier: Modifier = Modifier) {
    val t = androidx.compose.animation.core.rememberInfiniteTransition(label = "spin")
    val angle by t.animateFloat(
        0f, 360f,
        androidx.compose.animation.core.infiniteRepeatable(
            androidx.compose.animation.core.tween(900, easing = androidx.compose.animation.core.LinearEasing),
        ),
        label = "a",
    )
    androidx.compose.foundation.Canvas(modifier.size(40.dp)) {
        drawArc(
            PbColors.primary, angle, 270f, false,
            style = androidx.compose.ui.graphics.drawscope.Stroke(3.dp.toPx(), cap = androidx.compose.ui.graphics.StrokeCap.Round),
        )
    }
}
