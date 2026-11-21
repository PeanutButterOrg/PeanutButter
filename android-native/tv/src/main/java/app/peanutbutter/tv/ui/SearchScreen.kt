package app.peanutbutter.tv.ui

import androidx.activity.compose.BackHandler
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
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
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.itemsIndexed
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.rounded.History
import androidx.compose.material.icons.rounded.Mic
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material.icons.rounded.SearchOff
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateMapOf
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
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
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
import app.peanutbutter.tv.ui.compose.pbClick
import app.peanutbutter.tv.ui.compose.pbFocusRing
import kotlinx.coroutines.launch

/** What Search shows; [SearchActivity] runs the searches. */
class SearchState {
    var query by mutableStateOf("")
    /** MOVIE or SERIES: only this kind is searched. */
    var kind by mutableStateOf("MOVIE")
    val results = mutableStateListOf<TitleItem>()
    /** The query the results belong to ("" before any search). */
    var searched by mutableStateOf("")
    var loading by mutableStateOf(false)
    var error by mutableStateOf<String?>(null)
    val recent = mutableStateListOf<String>()
    var listening by mutableStateOf(false)
    val listed = mutableStateMapOf<String, Boolean>()
}

interface SearchActions {
    fun back()
    fun setQuery(text: String)
    fun submit()
    fun setKind(kind: String)
    fun mic()
    fun open(item: TitleItem, play: Boolean = false)
    fun setOnList(item: TitleItem, on: Boolean, done: (Boolean) -> Unit)
}

private val gutter = PbSpace.gutterTv
private val gap = 14.dp

/** The desktop's search: the pill field and Movies / Series up top, then results. */
@Composable
fun SearchScreen(state: SearchState, actions: SearchActions) {
    val field = remember { FocusRequester() }
    val grid = rememberLazyGridState()
    val scope = rememberCoroutineScope()
    var inHeader by remember { mutableStateOf(true) }

    BackHandler {
        if (inHeader) actions.back()
        else scope.launch {
            grid.scrollToItem(0)
            runCatching { field.requestFocus() }
        }
    }
    LaunchedEffect(Unit) { runCatching { field.requestFocus() } }

    Column(Modifier.fillMaxSize().background(PbColors.ground)) {
        SearchBar(state, actions, field) { inHeader = it }
        val q = state.searched
        when {
            state.query.trim().length < 2 -> SearchStart(state, actions)
            state.error != null && state.results.isEmpty() -> Message(Icons.Rounded.SearchOff, "Couldn't search", state.error!!)
            state.results.isEmpty() && !state.loading && q.isNotEmpty() ->
                Message(Icons.Rounded.SearchOff, "No matches", "Nothing matches that name. Try another title.")
            state.results.isEmpty() -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { Spinner() }
            else -> Results(state, actions, grid)
        }
    }
}

@Composable
private fun SearchBar(state: SearchState, actions: SearchActions, field: FocusRequester, onFocus: (Boolean) -> Unit) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .onFocusChanged { onFocus(it.hasFocus) }
            .padding(start = gutter - 12.dp, end = gutter, top = 20.dp, bottom = 6.dp),
    ) {
        RoundIcon(Icons.AutoMirrored.Rounded.ArrowBack) { actions.back() }
        Spacer(Modifier.width(8.dp))
        SearchField(state, actions, field, Modifier.weight(1f).widthIn(max = 640.dp))
        Spacer(Modifier.width(8.dp))
        RoundIcon(Icons.Rounded.Mic, tint = if (state.listening) PbColors.bad else PbColors.text) { actions.mic() }
        Spacer(Modifier.width(14.dp))
        KindTab("Movies", state.kind == "MOVIE") { actions.setKind("MOVIE") }
        KindTab("Series", state.kind == "SERIES") { actions.setKind("SERIES") }
    }
}

/**
 * The rounded field. Focus alone doesn't pop the keyboard (moving past it with
 * the remote would): OK opens it, as on the desktop app's TV build.
 */
@Composable
private fun SearchField(state: SearchState, actions: SearchActions, outer: FocusRequester, modifier: Modifier) {
    var editing by remember { mutableStateOf(false) }
    var hadFocus by remember { mutableStateOf(false) }
    var focused by remember { mutableStateOf(false) }
    val input = remember { FocusRequester() }
    val keyboard = LocalSoftwareKeyboardController.current
    val pill = RoundedCornerShape(PbRadius.pill)
    var value by remember { mutableStateOf(TextFieldValue(state.query)) }
    // Voice and recent picks set the query from outside.
    // Typed text comes back as state.query a frame later; only resync on
    // other changes, or keys typed in between are dropped.
    var sent by remember { mutableStateOf(state.query) }
    LaunchedEffect(state.query) {
        if (state.query != sent && state.query != value.text) value = TextFieldValue(state.query, TextRange(state.query.length))
        sent = state.query
    }
    LaunchedEffect(editing) {
        if (editing) {
            runCatching { input.requestFocus() }
            keyboard?.show()
        }
    }
    val border = when {
        editing -> PbColors.primary
        focused -> PbColors.focus
        else -> PbColors.line
    }
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = modifier
            .height(52.dp)
            .focusRequester(outer)
            .pbClick({ focused = it }, { editing = true })
            .background(if (focused || editing) PbColors.surfaceRaised else PbColors.surface, pill)
            .border(if (focused || editing) 2.dp else 1.dp, border, pill)
            .padding(start = 18.dp, end = 8.dp),
    ) {
        Icon(Icons.Rounded.Search, null, tint = PbColors.textMuted, modifier = Modifier.size(24.dp))
        Spacer(Modifier.width(12.dp))
        Box(Modifier.weight(1f), contentAlignment = Alignment.CenterStart) {
            if (editing) {
                BasicTextField(
                    value = value,
                    onValueChange = {
                        value = it
                        sent = it.text
                        actions.setQuery(it.text)
                    },
                    singleLine = true,
                    textStyle = PbType.body.copy(fontSize = 18.sp),
                    cursorBrush = SolidColor(PbColors.primary),
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
                    keyboardActions = KeyboardActions(onSearch = {
                        keyboard?.hide()
                        editing = false
                        actions.submit()
                        runCatching { outer.requestFocus() }
                    }),
                    modifier = Modifier
                        .fillMaxWidth()
                        .focusRequester(input)
                        // Leaving the field ends editing; its first report (before it gets focus) doesn't.
                        .onFocusChanged {
                            if (it.isFocused) hadFocus = true
                            else if (hadFocus && editing) {
                                hadFocus = false
                                editing = false
                            }
                        },
                )
            } else {
                BasicText(
                    when {
                        state.listening -> "Listening…"
                        state.query.isEmpty() -> "Search"
                        else -> state.query
                    },
                    maxLines = 1, overflow = TextOverflow.Ellipsis,
                    style = PbType.body.copy(fontSize = 18.sp, color = if (state.query.isEmpty()) PbColors.textFaint else PbColors.text),
                )
            }
        }
    }
}

@Composable
private fun RoundIcon(icon: ImageVector, tint: Color = PbColors.text, onClick: () -> Unit) {
    var focused by remember { mutableStateOf(false) }
    Box(
        contentAlignment = Alignment.Center,
        modifier = Modifier
            .pbFocusRing(focused, CircleShape, 1.1f)
            .pbClick({ focused = it }, onClick)
            .size(48.dp)
            .background(if (focused) PbColors.focusSoft else Color.Transparent, CircleShape),
    ) { Icon(icon, null, tint = tint, modifier = Modifier.size(28.dp)) }
}

/** Movies / Series: a text tab, the picked one with the amber underline. */
@Composable
private fun KindTab(label: String, selected: Boolean, onClick: () -> Unit) {
    var focused by remember { mutableStateOf(false) }
    val pill = RoundedCornerShape(PbRadius.pill)
    val line by animateDpAsState(if (selected) 22.dp else 0.dp, tween(120), label = "tab")
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        modifier = Modifier
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

/** Before typing: your recent searches, or how to start. */
@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun SearchStart(state: SearchState, actions: SearchActions) {
    if (state.recent.isEmpty()) {
        Message(
            Icons.Rounded.Search,
            if (state.kind == "SERIES") "Search series" else "Search movies",
            "Select the search field to type, or use the mic. Down moves to results.",
        )
        return
    }
    Column(Modifier.fillMaxWidth().padding(start = gutter, end = gutter, top = 24.dp)) {
        BasicText("RECENT SEARCHES", style = PbType.label.copy(color = PbColors.textMuted, letterSpacing = 1.2.sp))
        Spacer(Modifier.height(12.dp))
        FlowRow(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            state.recent.forEach { q ->
                var focused by remember { mutableStateOf(false) }
                val pill = RoundedCornerShape(PbRadius.pill)
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier
                        .pbFocusRing(focused, pill, 1.05f)
                        .pbClick({ focused = it }, { actions.setQuery(q); actions.submit() })
                        .height(40.dp)
                        .background(if (focused) PbColors.focusSoft else PbColors.surfaceRaised, pill)
                        .border(1.dp, PbColors.line, pill)
                        .padding(start = 12.dp, end = 16.dp),
                ) {
                    Icon(Icons.Rounded.History, null, tint = PbColors.textMuted, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(8.dp))
                    BasicText(q, style = PbType.body.copy(fontSize = 15.sp))
                }
            }
        }
    }
}

@Composable
private fun Message(icon: ImageVector, title: String, message: String) {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.widthIn(max = 520.dp)) {
            Icon(icon, null, tint = PbColors.textMuted, modifier = Modifier.size(44.dp))
            Spacer(Modifier.height(14.dp))
            BasicText(title, style = PbType.h2.copy(textAlign = TextAlign.Center))
            Spacer(Modifier.height(8.dp))
            BasicText(message, style = PbType.body.copy(color = PbColors.textMuted, textAlign = TextAlign.Center))
        }
    }
}

/** "Results for “q”", the counts, the top result featured, then Titles. */
@Composable
private fun Results(state: SearchState, actions: SearchActions, grid: androidx.compose.foundation.lazy.grid.LazyGridState) {
    val results = state.results
    val top = results.first()
    val rest = results.drop(1)
    val movies = results.count { it.kind == "MOVIE" }
    val series = results.size - movies
    val counts = listOf(
        "${results.size} result${if (results.size == 1) "" else "s"}",
        listOfNotNull(
            if (movies > 0) "$movies movie${if (movies == 1) "" else "s"}" else null,
            if (series > 0) "$series series" else null,
        ).joinToString(", "),
    ).filter { it.isNotEmpty() }.joinToString("  ·  ")
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val width = maxWidth - gutter * 2
        val columns = ((width + gap) / (PbSize.posterWidthTv + gap)).toInt().coerceAtLeast(3)
        val cell = (width - gap * (columns - 1)) / columns
        LazyVerticalGrid(
            columns = GridCells.Fixed(columns),
            state = grid,
            contentPadding = PaddingValues(start = gutter, end = gutter, top = 12.dp, bottom = 32.dp),
            horizontalArrangement = Arrangement.spacedBy(gap),
            verticalArrangement = Arrangement.spacedBy(gap + 4.dp),
            modifier = Modifier.fillMaxSize(),
        ) {
            item(key = "head", span = { GridItemSpan(maxLineSpan) }) {
                Column {
                    BasicText(
                        buildAnnotatedString {
                            append("Results for ")
                            withStyle(SpanStyle(color = PbColors.primary)) { append("“${state.searched}”") }
                        },
                        maxLines = 2, overflow = TextOverflow.Ellipsis,
                        style = PbType.hero.copy(fontSize = 36.sp, lineHeight = 38.sp),
                    )
                    Spacer(Modifier.height(6.dp))
                    BasicText(counts, style = PbType.meta.copy(fontSize = 15.sp))
                    Spacer(Modifier.height(18.dp))
                    val onList = state.listed[top.id] ?: UserStateEdits.apply(top).favorite
                    FeatureCard(
                        top, "Top result", 300.dp, onList,
                        onPlay = { actions.open(top, play = true) },
                        onToggleList = {
                            val next = !onList
                            state.listed[top.id] = next
                            actions.setOnList(top, next) { ok -> if (!ok) state.listed[top.id] = !next }
                        },
                        onInfo = { actions.open(top) },
                        modifier = Modifier.fillMaxWidth(),
                        synopsis = true,
                    )
                    if (rest.isNotEmpty()) {
                        Spacer(Modifier.height(24.dp))
                        BasicText(
                            buildAnnotatedString {
                                append("Titles")
                                withStyle(SpanStyle(color = PbColors.textMuted, fontSize = 15.sp)) { append("  ${rest.size}") }
                            },
                            style = PbType.h2,
                        )
                    }
                }
            }
            itemsIndexed(rest, key = { _, it -> it.id }) { _, item ->
                PosterCard(item, cell, { actions.open(item) })
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
    androidx.compose.foundation.Canvas(Modifier.size(40.dp)) {
        drawArc(
            PbColors.primary, angle, 270f, false,
            style = androidx.compose.ui.graphics.drawscope.Stroke(3.dp.toPx(), cap = androidx.compose.ui.graphics.StrokeCap.Round),
        )
    }
}
