package app.peanutbutter.tv.player

import android.view.KeyEvent
import android.widget.ImageView
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
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
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.AspectRatio
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.ClosedCaption
import androidx.compose.material.icons.rounded.ClosedCaptionDisabled
import androidx.compose.material.icons.rounded.Forward10
import androidx.compose.material.icons.rounded.Language
import androidx.compose.material.icons.rounded.Pause
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.Remove
import androidx.compose.material.icons.rounded.Replay
import androidx.compose.material.icons.rounded.Replay10
import androidx.compose.material.icons.rounded.SkipNext
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shadow
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.clipRect
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.tv.material3.Icon as MaterialIcon
import androidx.compose.foundation.text.BasicText
import app.peanutbutter.tv.PbGlide
import app.peanutbutter.tv.ui.compose.PbColors
import app.peanutbutter.tv.ui.compose.PbRadius
import app.peanutbutter.tv.ui.compose.PbType

/** Every control over the video, in the desktop player's order. */
enum class Ctl { BACK, AUDIO, SUBS, ASPECT, SEEK, REW, PLAY, FF, SKIP, NEXT }

/** A row in a player menu panel (the desktop's showMenu panel). */
sealed interface MenuRow {
    data class Section(val label: String) : MenuRow

    data class Option(
        val label: String,
        val checked: Boolean = false,
        val enabled: Boolean = true,
        /** A second, quieter line under the label. */
        val detail: String? = null,
        /** Picture menu: draws how this mode places the picture. */
        val picture: PictureGlyph? = null,
        val onPick: () -> Unit,
    ) : MenuRow

    /** Size / Background: one pill with a segment per choice. Stays open on pick. */
    class Segments(
        val label: String,
        val choices: List<String>,
        val choiceSizes: List<TextUnit>? = null,
        selected: Int,
        val onPick: (Int) -> Unit,
    ) : MenuRow {
        var selected by mutableIntStateOf(selected)
    }

    /** Delay: − value + in one pill. Stays open on press. */
    class Stepper(
        val label: String,
        value: String,
        val onStep: (Int) -> String,
    ) : MenuRow {
        var value by mutableStateOf(value)
    }
}

class PlayerMenu(val title: String, val rows: List<MenuRow>)

/** How a Picture mode places a 2.39:1 film on a 16:9 screen, for its menu row. */
enum class PictureGlyph { FIT, ORIGINAL, FILL, STRETCH, WIDE, CLASSIC }

class ResumeCard(val title: String, val atMs: Long, val totalMs: Long)

/**
 * The player's on-screen state. [PlayerActivity] sets it; [PlayerOverlay] draws
 * it. Focus is ours too (which control is lit), so the remote behaves the same
 * as before: the activity routes every key.
 */
class PlayerUi {
    var title by mutableStateOf("")
    var episode by mutableStateOf<String?>(null)
    var art by mutableStateOf<String?>(null)

    /** Before the first frame: the poster, the status line and the buffer bar. */
    var preparing by mutableStateOf(true)
    var status by mutableStateOf("")
    /** 0–100, or null while it can't tell (indeterminate bar). */
    var bufferPct by mutableStateOf<Int?>(null)
    var spinner by mutableStateOf(false)

    var chrome by mutableStateOf(false)
    var audioChoice by mutableStateOf(false)
    var subsOn by mutableStateOf(false)
    var showPlayIcon by mutableStateOf(false)
    var canSeek by mutableStateOf(true)
    var posMs by mutableLongStateOf(0L)
    var durMs by mutableLongStateOf(0L)
    var bufMs by mutableLongStateOf(0L)

    var stats by mutableStateOf<String?>(null)
    var skipLabel by mutableStateOf<String?>(null)
    var nextTitle by mutableStateOf<String?>(null)
    var nextLabel by mutableStateOf<String?>(null)
    var nextShown by mutableStateOf(false)
    var nextLoading by mutableStateOf<String?>(null)
    var hud by mutableStateOf<String?>(null)

    var focused by mutableStateOf<Ctl?>(null)
    var pressed by mutableStateOf<Ctl?>(null)

    var menu by mutableStateOf<PlayerMenu?>(null)
    private set
    var menuRow by mutableIntStateOf(0)
    var menuCol by mutableIntStateOf(0)

    var resume by mutableStateOf<ResumeCard?>(null)
    var resumeIndex by mutableIntStateOf(0)
    var onResume: (fromStart: Boolean) -> Unit = {}
    var onResumeCancel: () -> Unit = {}

    var leaving by mutableStateOf(false)
    var leaveIndex by mutableIntStateOf(0)
    var onLeave: () -> Unit = {}
    var leaveTitle = ""
    var leaveMessage = ""
    var leaveStay = ""
    var leaveGo = ""

    val overlayOpen: Boolean get() = menu != null || resume != null || leaving

    fun openMenu(m: PlayerMenu) {
        menu = m
        menuCol = 0
        val checked = m.rows.indexOfFirst { it is MenuRow.Option && it.checked && it.enabled }
        menuRow = if (checked >= 0) checked else m.rows.indexOfFirst { it.focusable() }.coerceAtLeast(0)
        (m.rows.getOrNull(menuRow) as? MenuRow.Segments)?.let { menuCol = it.selected }
    }

    fun closeMenu() {
        menu = null
    }

    fun askResume(card: ResumeCard) {
        resumeIndex = 0
        resume = card
    }

    fun askLeave() {
        leaveIndex = 0
        leaving = true
    }

    /** Back on an open card or menu. True when it was one of ours. */
    fun back(): Boolean {
        when {
            menu != null -> menu = null
            leaving -> leaving = false
            resume != null -> {
                resume = null
                onResumeCancel()
            }
            else -> return false
        }
        return true
    }

    /** D-pad and OK inside an open menu or card. Everything is eaten while one is up. */
    fun overlayKey(code: Int): Boolean {
        val ok = code == KeyEvent.KEYCODE_DPAD_CENTER || code == KeyEvent.KEYCODE_ENTER ||
            code == KeyEvent.KEYCODE_NUMPAD_ENTER
        menu?.let { m ->
            val row = m.rows.getOrNull(menuRow)
            when (code) {
                KeyEvent.KEYCODE_DPAD_UP, KeyEvent.KEYCODE_DPAD_DOWN -> {
                    val step = if (code == KeyEvent.KEYCODE_DPAD_UP) -1 else 1
                    var i = menuRow + step
                    while (i in m.rows.indices && !m.rows[i].focusable()) i += step
                    if (i in m.rows.indices) {
                        menuRow = i
                        menuCol = (m.rows[i] as? MenuRow.Segments)?.selected ?: 0
                    }
                }
                KeyEvent.KEYCODE_DPAD_LEFT, KeyEvent.KEYCODE_DPAD_RIGHT -> {
                    val step = if (code == KeyEvent.KEYCODE_DPAD_LEFT) -1 else 1
                    val cols = when (row) {
                        is MenuRow.Segments -> row.choices.size
                        is MenuRow.Stepper -> 2
                        else -> 1
                    }
                    menuCol = (menuCol + step).coerceIn(0, cols - 1)
                }
                else -> if (ok) when (row) {
                    is MenuRow.Option -> {
                        menu = null
                        row.onPick()
                    }
                    is MenuRow.Segments -> {
                        row.selected = menuCol
                        row.onPick(menuCol)
                    }
                    is MenuRow.Stepper -> row.value = row.onStep(if (menuCol == 0) -1 else 1)
                    else -> Unit
                }
            }
            return true
        }
        resume?.let {
            when (code) {
                KeyEvent.KEYCODE_DPAD_LEFT -> resumeIndex = 0
                KeyEvent.KEYCODE_DPAD_RIGHT -> resumeIndex = 1
                else -> if (ok) {
                    resume = null
                    onResume(resumeIndex == 1)
                }
            }
            return true
        }
        if (leaving) {
            when (code) {
                KeyEvent.KEYCODE_DPAD_LEFT -> leaveIndex = 0
                KeyEvent.KEYCODE_DPAD_RIGHT -> leaveIndex = 1
                else -> if (ok) {
                    leaving = false
                    if (leaveIndex == 1) onLeave()
                }
            }
            return true
        }
        return false
    }

    private fun MenuRow.focusable() = when (this) {
        is MenuRow.Option -> enabled
        is MenuRow.Segments, is MenuRow.Stepper -> true
        is MenuRow.Section -> false
    }
}

private val shadowText = Shadow(color = Color.Black.copy(alpha = 0.87f), blurRadius = 8f)

private fun clock(ms: Long): String {
    val total = (ms / 1000).coerceAtLeast(0)
    val h = total / 3600
    val m = (total % 3600) / 60
    val s = total % 60
    return if (h > 0) String.format(java.util.Locale.US, "%d:%02d:%02d", h, m, s)
    else String.format(java.util.Locale.US, "%d:%02d", m, s)
}

@Composable
fun PlayerOverlay(ui: PlayerUi) {
    Box(Modifier.fillMaxSize()) {
        if (ui.preparing) BufferOverlay(ui)

        // Top row: Back, title, then Audio / Subtitles / Picture.
        AnimatedVisibility(
            visible = ui.chrome || ui.preparing,
            enter = fadeIn(tween(180)) + slideInVertically(tween(180)) { -it / 3 },
            exit = fadeOut(tween(220)) + slideOutVertically(tween(220)) { -it / 3 },
            modifier = Modifier.align(Alignment.TopStart).fillMaxWidth(),
        ) {
            Box(
                Modifier
                    .fillMaxWidth()
                    .padding(start = 36.dp, end = 40.dp, top = 24.dp),
            ) {
                TopRow(ui)
            }
        }

        // Bottom: the seek bar, then −10 / Play / +10.
        AnimatedVisibility(
            visible = ui.chrome && !ui.preparing,
            enter = fadeIn(tween(180)) + slideInVertically(tween(180)) { it / 2 },
            exit = fadeOut(tween(220)) + slideOutVertically(tween(220)) { it / 2 },
            modifier = Modifier.align(Alignment.BottomCenter).fillMaxWidth(),
        ) {
            Box(
                Modifier
                    .fillMaxWidth()
                    .padding(start = 36.dp, end = 36.dp, bottom = 28.dp),
            ) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    SeekBar(ui)
                    Spacer(Modifier.height(14.dp))
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        RoundButton(ui, Ctl.REW, Icons.Rounded.Replay10, 52.dp, enabled = ui.canSeek)
                        Spacer(Modifier.width(18.dp))
                        RoundButton(
                            ui, Ctl.PLAY,
                            if (ui.showPlayIcon) Icons.Rounded.PlayArrow else Icons.Rounded.Pause,
                            60.dp,
                        )
                        Spacer(Modifier.width(18.dp))
                        RoundButton(ui, Ctl.FF, Icons.Rounded.Forward10, 52.dp, enabled = ui.canSeek)
                    }
                }
            }
        }

        val chipBottom = if (ui.chrome && !ui.preparing) 176.dp else 72.dp
        val chipBottomAnimated by androidx.compose.animation.core.animateDpAsState(chipBottom, tween(180), label = "chip")

        // Skip Intro / Play Next: bottom-left, above the controls when they're up.
        Box(Modifier.align(Alignment.BottomStart).padding(start = 36.dp, bottom = chipBottomAnimated)) {
            val skip = ui.skipLabel
            val next = ui.nextLabel
            AnimatedVisibility(skip != null, enter = fadeIn(tween(180)) + scaleIn(tween(180), 0.92f), exit = fadeOut(tween(120))) {
                ActionChip(ui, Ctl.SKIP) {
                    BasicText(skip.orEmpty(), style = chipText.copy(fontWeight = FontWeight.W600))
                    Spacer(Modifier.width(6.dp))
                    Icon(Icons.Rounded.SkipNext, 20.dp)
                }
            }
            AnimatedVisibility(skip == null && ui.nextShown, enter = fadeIn(tween(180)) + scaleIn(tween(180), 0.92f), exit = fadeOut(tween(120))) {
                ActionChip(ui, Ctl.NEXT) {
                    Icon(Icons.Rounded.SkipNext, 22.dp)
                    Spacer(Modifier.width(8.dp))
                    Column(Modifier.widthIn(max = 300.dp)) {
                        BasicText(ui.nextTitle.orEmpty(), style = chipText.copy(fontWeight = FontWeight.W700))
                        if (!next.isNullOrBlank()) {
                            Spacer(Modifier.height(2.dp))
                            BasicText(
                                next,
                                maxLines = 2,
                                overflow = TextOverflow.Ellipsis,
                                style = chipText.copy(fontSize = 13.sp, color = Color.White.copy(alpha = 0.75f)),
                            )
                        }
                    }
                }
            }
        }

        // Stream stats: bottom-right, never over the seek bar.
        val stats = ui.stats
        AnimatedVisibility(
            visible = ui.chrome && !ui.preparing && !stats.isNullOrBlank(),
            enter = fadeIn(tween(180)),
            exit = fadeOut(tween(220)),
            modifier = Modifier.align(Alignment.BottomEnd).padding(end = 36.dp, bottom = chipBottomAnimated),
        ) {
            BasicText(
                stats.orEmpty(),
                style = chipText.copy(fontSize = 13.sp, fontWeight = FontWeight.W600),
                modifier = Modifier
                    .background(Color.Black.copy(alpha = 0.68f), RoundedCornerShape(20.dp))
                    .padding(horizontal = 14.dp, vertical = 7.dp),
            )
        }

        // Short notices ("Skip Intro", seeking) under the top row.
        ui.hud?.let { text ->
            BasicText(
                text,
                style = chipText.copy(fontSize = 14.sp, fontWeight = FontWeight.W600),
                modifier = Modifier
                    .align(Alignment.TopCenter)
                    .padding(top = 88.dp)
                    .background(Color.Black.copy(alpha = 0.72f), RoundedCornerShape(20.dp))
                    .padding(horizontal = 16.dp, vertical = 8.dp),
            )
        }

        if (ui.spinner && !ui.preparing) {
            Spinner(Modifier.align(Alignment.Center).size(48.dp))
        }

        ui.nextLoading?.let { NextLoading(it) }
        ui.menu?.let { MenuPanel(ui, it) }
        ui.resume?.let { ResumeCardView(ui, it) }
        if (ui.leaving) LeaveCard(ui)
    }
}

private val chipText = TextStyle(
    fontFamily = PbType.body.fontFamily,
    color = Color.White,
    fontSize = 14.sp,
)

@Composable
private fun Icon(icon: ImageVector, size: Dp, tint: Color = Color.White) {
    MaterialIcon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(size))
}

@Composable
private fun TopRow(ui: PlayerUi) {
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
        RoundButton(ui, Ctl.BACK, Icons.AutoMirrored.Rounded.ArrowBack, 44.dp)
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f).padding(end = 16.dp)) {
            BasicText(
                ui.title,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                style = PbType.title.copy(color = Color.White, fontSize = 20.sp, shadow = shadowText),
            )
            ui.episode?.let {
                BasicText(
                    it,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    style = PbType.meta.copy(color = Color.White.copy(alpha = 0.85f), fontSize = 14.sp, shadow = shadowText),
                )
            }
        }
        if (!ui.preparing) {
            if (ui.audioChoice) {
                RoundButton(ui, Ctl.AUDIO, Icons.Rounded.Language, 44.dp)
                Spacer(Modifier.width(10.dp))
            }
            RoundButton(
                ui, Ctl.SUBS,
                if (ui.subsOn) Icons.Rounded.ClosedCaption else Icons.Rounded.ClosedCaptionDisabled,
                44.dp,
                selected = ui.subsOn,
            )
            Spacer(Modifier.width(10.dp))
            RoundButton(ui, Ctl.ASPECT, Icons.Rounded.AspectRatio, 44.dp)
        }
    }
}

/** The desktop's _RoundButton: dark disc, white ring on focus, amber when on. */
@Composable
private fun RoundButton(
    ui: PlayerUi,
    ctl: Ctl,
    icon: ImageVector,
    size: Dp,
    enabled: Boolean = true,
    selected: Boolean = false,
) {
    val focused = ui.focused == ctl && !ui.overlayOpen
    val scale by animateFloatAsState(
        when {
            ui.pressed == ctl -> 0.94f
            focused -> 1.08f
            else -> 1f
        },
        tween(110),
        label = "btn",
    )
    Box(
        contentAlignment = Alignment.Center,
        modifier = Modifier
            .scale(scale)
            .alpha(if (enabled) 1f else 0.45f)
            .size(size)
            .background(Color.Black.copy(alpha = if (focused) 0.9f else 0.62f), CircleShape)
            .then(
                when {
                    focused -> Modifier.border(2.5.dp, Color.White, CircleShape)
                    selected -> Modifier.border(2.dp, PbColors.primary, CircleShape)
                    else -> Modifier
                },
            ),
    ) {
        Icon(icon, size * 0.54f)
    }
}

/** Skip Intro / Play Next pill: white border and a slight grow on focus. */
@Composable
private fun ActionChip(ui: PlayerUi, ctl: Ctl, content: @Composable () -> Unit) {
    val focused = ui.focused == ctl && !ui.overlayOpen
    val scale by animateFloatAsState(
        when {
            ui.pressed == ctl -> 0.94f
            focused -> 1.06f
            else -> 1f
        },
        tween(110),
        label = "chip",
    )
    val shape = RoundedCornerShape(22.dp)
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .scale(scale)
            .background(Color.Black.copy(alpha = if (focused) 0.88f else 0.72f), shape)
            .border(if (focused) 2.dp else 1.dp, if (focused) Color.White else Color.White.copy(alpha = 0.24f), shape)
            .padding(horizontal = 16.dp, vertical = 10.dp),
    ) { content() }
}

/** Rounded dark bar: elapsed · amber played · lighter buffered · total. */
@Composable
private fun SeekBar(ui: PlayerUi) {
    val focused = ui.focused == Ctl.SEEK && !ui.overlayOpen
    val dur = ui.durMs
    val played = if (dur > 0) (ui.posMs.toFloat() / dur).coerceIn(0f, 1f) else 0f
    val buffered = if (dur > 0) (ui.bufMs.toFloat() / dur).coerceIn(played, 1f) else 0f
    val timeStyle = PbType.meta.copy(color = Color.White.copy(alpha = 0.7f), fontSize = 14.sp)
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .background(Color.Black.copy(alpha = 0.55f), RoundedCornerShape(10.dp))
            .then(if (focused) Modifier.border(2.dp, Color.White.copy(alpha = 0.9f), RoundedCornerShape(10.dp)) else Modifier)
            .padding(horizontal = 16.dp, vertical = 10.dp),
    ) {
        BasicText(clock(ui.posMs), style = timeStyle)
        Canvas(
            Modifier
                .weight(1f)
                .height(22.dp)
                .padding(horizontal = 14.dp),
        ) {
            val h = if (focused) 5.dp.toPx() else 3.dp.toPx()
            val y = size.height / 2
            val r = CornerRadius(h / 2, h / 2)
            drawRoundRect(Color.White.copy(alpha = 0.24f), Offset(0f, y - h / 2), Size(size.width, h), r)
            drawRoundRect(Color.White.copy(alpha = 0.7f), Offset(0f, y - h / 2), Size(size.width * buffered, h), r)
            drawRoundRect(PbColors.primary, Offset(0f, y - h / 2), Size(size.width * played, h), r)
            val thumb = if (focused) 9.dp.toPx() else 7.dp.toPx()
            drawCircle(Color.White, thumb, Offset(size.width * played, y))
        }
        BasicText(if (dur > 0) clock(dur) else "--:--", style = timeStyle)
    }
}

/** Before the first frame: poster under a dark drop, status and buffer bar. */
@Composable
private fun BufferOverlay(ui: PlayerUi) {
    Box(Modifier.fillMaxSize().background(Color(0xFF0A0A0E))) {
        val art = ui.art
        if (!art.isNullOrBlank()) {
            AndroidView(
                factory = { ctx -> ImageView(ctx).also { PbGlide.playerBackdrop(it, art) } },
                modifier = Modifier.fillMaxSize(),
            )
        }
        Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.7f)))
        Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.align(Alignment.Center)) {
            BasicText(
                ui.status,
                style = PbType.body.copy(color = Color.White, fontSize = 17.sp, fontWeight = FontWeight.W600, shadow = shadowText, textAlign = TextAlign.Center),
            )
            Spacer(Modifier.height(16.dp))
            LinearBar(ui.bufferPct?.let { it / 100f }, Modifier.width(280.dp).height(4.dp))
        }
    }
}

@Composable
private fun LinearBar(value: Float?, modifier: Modifier, track: Color = Color.White.copy(alpha = 0.24f)) {
    val transition = androidx.compose.animation.core.rememberInfiniteTransition(label = "bar")
    val sweep by transition.animateFloat(
        0f, 1f,
        androidx.compose.animation.core.infiniteRepeatable(tween(1200)),
        label = "sweep",
    )
    Canvas(modifier.clip(RoundedCornerShape(2.dp))) {
        drawRect(track)
        if (value != null) {
            drawRect(PbColors.primary, size = Size(size.width * value.coerceIn(0f, 1f), size.height))
        } else {
            val w = size.width * 0.3f
            drawRect(PbColors.primary, Offset(-w + (size.width + w) * sweep, 0f), Size(w, size.height))
        }
    }
}

@Composable
private fun Spinner(modifier: Modifier) {
    val transition = androidx.compose.animation.core.rememberInfiniteTransition(label = "spin")
    val angle by transition.animateFloat(
        0f, 360f,
        androidx.compose.animation.core.infiniteRepeatable(tween(900, easing = androidx.compose.animation.core.LinearEasing)),
        label = "angle",
    )
    Canvas(modifier) {
        drawArc(
            Color.White, angle, 270f, false,
            style = Stroke(width = 3.dp.toPx(), cap = StrokeCap.Round),
        )
    }
}

@Composable
private fun NextLoading(label: String) {
    Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.85f)), contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Spinner(Modifier.size(48.dp))
            Spacer(Modifier.height(20.dp))
            BasicText(
                androidx.compose.ui.res.stringResource(app.peanutbutter.tv.R.string.next_episode_loading),
                style = PbType.title.copy(color = Color.White, fontSize = 20.sp, fontWeight = FontWeight.W700),
            )
            Spacer(Modifier.height(6.dp))
            BasicText(
                label,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
                style = PbType.body.copy(color = Color.White.copy(alpha = 0.75f), fontSize = 15.sp, textAlign = TextAlign.Center),
            )
        }
    }
}

private val panelShape = RoundedCornerShape(PbRadius.panel)

/** The desktop's menu panel, under the top-right buttons. */
@Composable
private fun BoxScope.MenuPanel(ui: PlayerUi, menu: PlayerMenu) {
    val maxH = (LocalConfiguration.current.screenHeightDp * 0.72f).dp
    val list = rememberLazyListState()
    LaunchedEffect(ui.menuRow, menu) {
        val visible = list.layoutInfo.visibleItemsInfo
        val first = visible.firstOrNull()?.index ?: 0
        val last = visible.lastOrNull()?.index ?: 0
        // +1: the title is item 0.
        val item = ui.menuRow + 1
        if (item <= first || item >= last) list.animateScrollToItem((item - 3).coerceAtLeast(0))
    }
    Column(
        Modifier
            .align(Alignment.TopEnd)
            .padding(top = 80.dp, end = 40.dp)
            .widthIn(min = 320.dp, max = 400.dp)
            .heightIn(max = maxH)
            .shadow(16.dp, panelShape)
            .background(PbColors.surface, panelShape)
            .border(1.dp, PbColors.line, panelShape)
            .padding(start = 6.dp, end = 6.dp, top = 8.dp, bottom = 10.dp),
    ) {
        LazyColumn(state = list) {
            item {
                BasicText(
                    menu.title,
                    style = PbType.h2.copy(fontSize = 19.sp),
                    modifier = Modifier.padding(horizontal = 14.dp, vertical = 10.dp),
                )
            }
            itemsIndexed(menu.rows) { i, row ->
                val active = i == ui.menuRow
                when (row) {
                    is MenuRow.Section -> BasicText(
                        row.label.uppercase(),
                        style = PbType.label.copy(fontSize = 12.sp, letterSpacing = 1.3.sp),
                        modifier = Modifier.padding(start = 14.dp, end = 14.dp, top = 12.dp, bottom = 6.dp),
                    )
                    is MenuRow.Option -> MenuOptionRow(row, active)
                    is MenuRow.Segments -> StyleBox(first = !menu.rows.isStyle(i - 1), last = !menu.rows.isStyle(i + 1)) {
                        StyleLabel(row.label)
                        Segments(row, if (active) ui.menuCol else -1)
                    }
                    is MenuRow.Stepper -> StyleBox(first = !menu.rows.isStyle(i - 1), last = !menu.rows.isStyle(i + 1)) {
                        StyleLabel(row.label)
                        Stepper(row, if (active) ui.menuCol else -1)
                    }
                }
            }
        }
    }
}

@Composable
private fun MenuOptionRow(row: MenuRow.Option, active: Boolean) {
    val shape = RoundedCornerShape(PbRadius.card)
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .height(if (row.detail == null) 46.dp else 62.dp)
            .background(if (active) PbColors.focusSoft else Color.Transparent, shape)
            .then(if (active) Modifier.border(2.dp, PbColors.focus, shape) else Modifier)
            .padding(horizontal = 12.dp),
    ) {
        Box(Modifier.width(30.dp)) {
            if (row.checked) Icon(Icons.Rounded.Check, 20.dp, PbColors.primary)
        }
        row.picture?.let {
            PictureGlyphView(it, row.checked)
            Spacer(Modifier.width(14.dp))
        }
        Column {
            BasicText(
                row.label,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                style = PbType.body.copy(
                    fontSize = 16.sp,
                    color = when {
                        !row.enabled -> PbColors.textFaint
                        row.checked -> PbColors.primary
                        else -> PbColors.text
                    },
                    fontWeight = if (row.checked) FontWeight.W700 else FontWeight.W500,
                ),
            )
            row.detail?.let {
                BasicText(
                    it,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    style = PbType.meta.copy(fontSize = 13.sp, color = PbColors.textMuted),
                )
            }
        }
    }
}

/** A small screen with the picture drawn the way [mode] places it. */
@Composable
private fun PictureGlyphView(mode: PictureGlyph, selected: Boolean) {
    val film = (if (selected) PbColors.primary else PbColors.textMuted).copy(alpha = 0.9f)
    val edge = if (selected) PbColors.primary else PbColors.line
    Canvas(Modifier.size(48.dp, 27.dp)) {
        val w = size.width
        val h = size.height
        val radius = CornerRadius(3.dp.toPx())
        fun centered(pw: Float, ph: Float) = Offset((w - pw) / 2f, (h - ph) / 2f) to Size(pw, ph)
        val (at, sz) = when (mode) {
            PictureGlyph.FIT -> centered(w, w / 2.39f)
            PictureGlyph.ORIGINAL -> centered(w * 0.62f, w * 0.62f / 2.39f)
            PictureGlyph.FILL -> centered(h * 2.39f, h)
            PictureGlyph.STRETCH, PictureGlyph.WIDE -> Offset.Zero to size
            PictureGlyph.CLASSIC -> centered(h * 4f / 3f, h)
        }
        drawRoundRect(Color.Black, cornerRadius = radius)
        // Fill: the trimmed edges, faint outside the screen.
        if (mode == PictureGlyph.FILL) drawRect(film.copy(alpha = 0.25f), at, sz)
        clipRect(0f, 0f, w, h) { drawRect(film, at, sz) }
        if (mode == PictureGlyph.STRETCH) {
            val c = w / 2f
            val ink = Color.Black.copy(alpha = 0.7f)
            val sw = 1.8.dp.toPx()
            val inset = 4.dp.toPx()
            val tip = 3.dp.toPx()
            drawLine(ink, Offset(c, inset), Offset(c, h - inset), sw, StrokeCap.Round)
            for ((y, dir) in listOf(inset to 1f, h - inset to -1f)) {
                drawLine(ink, Offset(c - tip, y + tip * dir), Offset(c, y), sw, StrokeCap.Round)
                drawLine(ink, Offset(c + tip, y + tip * dir), Offset(c, y), sw, StrokeCap.Round)
            }
        }
        drawRoundRect(edge, cornerRadius = radius, style = Stroke(1.3.dp.toPx()))
    }
}

private fun List<MenuRow>.isStyle(i: Int) = getOrNull(i).let { it is MenuRow.Segments || it is MenuRow.Stepper }

/** The desktop's raised box around Size, Background and Delay. */
@Composable
private fun StyleBox(first: Boolean, last: Boolean, content: @Composable () -> Unit) {
    val r = 12.dp
    Column(
        Modifier
            .fillMaxWidth()
            .padding(start = 4.dp, end = 4.dp, bottom = if (last) 6.dp else 0.dp)
            .background(
                PbColors.surfaceRaised,
                RoundedCornerShape(
                    topStart = if (first) r else 0.dp, topEnd = if (first) r else 0.dp,
                    bottomStart = if (last) r else 0.dp, bottomEnd = if (last) r else 0.dp,
                ),
            )
            .padding(start = 12.dp, end = 12.dp, top = if (first) 12.dp else 6.dp, bottom = if (last) 14.dp else 8.dp),
    ) { content() }
}

@Composable
private fun StyleLabel(text: String) {
    BasicText(
        text.uppercase(),
        style = PbType.label.copy(fontSize = 12.sp, letterSpacing = 1.3.sp),
        modifier = Modifier.padding(bottom = 8.dp),
    )
}

@Composable
private fun Segments(row: MenuRow.Segments, cursor: Int) {
    val pill = RoundedCornerShape(PbRadius.pill)
    Row(
        Modifier
            .fillMaxWidth()
            .height(42.dp)
            .background(PbColors.ground, pill)
            .border(1.dp, PbColors.line, pill)
            .padding(3.dp),
    ) {
        row.choices.forEachIndexed { i, choice ->
            val on = i == row.selected
            val lit = i == cursor
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier
                    .weight(1f)
                    .fillMaxSize()
                    .background(if (on) PbColors.primary else Color.Transparent, pill)
                    .then(if (lit) Modifier.border(2.dp, PbColors.focus, pill) else Modifier),
            ) {
                BasicText(
                    choice,
                    style = PbType.button.copy(
                        fontSize = row.choiceSizes?.getOrNull(i) ?: 14.sp,
                        color = if (on) PbColors.onPrimary else PbColors.text,
                    ),
                )
            }
        }
    }
}

@Composable
private fun Stepper(row: MenuRow.Stepper, cursor: Int) {
    val pill = RoundedCornerShape(PbRadius.pill)
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .height(42.dp)
            .background(PbColors.ground, pill)
            .border(1.dp, PbColors.line, pill)
            .padding(3.dp),
    ) {
        StepButton(Icons.Rounded.Remove, cursor == 0)
        BasicText(
            row.value,
            style = PbType.button.copy(fontSize = 14.sp, textAlign = TextAlign.Center),
            modifier = Modifier.weight(1f),
        )
        StepButton(Icons.Rounded.Add, cursor == 1)
    }
}

@Composable
private fun StepButton(icon: ImageVector, lit: Boolean) {
    Box(
        contentAlignment = Alignment.Center,
        modifier = Modifier
            .size(36.dp)
            .background(if (lit) PbColors.focusSoft else Color.Transparent, CircleShape)
            .then(if (lit) Modifier.border(2.dp, PbColors.focus, CircleShape) else Modifier),
    ) { Icon(icon, 20.dp, PbColors.text) }
}

/** A centred card over a light scrim: the resume and leave questions. */
@Composable
private fun CenterCard(content: @Composable () -> Unit) {
    Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.45f)), contentAlignment = Alignment.Center) {
        Column(
            Modifier
                .width(560.dp)
                .shadow(40.dp, panelShape)
                .background(PbColors.surface, panelShape)
                .border(1.dp, PbColors.line, panelShape)
                .padding(start = 26.dp, end = 26.dp, top = 24.dp, bottom = 26.dp),
        ) { content() }
    }
}

@Composable
private fun PillButton(
    text: String,
    icon: ImageVector?,
    primary: Boolean,
    lit: Boolean,
    modifier: Modifier = Modifier,
) {
    val pill = RoundedCornerShape(PbRadius.pill)
    val scale by animateFloatAsState(if (lit) 1.04f else 1f, tween(110), label = "pill")
    Row(
        horizontalArrangement = Arrangement.Center,
        verticalAlignment = Alignment.CenterVertically,
        modifier = modifier
            .scale(scale)
            .height(50.dp)
            .background(if (primary) PbColors.primary else if (lit) PbColors.focusSoft else Color.Transparent, pill)
            .border(
                if (lit) 3.dp else 1.dp,
                if (lit) PbColors.focus else if (primary) Color.Transparent else PbColors.line,
                pill,
            )
            .padding(horizontal = 18.dp),
    ) {
        val color = if (primary) PbColors.onPrimary else PbColors.text
        if (icon != null) {
            Icon(icon, 22.dp, color)
            Spacer(Modifier.width(8.dp))
        }
        BasicText(text, maxLines = 1, style = PbType.button.copy(color = color))
    }
}

@Composable
private fun ResumeCardView(ui: PlayerUi, card: ResumeCard) {
    CenterCard {
        BasicText(
            androidx.compose.ui.res.stringResource(app.peanutbutter.tv.R.string.resume_eyebrow),
            style = PbType.label.copy(color = PbColors.primary, fontSize = 12.sp, letterSpacing = 1.5.sp, fontWeight = FontWeight.W800),
        )
        Spacer(Modifier.height(8.dp))
        BasicText(card.title, maxLines = 2, overflow = TextOverflow.Ellipsis, style = PbType.h2)
        Spacer(Modifier.height(18.dp))
        if (card.totalMs > card.atMs) {
            LinearBar(
                (card.atMs.toFloat() / card.totalMs).coerceIn(0.01f, 1f),
                Modifier.fillMaxWidth().height(4.dp),
                Color.White.copy(alpha = 0.16f),
            )
            Spacer(Modifier.height(8.dp))
        }
        Row {
            BasicText(clock(card.atMs), style = PbType.meta.copy(color = PbColors.text, fontWeight = FontWeight.W700))
            Spacer(Modifier.weight(1f))
            if (card.totalMs > card.atMs) BasicText("-" + clock(card.totalMs - card.atMs), style = PbType.meta)
        }
        Spacer(Modifier.height(20.dp))
        Row {
            PillButton(
                androidx.compose.ui.res.stringResource(app.peanutbutter.tv.R.string.resume_continue, clock(card.atMs)),
                Icons.Rounded.PlayArrow, primary = true, lit = ui.resumeIndex == 0,
                modifier = Modifier.weight(3f),
            )
            Spacer(Modifier.width(12.dp))
            PillButton(
                androidx.compose.ui.res.stringResource(app.peanutbutter.tv.R.string.resume_start_over),
                Icons.Rounded.Replay, primary = false, lit = ui.resumeIndex == 1,
                modifier = Modifier.weight(2f),
            )
        }
    }
}

@Composable
private fun LeaveCard(ui: PlayerUi) {
    CenterCard {
        BasicText(ui.leaveTitle, style = PbType.h2)
        Spacer(Modifier.height(8.dp))
        BasicText(ui.leaveMessage, style = PbType.body.copy(color = PbColors.textMuted))
        Spacer(Modifier.height(22.dp))
        Row {
            PillButton(ui.leaveStay, Icons.Rounded.PlayArrow, primary = true, lit = ui.leaveIndex == 0, modifier = Modifier.weight(1f))
            Spacer(Modifier.width(12.dp))
            PillButton(ui.leaveGo, null, primary = false, lit = ui.leaveIndex == 1, modifier = Modifier.weight(1f))
        }
    }
}
