package app.peanutbutter.tv.ui

import android.app.Activity
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
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
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.Link
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.Refresh
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.tv.material3.Icon
import app.peanutbutter.core.ReleaseTags
import app.peanutbutter.core.StreamHealth
import app.peanutbutter.core.StreamSource
import app.peanutbutter.tv.R
import app.peanutbutter.tv.ui.compose.PbColors
import app.peanutbutter.tv.ui.compose.PbImage
import app.peanutbutter.tv.ui.compose.PbRadius
import app.peanutbutter.tv.ui.compose.PbSize
import app.peanutbutter.tv.ui.compose.PbType
import app.peanutbutter.tv.ui.compose.pbClick
import app.peanutbutter.tv.ui.compose.pbFocusRing
import kotlinx.coroutines.launch

/**
 * Choose a stream, drawn like the desktop's picker: the poster and title,
 * Torrents / Direct links tabs, then the ranked sources (the first is Best).
 */
object SourcesDialog {
    fun show(
        activity: Activity,
        title: String,
        sources: List<StreamSource>,
        /** "Season 2 · Episode 3" or "Movie" under the title. */
        subtitle: String = "",
        posterUrl: String? = null,
        onRefresh: (suspend () -> List<StreamSource>)? = null,
        onPicked: (StreamSource) -> Unit,
    ) {
        showPbDialog(activity) { dismiss ->
            Picker(activity, title, subtitle, posterUrl, sources, onRefresh, dismiss) { src ->
                dismiss()
                onPicked(src)
            }
        }
    }
}

@Composable
private fun Picker(
    activity: Activity,
    title: String,
    subtitle: String,
    posterUrl: String?,
    initial: List<StreamSource>,
    onRefresh: (suspend () -> List<StreamSource>)?,
    close: () -> Unit,
    onPick: (StreamSource) -> Unit,
) {
    var all by remember { mutableStateOf(initial) }
    var refreshing by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var direct by remember { mutableStateOf(initial.none { !it.isHttp }) }
    val scope = rememberCoroutineScope()
    val torrents = all.count { !it.isHttp }
    val links = all.count { it.isHttp }
    val both = torrents > 0 && links > 0
    val shown = if (both) all.filter { it.isHttp == direct } else all
    val first = remember { FocusRequester() }
    LaunchedEffect(shown.firstOrNull()?.key) { runCatching { first.requestFocus() } }

    val shape = RoundedCornerShape(PbRadius.panel + 4.dp)
    val maxH = (LocalConfiguration.current.screenHeightDp * 0.86f).dp
    Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.55f)), contentAlignment = Alignment.Center) {
        Column(
            Modifier
                .width(680.dp)
                .heightIn(max = maxH)
                .shadow(40.dp, shape)
                .background(Brush.verticalGradient(listOf(Color(0xFF1C1D25), PbColors.surface)), shape)
                .border(1.dp, PbColors.line, shape)
                .padding(18.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (!posterUrl.isNullOrBlank()) {
                    PbImage(posterUrl, Modifier.size(56.dp, 84.dp).clip(RoundedCornerShape(8.dp)), 56.dp, 84.dp)
                    Spacer(Modifier.width(14.dp))
                }
                Column(Modifier.weight(1f)) {
                    BasicText("CHOOSE A STREAM", style = PbType.label.copy(color = PbColors.primary, letterSpacing = 1.1.sp))
                    Spacer(Modifier.height(2.dp))
                    BasicText(
                        title.ifBlank { "Choose a stream" }, maxLines = 1, overflow = TextOverflow.Ellipsis,
                        style = PbType.h1.copy(fontSize = 24.sp),
                    )
                    if (subtitle.isNotBlank()) BasicText(subtitle, style = PbType.meta)
                }
                if (onRefresh != null) {
                    RoundIcon(Icons.Rounded.Refresh) {
                        if (refreshing) return@RoundIcon
                        refreshing = true
                        error = null
                        scope.launch {
                            try {
                                val next = onRefresh()
                                if (next.isEmpty()) error = activity.getString(R.string.no_sources)
                                else {
                                    all = next
                                    direct = next.none { !it.isHttp }
                                }
                            } catch (e: Exception) {
                                error = e.message ?: activity.getString(R.string.no_sources)
                            } finally {
                                refreshing = false
                            }
                        }
                    }
                }
                RoundIcon(Icons.Rounded.Close, onClick = close)
            }
            if (both) {
                Spacer(Modifier.height(12.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Tab("Torrents", torrents, !direct, Modifier.weight(1f)) { direct = false }
                    Tab("Direct links", links, direct, Modifier.weight(1f)) { direct = true }
                }
            }
            Spacer(Modifier.height(10.dp))
            BasicText(
                when {
                    refreshing -> activity.getString(R.string.refreshing_sources)
                    direct && both || links > 0 && torrents == 0 -> activity.getString(R.string.sources_note_direct)
                    else -> activity.getString(R.string.sources_note)
                },
                style = PbType.meta.copy(fontSize = 14.sp, color = PbColors.textFaint),
            )
            error?.let {
                Spacer(Modifier.height(6.dp))
                BasicText(it, style = PbType.meta.copy(color = PbColors.bad))
            }
            Spacer(Modifier.height(10.dp))
            LazyColumn(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                itemsIndexed(shown, key = { _, s -> s.key }) { i, s ->
                    SourceTile(activity, s, best = i == 0, if (i == 0) Modifier.focusRequester(first) else Modifier) { onPick(s) }
                }
            }
        }
    }
}

@Composable
private fun RoundIcon(icon: ImageVector, onClick: () -> Unit) {
    var focused by remember { mutableStateOf(false) }
    Box(
        contentAlignment = Alignment.Center,
        modifier = Modifier
            .pbFocusRing(focused, CircleShape, 1.1f)
            .pbClick({ focused = it }, onClick)
            .size(44.dp)
            .background(if (focused) PbColors.focusSoft else Color.Transparent, CircleShape),
    ) { Icon(icon, null, tint = PbColors.textMuted, modifier = Modifier.size(24.dp)) }
}

@Composable
private fun Tab(label: String, count: Int, selected: Boolean, modifier: Modifier, onClick: () -> Unit) {
    var focused by remember { mutableStateOf(false) }
    val pill = RoundedCornerShape(PbRadius.pill)
    val fg = if (selected) PbColors.onPrimary else PbColors.textMuted
    Box(
        contentAlignment = Alignment.Center,
        modifier = modifier
            .pbFocusRing(focused, pill, 1.03f)
            .pbClick({ focused = it }, onClick)
            .height(40.dp)
            .background(if (selected) PbColors.primary else if (focused) PbColors.focusSoft else Color.Transparent, pill)
            .border(1.dp, if (selected) Color.Transparent else PbColors.line, pill),
    ) {
        BasicText(
            buildAnnotatedString {
                append(label)
                withStyle(SpanStyle(color = fg.copy(alpha = 0.75f))) { append("  $count") }
            },
            style = PbType.button.copy(color = fg, fontSize = 15.sp),
        )
    }
}

/** One source: quality box, health, size and codecs, where it's from, play. */
@Composable
private fun SourceTile(activity: Activity, s: StreamSource, best: Boolean, modifier: Modifier, onClick: () -> Unit) {
    var focused by remember { mutableStateOf(false) }
    val shape = RoundedCornerShape(12.dp)
    val tags = ReleaseTags.parse(s.title)
    val status = if (s.isHttp) activity.getString(R.string.direct_link)
    else "${StreamHealth.label(s.health)} · ${s.seeders} seeder${if (s.seeders == 1) "" else "s"}"
    val spec = listOf(s.size.takeIf { it.isNotBlank() && it != "?" }, tags.codec, tags.audio)
        .filter { !it.isNullOrBlank() }.joinToString(" · ")
    val origin = listOf(
        languageName(s.language),
        if (s.providers.size > 1) s.providers.joinToString(" + ") else StreamHealth.sourceLabel(s),
    ).filter { it.isNotBlank() }.joinToString(" · ")
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = modifier
            .fillMaxWidth()
            .pbClick({ focused = it }, onClick)
            .background(
                if (best) Brush.horizontalGradient(0f to Color(0x1FE2A456), 0.6f to PbColors.surfaceRaised)
                else Brush.horizontalGradient(listOf(PbColors.surfaceRaised, PbColors.surfaceRaised)),
                shape,
            )
            .border(
                if (focused) PbSize.focusRing else 1.dp,
                when {
                    focused -> PbColors.focus
                    best -> PbColors.primary
                    else -> Color.Transparent
                },
                shape,
            )
            .padding(horizontal = 12.dp, vertical = 10.dp),
    ) {
        QualityBox(tags)
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (s.isHttp) Icon(Icons.Rounded.Link, null, tint = PbColors.textMuted, modifier = Modifier.size(16.dp))
                else SignalBars(
                    when (s.health) {
                        "excellent" -> 4
                        "good" -> 3
                        "decent" -> 2
                        else -> 1
                    },
                )
                Spacer(Modifier.width(7.dp))
                BasicText(status, maxLines = 1, overflow = TextOverflow.Ellipsis, style = PbType.meta.copy(fontSize = 14.sp), modifier = Modifier.weight(1f, fill = false))
                if (best) {
                    Spacer(Modifier.width(8.dp))
                    BasicText(
                        "Best",
                        style = PbType.label.copy(fontSize = 11.sp, color = PbColors.onPrimary),
                        modifier = Modifier.background(PbColors.primary, RoundedCornerShape(5.dp)).padding(horizontal = 7.dp, vertical = 2.dp),
                    )
                }
            }
            Spacer(Modifier.height(3.dp))
            if (spec.isNotEmpty()) BasicText(spec, style = PbType.title.copy(fontSize = 16.sp))
            if (origin.isNotEmpty()) BasicText(origin, maxLines = 1, overflow = TextOverflow.Ellipsis, style = PbType.meta.copy(fontSize = 13.sp, color = PbColors.textFaint))
            BasicText(s.title, maxLines = 1, overflow = TextOverflow.Ellipsis, style = PbType.meta.copy(fontSize = 12.sp, color = PbColors.textFaint))
        }
        Spacer(Modifier.width(10.dp))
        Box(
            contentAlignment = Alignment.Center,
            modifier = Modifier
                .size(38.dp)
                .background(if (best || focused) PbColors.primary else Color.White.copy(alpha = 0.10f), CircleShape),
        ) {
            Icon(Icons.Rounded.PlayArrow, null, tint = if (best || focused) PbColors.onPrimary else PbColors.text, modifier = Modifier.size(22.dp))
        }
    }
}

/** "4K / HDR", "1080 / BLURAY": the copy's quality at a glance. */
@Composable
private fun QualityBox(tags: ReleaseTags) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
        modifier = Modifier
            .size(58.dp, 52.dp)
            .background(PbColors.ground, RoundedCornerShape(8.dp))
            .border(1.dp, PbColors.line, RoundedCornerShape(8.dp)),
    ) {
        BasicText(tags.resolution.ifEmpty { "HD" }, style = PbType.h2.copy(fontSize = 17.sp))
        if (tags.source.isNotEmpty()) {
            Spacer(Modifier.height(3.dp))
            BasicText(tags.source.uppercase(), maxLines = 1, style = PbType.label.copy(fontSize = 9.sp, color = PbColors.primary, letterSpacing = 0.6.sp))
        }
    }
}

/** 1–4 lit bars: green when healthy, amber when weak. */
@Composable
private fun SignalBars(lit: Int) {
    val on = if (lit >= 3) PbColors.good else PbColors.warn
    Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(2.dp)) {
        for (i in 0 until 4) {
            Box(
                Modifier
                    .size(3.dp, (4f + i * 2.7f).dp)
                    .background(if (i < lit) on else Color.White.copy(alpha = 0.18f), RoundedCornerShape(1.dp)),
            )
        }
    }
}

/** "English" for "en"; empty when there's no language. */
private fun languageName(code: String): String {
    val c = code.trim()
    // The server says "unknown" / "und" when the release doesn't say.
    if (c.isEmpty() || c.equals("unknown", true) || c.equals("und", true)) return ""
    val name = java.util.Locale.forLanguageTag(c).getDisplayLanguage(java.util.Locale.ENGLISH)
    return if (name.isBlank() || name.equals(c, true)) c.uppercase() else name
}
