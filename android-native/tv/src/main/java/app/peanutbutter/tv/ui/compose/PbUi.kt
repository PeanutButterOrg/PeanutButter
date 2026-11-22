package app.peanutbutter.tv.ui.compose

import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsFocusedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.Favorite
import androidx.compose.material.icons.rounded.Star
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.withFrameNanos
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.drawscope.withTransform
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.draw.scale
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import com.bumptech.glide.load.resource.bitmap.DownsampleStrategy
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.tv.material3.Icon
import app.peanutbutter.core.HomeSections
import app.peanutbutter.core.ServiceBadges
import app.peanutbutter.core.TitleItem
import app.peanutbutter.tv.R
import com.bumptech.glide.Glide
import com.bumptech.glide.load.DecodeFormat
import com.bumptech.glide.load.engine.DiskCacheStrategy
import com.bumptech.glide.request.RequestOptions
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** Artwork through the app's Glide setup (RGB_565, sized, disk cached). */
@Composable
fun PbImage(
    url: String?,
    modifier: Modifier = Modifier,
    widthDp: Dp,
    heightDp: Dp,
    contentScale: ContentScale = ContentScale.Crop,
    alignment: Alignment = Alignment.Center,
) {
    val context = LocalContext.current.applicationContext
    // Load for the box's measured size, not [widthDp]/[heightDp]: those are
    // the intended size in dp, but TVs differ in density and boxes stretch.
    var size by remember { mutableStateOf(IntSize.Zero) }
    val target = if (size.width > 0 && size.height > 0) size else IntSize.Zero
    // The Glide request is kept with its picture and cleared once the picture
    // is no longer drawn: a request that isn't cleared holds its bitmap for
    // good (these use the app's context, so leaving a screen frees nothing).
    var shown by remember { mutableStateOf<LoadedImage?>(null) }
    fun release(old: LoadedImage?) {
        if (old != null) runCatching { Glide.with(context).clear(old.request) }
    }
    // Frees a picture once the frame that stopped drawing it is out. Not
    // cancellable: a quick next change must not skip it (nothing else holds
    // it any more); bounded, in case no further frame comes.
    suspend fun releaseAfterDraw(old: LoadedImage) = withContext(kotlinx.coroutines.NonCancellable) {
        kotlinx.coroutines.withTimeoutOrNull(500) {
            withFrameNanos { }
            withFrameNanos { }
        }
        release(old)
    }
    LaunchedEffect(url, target) {
        // Another picture (or none): stop drawing the old one, then free it.
        if (shown?.url != url) {
            val old = shown
            shown = null
            if (old != null) releaseAfterDraw(old)
        }
        if (url.isNullOrBlank() || target == IntSize.Zero) return@LaunchedEffect
        // Keep the picture's own shape, just big enough to cover the box; the
        // crop (and its alignment) happens once, when drawn.
        val request = Glide.with(context).asBitmap().load(url)
            .apply(
                RequestOptions()
                    .format(DecodeFormat.PREFER_RGB_565)
                    .disallowHardwareConfig()
                    .diskCacheStrategy(DiskCacheStrategy.AUTOMATIC)
                    .downsample(DownsampleStrategy.CENTER_OUTSIDE)
                    .override(target.width, target.height),
            )
            .submit()
        var adopted = false
        try {
            val bitmap = withContext(Dispatchers.IO) { runCatching { request.get() }.getOrNull() }
                ?: return@LaunchedEffect
            val old = shown
            shown = LoadedImage(url, request, bitmap.asImageBitmap())
            adopted = true
            // The new size's picture is drawn from the next frame: free the old one after it.
            if (old != null) releaseAfterDraw(old)
        } finally {
            if (!adopted) {
                withContext(kotlinx.coroutines.NonCancellable + Dispatchers.Main) {
                    runCatching { Glide.with(context).clear(request) }
                }
            }
        }
    }
    // Leaving the screen: nothing draws it any more.
    DisposableEffect(Unit) { onDispose { release(shown) } }
    Box(modifier.onSizeChanged { if (it.width > 0 && it.height > 0) size = it }) {
        shown?.let {
            Image(it.image, null, Modifier.fillMaxSize(), contentScale = contentScale, alignment = alignment)
        }
    }
}

/** A drawn picture and the Glide request that owns its bitmap. */
private class LoadedImage(
    val url: String,
    val request: com.bumptech.glide.request.FutureTarget<android.graphics.Bitmap>,
    val image: ImageBitmap,
)

/** Lists whose scrolling the screen drives itself (it pins the focused section). */
@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
val NoScroll = object : androidx.compose.foundation.gestures.BringIntoViewSpec {
    override fun calculateScrollDistance(offset: Float, size: Float, containerSize: Float) = 0f
}

/** Rows keep the focused card about 42% in, like the desktop app's TV build. */
@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
val RowScroll = object : androidx.compose.foundation.gestures.BringIntoViewSpec {
    override fun calculateScrollDistance(offset: Float, size: Float, containerSize: Float) =
        offset - (containerSize - size) * 0.42f
}

/** Focus state for a remote-driven control: clickable and lit while focused. */
@Composable
fun Modifier.pbClick(
    onFocus: (Boolean) -> Unit,
    onClick: () -> Unit,
): Modifier {
    val source = remember { MutableInteractionSource() }
    val focused by source.collectIsFocusedAsState()
    LaunchedEffect(focused) { onFocus(focused) }
    return clickable(interactionSource = source, indication = null, onClick = onClick)
}

/** The desktop's TV focus: white ring and a 1.06 lift. */
@Composable
fun Modifier.pbFocusRing(focused: Boolean, shape: Shape, scaleTo: Float = PbSize.focusScaleTv): Modifier {
    val scale by animateFloatAsState(if (focused) scaleTo else 1f, tween(160), label = "focus")
    return this
        .pbDrawScale(scale)
        .then(
            if (focused) {
                Modifier
                    .shadow(18.dp, shape, ambientColor = Color.Black, spotColor = Color.Black)
                    .border(PbSize.focusRing, PbColors.focus, shape)
            } else Modifier,
        )
}

private val glass = Color.Black.copy(alpha = 0.72f)

/** Star score chip (or Rotten Tomatoes %), top-left of a poster. */
@Composable
fun ScoreChip(item: TitleItem, compact: Boolean = true) {
    val score = item.displayScore ?: return
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .background(glass, RoundedCornerShape(if (compact) 6.dp else 8.dp))
            .padding(start = 5.dp, end = 6.dp, top = 3.dp, bottom = 3.dp),
    ) {
        val rt = score.rtScore
        if (rt == null) {
            Icon(Icons.Rounded.Star, null, tint = PbColors.primary, modifier = Modifier.size(14.dp))
            Spacer(Modifier.width(3.dp))
        }
        BasicText(
            score.label,
            style = PbType.body.copy(
                fontSize = 12.sp,
                fontWeight = FontWeight.W800,
                color = when {
                    rt == null -> Color.White
                    rt >= 60 -> PbColors.rt
                    else -> PbColors.good
                },
            ),
        )
        Spacer(Modifier.width(3.dp))
        BasicText(score.source, style = PbType.body.copy(fontSize = 10.sp, fontWeight = FontWeight.W600, color = Color.White.copy(alpha = 0.7f)))
    }
}

private val serviceLogos = mapOf(
    "netflix" to R.drawable.ic_service_netflix,
    "disney" to R.drawable.ic_service_disney,
    "hbo" to R.drawable.ic_service_hbo,
    "apple" to R.drawable.ic_service_apple,
    "paramount" to R.drawable.ic_service_paramount,
    "crunchyroll" to R.drawable.ic_service_crunchyroll,
    "mubi" to R.drawable.ic_service_mubi,
    "starz" to R.drawable.ic_service_starz,
    "showtime" to R.drawable.ic_service_showtime,
)

@Composable
private fun GlassChip(content: @Composable () -> Unit) {
    Box(
        contentAlignment = Alignment.Center,
        modifier = Modifier
            .height(22.dp)
            .background(glass, RoundedCornerShape(6.dp))
            .padding(horizontal = 5.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) { content() }
    }
}

/** Score, liked / watched and the streaming service along a poster's top edge. */
@Composable
private fun PosterBadges(item: TitleItem) {
    Row(Modifier.fillMaxWidth().padding(6.dp), verticalAlignment = Alignment.CenterVertically) {
        ScoreChip(item)
        Spacer(Modifier.weight(1f))
        if (item.favorite || item.watched) {
            Spacer(Modifier.width(4.dp))
            GlassChip {
                if (item.favorite) Icon(Icons.Rounded.Favorite, null, tint = PbColors.primary, modifier = Modifier.size(14.dp))
                if (item.favorite && item.watched) Spacer(Modifier.width(3.dp))
                if (item.watched) Icon(Icons.Rounded.CheckCircle, null, tint = PbColors.primary, modifier = Modifier.size(14.dp))
            }
        }
        item.services.firstOrNull()?.let { tag ->
            Spacer(Modifier.width(4.dp))
            GlassChip {
                val badge = ServiceBadges.of(tag)
                val logo = serviceLogos[tag.id]
                if (logo != null) {
                    Image(
                        painterResource(logo), tag.name,
                        colorFilter = ColorFilter.tint(Color(badge.color)),
                        modifier = Modifier.height(14.dp),
                    )
                } else {
                    BasicText(badge.label, style = PbType.body.copy(fontSize = 11.sp, fontWeight = FontWeight.W800, color = Color(badge.color)))
                }
            }
        }
    }
}

/** Resume share for a card's amber bar; 0 when there's nothing to resume. */
fun titleProgress(item: TitleItem): Float {
    if (item.watched) return 0f
    val p = item.watchProgress
    if (p > 0) return p.toFloat().coerceIn(0.02f, 1f)
    if (!item.canResume) return 0f
    if (item.durationMs <= 0) return 0.08f
    return (item.positionMs.toFloat() / item.durationMs).coerceIn(0f, 1f)
}

@Composable
private fun ProgressLine(value: Float, modifier: Modifier, height: Dp = 3.dp) {
    Box(modifier.fillMaxWidth().height(height).background(Color.White.copy(alpha = 0.24f))) {
        Box(Modifier.fillMaxWidth(value.coerceIn(0f, 1f)).height(height).background(PbColors.primary))
    }
}

val cardShape = RoundedCornerShape(PbRadius.card)

/** The desktop's PosterCard: 2:3 art, badges, name when there's no art, resume bar. */
@Composable
fun PosterCard(
    item: TitleItem,
    width: Dp,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    onFocus: (Boolean) -> Unit = {},
) {
    @Suppress("UNUSED_VARIABLE") val edits = app.peanutbutter.tv.ui.UserStateEdits.version
    val title = app.peanutbutter.tv.ui.UserStateEdits.apply(item)
    var focused by remember { mutableStateOf(false) }
    val height = width * 1.5f
    Box(
        modifier
            .size(width, height)
            .pbFocusRing(focused, RoundedCornerShape(PbRadius.card + 3.dp))
            .pbClick({ focused = it; onFocus(it) }, onClick)
            .clip(cardShape)
            .background(PbColors.surface),
    ) {
        PbImage(title.posterUrl, Modifier.fillMaxSize(), width, height)
        val hasArt = !title.posterUrl.isNullOrBlank()
        if (!hasArt) {
            Box(Modifier.fillMaxSize().background(Brush.verticalGradient(listOf(Color.Transparent, Color(0xCC000000)))))
            Column(Modifier.align(Alignment.BottomStart).padding(8.dp)) {
                BasicText(
                    title.displayTitle, maxLines = 2, overflow = TextOverflow.Ellipsis,
                    style = PbType.body.copy(color = Color.White, fontSize = 13.sp, fontWeight = FontWeight.W700),
                )
                title.year?.let { BasicText("$it", style = PbType.meta.copy(fontSize = 11.sp, color = Color.White.copy(alpha = 0.7f))) }
            }
        }
        PosterBadges(title)
        val p = titleProgress(title)
        if (p > 0.02f) ProgressLine(p, Modifier.align(Alignment.BottomStart))
    }
}

/**
 * Top 10: a big outlined rank number with the poster tucked over its right
 * edge, and the name under the poster. Same maths as the desktop's Top10Tile.
 */
@Composable
fun Top10Tile(
    rank: Int,
    item: TitleItem,
    posterWidth: Dp,
    onClick: () -> Unit,
    onFocus: (Boolean) -> Unit = {},
) {
    val box = posterWidth * 0.8f
    val overlap = posterWidth * 0.07f
    val posterHeight = posterWidth * 1.5f
    val measurer = rememberTextMeasurer()
    val density = LocalDensity.current
    Box(Modifier.width(box + posterWidth - overlap).height(posterHeight + TOP10_NAME_HEIGHT)) {
        Canvas(Modifier.width(box).height(posterHeight)) {
            val stroke = 3.dp.toPx()
            val tuck = 0.2f
            fun style(sizePx: Float) = TextStyle(
                fontFamily = PbFonts.display,
                fontWeight = FontWeight.W700,
                fontSize = with(density) { sizePx.toSp() },
                letterSpacing = if (rank >= 10) with(density) { (-sizePx * 0.04f).toSp() } else 0.sp,
            )
            // Digits stand 0.70 of the font size tall; most of the poster's height.
            val byHeight = (size.height - stroke) * 0.86f / 0.70f
            val probe = measurer.measure(if (rank >= 10) "$rank" else "8", style(byHeight))
            val visible = probe.size.width * (1 - tuck)
            val fontPx = if (visible <= size.width) byHeight else byHeight * size.width / visible
            val layout = measurer.measure("$rank", style(fontPx))
            val baseline = layout.firstBaseline
            drawText(
                layout,
                color = PbColors.textFaint,
                topLeft = Offset(size.width + layout.size.width * tuck - layout.size.width, size.height - stroke / 2 - baseline),
                drawStyle = Stroke(width = stroke),
            )
        }
        PosterCard(
            item, posterWidth, onClick,
            Modifier.align(Alignment.TopEnd),
            onFocus = onFocus,
        )
        BasicText(
            item.displayTitle,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            style = PbType.meta.copy(color = PbColors.text, textAlign = TextAlign.Center),
            modifier = Modifier.align(Alignment.BottomEnd).width(posterWidth),
        )
    }
}

val TOP10_NAME_HEIGHT = 28.dp

/** Continue watching: 16:9 still, name, time left and an amber bar. */
@Composable
fun WideCard(
    item: TitleItem,
    width: Dp,
    onClick: () -> Unit,
    onFocus: (Boolean) -> Unit = {},
) {
    var focused by remember { mutableStateOf(false) }
    val height = width * 9f / 16f
    Box(
        Modifier
            .size(width, height)
            .pbFocusRing(focused, RoundedCornerShape(PbRadius.card + 3.dp))
            .pbClick({ focused = it; onFocus(it) }, onClick)
            .clip(cardShape)
            .background(PbColors.surface),
    ) {
        val art = item.backdropUrl?.takeIf { it.isNotBlank() } ?: item.posterUrl
        PbImage(art, Modifier.fillMaxSize(), width, height)
        Box(Modifier.fillMaxSize().background(Brush.verticalGradient(0.4f to Color.Transparent, 1f to Color(0xD9000000))))
        Column(Modifier.align(Alignment.BottomStart).padding(start = 12.dp, end = 12.dp, bottom = 14.dp)) {
            BasicText(item.displayTitle, maxLines = 1, overflow = TextOverflow.Ellipsis, style = PbType.title)
            BasicText(HomeSections.timeLeft(item), style = PbType.meta.copy(color = PbColors.textMuted))
        }
        ProgressLine(titleProgress(item).coerceAtLeast(0.02f), Modifier.align(Alignment.BottomStart), 4.dp)
    }
}

/** Hero meta: ★ 8.0 TMDB · 2026 · 2h 53m · genre pills. */
@Composable
fun MetaRow(item: TitleItem, maxGenres: Int = 3) {
    val text = PbType.meta.copy(color = Color.White.copy(alpha = 0.82f), fontSize = 15.sp, fontWeight = FontWeight.W600)
    val pieces = ArrayList<@Composable () -> Unit>()
    item.displayScore?.let { score ->
        pieces += {
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (score.rtScore == null) {
                    Icon(Icons.Rounded.Star, null, tint = PbColors.primary, modifier = Modifier.size(17.dp))
                    Spacer(Modifier.width(3.dp))
                }
                BasicText(score.label, style = text.copy(color = Color.White, fontWeight = FontWeight.W800))
                Spacer(Modifier.width(4.dp))
                BasicText(score.source, style = text.copy(fontSize = 12.sp, color = Color.White.copy(alpha = 0.55f)))
            }
        }
    }
    item.year?.let { y -> pieces += { BasicText("$y", style = text) } }
    item.runtimeMinutes?.takeIf { it > 0 }?.let { m ->
        val label = if (m < 60) "${m}m" else if (m % 60 == 0) "${m / 60}h" else "${m / 60}h ${m % 60}m"
        pieces += { BasicText(label, style = text) }
    }
    item.genres.take(maxGenres).forEach { g ->
        pieces += {
            BasicText(
                g,
                style = text.copy(fontSize = 13.sp, color = Color.White.copy(alpha = 0.88f)),
                modifier = Modifier
                    .background(Color.White.copy(alpha = 0.10f), RoundedCornerShape(PbRadius.pill))
                    .padding(horizontal = 9.dp, vertical = 3.dp),
            )
        }
    }
    Row(verticalAlignment = Alignment.CenterVertically) {
        pieces.forEachIndexed { i, piece ->
            if (i > 0) {
                Box(Modifier.padding(horizontal = 9.dp).size(4.dp).background(Color.White.copy(alpha = 0.45f), CircleShape))
            }
            piece()
        }
    }
}

/** Play (amber, filled) or an outlined pill like My List / More info. */
@Composable
fun PbButton(
    text: String,
    icon: ImageVector?,
    primary: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    onFocus: (Boolean) -> Unit = {},
    /** Smaller, for buttons inside a card (Explore's and Search's featured title). */
    compact: Boolean = false,
) {
    var focused by remember { mutableStateOf(false) }
    val pill = RoundedCornerShape(PbRadius.pill)
    val color = if (primary) PbColors.onPrimary else PbColors.text
    Row(
        horizontalArrangement = Arrangement.Center,
        verticalAlignment = Alignment.CenterVertically,
        modifier = modifier
            .pbFocusRing(focused, pill)
            .pbClick({ focused = it; onFocus(it) }, onClick)
            .height(if (compact) 40.dp else PbSize.buttonHeightTv)
            .background(
                when {
                    primary -> PbColors.primary
                    focused -> PbColors.focusSoft
                    else -> Color.White.copy(alpha = 0.06f)
                },
                pill,
            )
            .border(1.dp, if (primary) Color.Transparent else Color.White.copy(alpha = 0.28f), pill)
            .padding(
                start = if (text.isEmpty()) 10.dp else if (compact) 12.dp else if (icon != null) 18.dp else 24.dp,
                end = if (text.isEmpty()) 10.dp else if (compact) 16.dp else 24.dp,
            ),
    ) {
        if (icon != null) {
            Icon(icon, null, tint = color, modifier = Modifier.size(if (compact) 20.dp else 24.dp))
            // An empty label: a round icon-only button.
            if (text.isNotEmpty()) Spacer(Modifier.width(if (compact) 6.dp else 8.dp))
        }
        if (text.isNotEmpty()) {
            BasicText(text, maxLines = 1, softWrap = false, style = PbType.button.copy(color = color, fontSize = if (compact) 15.sp else 17.sp))
        }
    }
}

/** App icon and "Peanut" + blue "Butter". */
@Composable
fun PbLogo() {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Image(
            painterResource(R.mipmap.ic_launcher), null,
            modifier = Modifier.size(32.dp).clip(RoundedCornerShape(8.dp)),
        )
        Spacer(Modifier.width(10.dp))
        BasicText(
            buildAnnotatedString {
                append("Peanut")
                withStyle(SpanStyle(color = PbColors.brand)) { append("Butter") }
            },
            style = PbType.h2.copy(fontSize = 22.sp, letterSpacing = (-0.2).sp),
        )
    }
}

/** The app's amber loading ring. */
@Composable
fun PbSpinner(modifier: Modifier = Modifier) {
    val t = androidx.compose.animation.core.rememberInfiniteTransition(label = "spin")
    val angle by t.animateFloat(
        0f, 360f,
        androidx.compose.animation.core.infiniteRepeatable(tween(900, easing = androidx.compose.animation.core.LinearEasing)),
        label = "a",
    )
    Canvas(modifier.size(40.dp)) {
        drawArc(
            PbColors.primary, angle, 270f, false,
            style = Stroke(3.dp.toPx(), cap = androidx.compose.ui.graphics.StrokeCap.Round),
        )
    }
}

/**
 * A text tab (top bar, My List / Watched, Search). No focus pill: the
 * underline says it all. Amber under the picked one; white under the one the
 * remote is on, so moving along shows where OK would go.
 */
@Composable
fun PbTab(label: String, selected: Boolean, modifier: Modifier = Modifier, onClick: () -> Unit) {
    var focused by remember { mutableStateOf(false) }
    val line by androidx.compose.animation.core.animateDpAsState(
        if (selected || focused) 22.dp else 0.dp, tween(120), label = "tab",
    )
    val lineColor by androidx.compose.animation.animateColorAsState(
        if (selected) PbColors.primary else PbColors.text, tween(120), label = "tabColor",
    )
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        modifier = modifier
            .padding(end = 6.dp)
            .pbClick({ focused = it }, onClick)
            .padding(horizontal = 14.dp, vertical = 8.dp),
    ) {
        BasicText(
            label,
            style = PbType.button.copy(
                fontSize = 17.sp,
                color = if (selected || focused) PbColors.text else PbColors.textMuted,
            ),
        )
        Spacer(Modifier.height(5.dp))
        Box(Modifier.width(line).height(2.dp).background(lineColor, RoundedCornerShape(2.dp)))
    }
}

/**
 * Grows what's drawn without changing the measured size. A layout scale
 * (Modifier.scale) also grows the bounds a list scrolls to, so while the
 * focus animation ran each frame re-scrolled the row: the list shook.
 */
fun Modifier.pbDrawScale(scale: Float): Modifier =
    if (scale == 1f) this else drawWithContent {
        withTransform({ scale(scale, scale, center) }) { this@drawWithContent.drawContent() }
    }

/**
 * A soft dark fade behind a header that content scrolls under: [extend]
 * past the header's bottom it reaches transparent (no hard edge).
 */
fun Modifier.pbHeaderShade(strength: Float, extend: Dp = 56.dp): Modifier = drawBehind {
    val total = size.height + extend.toPx()
    val edge = size.height / total
    drawRect(
        Brush.verticalGradient(
            0f to PbColors.ground.copy(alpha = 0.86f + 0.1f * strength),
            edge to PbColors.ground.copy(alpha = 0.3f + 0.45f * strength),
            1f to PbColors.ground.copy(alpha = 0f),
            endY = total,
        ),
        size = androidx.compose.ui.geometry.Size(size.width, total),
    )
}
