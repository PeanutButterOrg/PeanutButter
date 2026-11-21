package app.peanutbutter.tv.ui

import androidx.activity.compose.BackHandler
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.tween
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.LocalBringIntoViewSpec
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
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.itemsIndexed
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.tv.material3.Icon
import app.peanutbutter.core.TitleItem
import app.peanutbutter.tv.ui.compose.PbColors
import app.peanutbutter.tv.ui.compose.PbRadius
import app.peanutbutter.tv.ui.compose.PbSize
import app.peanutbutter.tv.ui.compose.PbSpace
import app.peanutbutter.tv.ui.compose.PbType
import app.peanutbutter.tv.ui.compose.PosterCard
import app.peanutbutter.tv.ui.compose.RowScroll
import app.peanutbutter.tv.ui.compose.WideCard
import app.peanutbutter.tv.ui.compose.pbClick
import app.peanutbutter.tv.ui.compose.pbFocusRing
import app.peanutbutter.tv.ui.compose.titleProgress
import kotlinx.coroutines.launch

/** My List or Watched; [LibraryActivity] loads it. */
class LibraryState {
    var title by mutableStateOf("")
    var emptyMessage by mutableStateOf("")
    /** My List: titles you've started, as wide cards above the grid. */
    var keepWatching by mutableStateOf(false)
    /** Newest first, as the server returns them. */
    val items = mutableStateListOf<TitleItem>()
    var loading by mutableStateOf(true)
}

private val gutter = PbSpace.gutterTv
private val gap = 14.dp

/**
 * The desktop's LibraryPage: a big title with counts, All / Movies / Series,
 * Recently added / A–Z, Keep watching (My List), then the grid.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun LibraryScreen(state: LibraryState, onBack: () -> Unit, onOpen: (TitleItem) -> Unit) {
    var kind by remember { mutableStateOf<String?>(null) }
    var az by remember { mutableStateOf(false) }
    val grid = rememberLazyGridState()
    val scope = rememberCoroutineScope()
    val firstTab = remember { FocusRequester() }
    var inHeader by remember { mutableStateOf(true) }

    BackHandler {
        if (inHeader) onBack()
        else scope.launch {
            grid.scrollToItem(0)
            runCatching { firstTab.requestFocus() }
        }
    }
    LaunchedEffect(state.loading) { if (!state.loading) runCatching { firstTab.requestFocus() } }

    val all = state.items
    val movies = all.count { it.kind == "MOVIE" }
    val series = all.size - movies
    var shown = if (kind == null) all.toList() else all.filter { (it.kind == "MOVIE") == (kind == "MOVIE") }
    if (az) shown = shown.sortedBy { it.title.lowercase() }
    val started = if (state.keepWatching) shown.filter { titleProgress(it) > 0.02f && !it.watched } else emptyList()
    val counts = listOf(
        "${all.size} title${if (all.size == 1) "" else "s"}",
        listOfNotNull(
            if (movies > 0) "$movies movie${if (movies == 1) "" else "s"}" else null,
            if (series > 0) "$series series" else null,
        ).joinToString(", "),
    ).filter { it.isNotEmpty() }.joinToString("  ·  ")

    BoxWithConstraints(Modifier.fillMaxSize().background(PbColors.ground)) {
        val width = maxWidth - gutter * 2
        val columns = ((width + gap) / (PbSize.posterWidthTv + gap)).toInt().coerceAtLeast(3)
        val cell = (width - gap * (columns - 1)) / columns
        LazyVerticalGrid(
            columns = GridCells.Fixed(columns),
            state = grid,
            contentPadding = PaddingValues(start = gutter, end = gutter, top = 16.dp, bottom = 32.dp),
            horizontalArrangement = Arrangement.spacedBy(gap),
            verticalArrangement = Arrangement.spacedBy(gap + 4.dp),
            modifier = Modifier.fillMaxSize(),
        ) {
            item(key = "header", span = { GridItemSpan(maxLineSpan) }) {
                Column(Modifier.onFocusChanged { inHeader = it.hasFocus }) {
                    var backFocused by remember { mutableStateOf(false) }
                    Box(
                        contentAlignment = Alignment.Center,
                        modifier = Modifier
                            .padding(start = 0.dp)
                            .pbFocusRing(backFocused, CircleShape, 1.1f)
                            .pbClick({ backFocused = it }, onBack)
                            .size(48.dp)
                            .background(if (backFocused) PbColors.focusSoft else Color.Transparent, CircleShape),
                    ) { Icon(Icons.AutoMirrored.Rounded.ArrowBack, null, tint = PbColors.text, modifier = Modifier.size(28.dp)) }
                    Spacer(Modifier.height(10.dp))
                    BasicText(state.title, style = PbType.hero.copy(fontSize = 48.sp, lineHeight = 50.sp))
                    Spacer(Modifier.height(8.dp))
                    if (!state.loading) BasicText(counts, style = PbType.meta)
                    Spacer(Modifier.height(18.dp))
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Tab("All", kind == null, Modifier.focusRequester(firstTab)) { kind = null }
                        Tab("Movies", kind == "MOVIE") { kind = "MOVIE" }
                        Tab("Series", kind == "SERIES") { kind = "SERIES" }
                        Spacer(Modifier.weight(1f))
                        Tab("Recently added", !az) { az = false }
                        Tab("A–Z", az) { az = true }
                    }
                    if (started.isNotEmpty()) {
                        Spacer(Modifier.height(24.dp))
                        BasicText("Keep watching", style = PbType.h2)
                        CompositionLocalProvider(LocalBringIntoViewSpec provides RowScroll) {
                            LazyRow(
                                contentPadding = PaddingValues(vertical = 14.dp),
                                horizontalArrangement = Arrangement.spacedBy(gap),
                            ) {
                                items(started, key = { it.id }) { item ->
                                    WideCard(item, PbSize.wideCardWidthTv, { onOpen(item) })
                                }
                            }
                        }
                    }
                    Spacer(Modifier.height(8.dp))
                }
            }
            when {
                state.loading -> item(key = "loading", span = { GridItemSpan(maxLineSpan) }) {
                    Box(Modifier.fillMaxWidth().padding(48.dp), contentAlignment = Alignment.Center) { Spinner() }
                }
                all.isEmpty() -> item(key = "empty", span = { GridItemSpan(maxLineSpan) }) {
                    BasicText(
                        state.emptyMessage,
                        style = PbType.body.copy(color = PbColors.textMuted, textAlign = TextAlign.Center),
                        modifier = Modifier.fillMaxWidth().padding(48.dp),
                    )
                }
                else -> itemsIndexed(shown, key = { _, it -> it.id }) { _, item ->
                    PosterCard(item, cell, { onOpen(item) })
                }
            }
        }
    }
}

/** A text tab with the amber underline under the picked one (the desktop's AppFilterChip). */
@Composable
private fun Tab(label: String, selected: Boolean, modifier: Modifier = Modifier, onClick: () -> Unit) {
    var focused by remember { mutableStateOf(false) }
    val pill = RoundedCornerShape(PbRadius.pill)
    val line by animateDpAsState(if (selected) 22.dp else 0.dp, tween(120), label = "tab")
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        modifier = modifier
            .padding(end = 6.dp)
            .pbClick({ focused = it }, onClick)
            .border(PbSize.focusRing, if (focused) PbColors.focus else Color.Transparent, pill)
            .padding(horizontal = 14.dp, vertical = 8.dp),
    ) {
        BasicText(label, style = PbType.button.copy(fontSize = 17.sp, color = if (selected || focused) PbColors.text else PbColors.textMuted))
        Spacer(Modifier.height(5.dp))
        Box(Modifier.width(line).height(2.dp).background(PbColors.primary, RoundedCornerShape(2.dp)))
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
    androidx.compose.foundation.Canvas(Modifier.size(40.dp)) {
        drawArc(
            PbColors.primary, angle, 270f, false,
            style = androidx.compose.ui.graphics.drawscope.Stroke(3.dp.toPx(), cap = androidx.compose.ui.graphics.StrokeCap.Round),
        )
    }
}
