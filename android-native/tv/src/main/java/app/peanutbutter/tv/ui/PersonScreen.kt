package app.peanutbutter.tv.ui

import androidx.compose.foundation.background
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
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.rounded.Person
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.tv.material3.Icon
import app.peanutbutter.core.PersonCredit
import app.peanutbutter.core.PersonDetails
import app.peanutbutter.core.TitleItem
import app.peanutbutter.tv.ui.compose.PbColors
import app.peanutbutter.tv.ui.compose.PbImage
import app.peanutbutter.tv.ui.compose.PbSize
import app.peanutbutter.tv.ui.compose.PbSpace
import app.peanutbutter.tv.ui.compose.PbType
import app.peanutbutter.tv.ui.compose.PosterCard
import app.peanutbutter.tv.ui.compose.pbClick
import app.peanutbutter.tv.ui.compose.pbFocusRing

/** A cast or crew member's page; [PersonActivity] loads it. */
class PersonState {
    var name by mutableStateOf("")
    var person by mutableStateOf<PersonDetails?>(null)
    var error by mutableStateOf<String?>(null)
    /** Fetching a credit the catalog didn't have yet. */
    var opening by mutableStateOf(false)
}

private val gutter = PbSpace.gutterTv
private val gap = 14.dp

/** Photo, name, birth and bio, then everything they acted in and worked on. */
@Composable
fun PersonScreen(state: PersonState, onBack: () -> Unit, onOpen: (PersonCredit) -> Unit) {
    val firstCard = remember { FocusRequester() }
    val back = remember { FocusRequester() }
    val person = state.person
    LaunchedEffect(person, state.error) {
        runCatching {
            if (person != null && (person.acting.isNotEmpty() || person.crew.isNotEmpty())) firstCard.requestFocus()
            else back.requestFocus()
        }
    }
    BoxWithConstraints(Modifier.fillMaxSize().background(PbColors.ground)) {
        val width = maxWidth - gutter * 2
        val columns = ((width + gap) / (PbSize.posterWidthTv + gap)).toInt().coerceAtLeast(3)
        val cell = (width - gap * (columns - 1)) / columns
        var first = true
        LazyVerticalGrid(
            columns = GridCells.Fixed(columns),
            contentPadding = PaddingValues(start = gutter, end = gutter, top = 16.dp, bottom = 40.dp),
            horizontalArrangement = Arrangement.spacedBy(gap),
            verticalArrangement = Arrangement.spacedBy(gap + 6.dp),
            modifier = Modifier.fillMaxSize(),
        ) {
            item(key = "header", span = { GridItemSpan(maxLineSpan) }) {
                Header(state, back, onBack)
            }
            when {
                state.error != null -> item(key = "error", span = { GridItemSpan(maxLineSpan) }) {
                    BasicText(
                        state.error.orEmpty(),
                        style = PbType.body.copy(color = PbColors.textMuted, textAlign = TextAlign.Center),
                        modifier = Modifier.fillMaxWidth().padding(48.dp),
                    )
                }
                person == null -> Unit
                else -> listOf("Acting" to person.acting, "Crew" to person.crew).forEach { (label, credits) ->
                    if (credits.isEmpty()) return@forEach
                    item(key = "head-$label", span = { GridItemSpan(maxLineSpan) }) {
                        Row(verticalAlignment = Alignment.Bottom, modifier = Modifier.padding(top = 18.dp)) {
                            BasicText(label, style = PbType.h2)
                            Spacer(Modifier.width(10.dp))
                            BasicText("${credits.size}", style = PbType.meta.copy(color = PbColors.textFaint))
                        }
                    }
                    val focusFirst = first
                    first = false
                    itemsIndexed(credits, key = { _, c -> "$label-${c.kind}-${c.tmdbId}" }) { i, c ->
                        CreditCard(
                            c, cell,
                            if (focusFirst && i == 0) Modifier.focusRequester(firstCard) else Modifier,
                        ) { onOpen(c) }
                    }
                }
            }
        }
        if (state.opening) {
            Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.55f)), contentAlignment = Alignment.Center) {
                BasicText("Opening…", style = PbType.h2)
            }
        }
    }
}

@Composable
private fun Header(state: PersonState, back: FocusRequester, onBack: () -> Unit) {
    val p = state.person
    Column {
        var backFocused by remember { mutableStateOf(false) }
        Box(
            contentAlignment = Alignment.Center,
            modifier = Modifier
                .focusRequester(back)
                .pbFocusRing(backFocused, CircleShape, 1.1f)
                .pbClick({ backFocused = it }, onBack)
                .size(48.dp)
                .background(if (backFocused) PbColors.focusSoft else Color.Transparent, CircleShape),
        ) { Icon(Icons.AutoMirrored.Rounded.ArrowBack, null, tint = PbColors.text, modifier = Modifier.size(28.dp)) }
        Spacer(Modifier.height(12.dp))
        Row {
            Box(
                Modifier
                    .size(176.dp, 264.dp)
                    .clip(RoundedCornerShape(14.dp))
                    .background(PbColors.surface),
                contentAlignment = Alignment.Center,
            ) {
                if (p?.profileUrl.isNullOrBlank()) {
                    Icon(Icons.Rounded.Person, null, tint = Color.White.copy(alpha = 0.24f), modifier = Modifier.size(56.dp))
                } else {
                    PbImage(p?.profileUrl, Modifier.fillMaxSize(), 176.dp, 264.dp, alignment = Alignment.TopCenter)
                }
            }
            Spacer(Modifier.width(28.dp))
            Column(Modifier.weight(1f)) {
                BasicText(
                    p?.name ?: state.name,
                    maxLines = 2, overflow = TextOverflow.Ellipsis,
                    style = PbType.hero.copy(fontSize = 46.sp, lineHeight = 50.sp),
                )
                val meta = p?.let { personMeta(it) }.orEmpty()
                if (meta.isNotEmpty()) {
                    Spacer(Modifier.height(10.dp))
                    BasicText(meta, style = PbType.meta.copy(fontSize = 16.sp, color = PbColors.textMuted))
                }
                p?.biography?.let {
                    Spacer(Modifier.height(16.dp))
                    BasicText(
                        it, maxLines = 6, overflow = TextOverflow.Ellipsis,
                        style = PbType.body.copy(color = Color(0xFFD6DAE3), lineHeight = 24.sp),
                    )
                }
                if (p == null && state.error == null) {
                    Spacer(Modifier.height(16.dp))
                    BasicText("Loading…", style = PbType.body.copy(color = PbColors.textFaint))
                }
            }
        }
    }
}

/** "Acting · Born 18 Dec 1963 in Shawnee, Oklahoma · Died …" */
private fun personMeta(p: PersonDetails): String {
    // SimpleDateFormat, not java.time: that needs Android 8 and TVs run 7.
    fun date(d: String): String = runCatching {
        val parsed = java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.US).parse(d)!!
        java.text.SimpleDateFormat("d MMM yyyy", java.util.Locale.US).format(parsed)
    }.getOrDefault(d)
    return listOfNotNull(
        p.knownFor,
        p.birthday?.let { b -> "Born ${date(b)}" + (p.placeOfBirth?.let { " in $it" } ?: "") },
        p.deathday?.let { "Died ${date(it)}" },
    ).joinToString("  ·  ")
}

@Composable
private fun CreditCard(credit: PersonCredit, width: androidx.compose.ui.unit.Dp, modifier: Modifier, onClick: () -> Unit) {
    // A poster card needs a title; credits outside the catalog get a stand-in id.
    val item = TitleItem(
        id = credit.titleId ?: "tmdb-${credit.kind}-${credit.tmdbId}",
        kind = credit.kind,
        title = credit.title,
        year = credit.year,
        posterUrl = credit.posterUrl,
        tmdbVoteAverage = credit.voteAverage,
    )
    Column(Modifier.width(width)) {
        PosterCard(item, width, onClick, modifier)
        Spacer(Modifier.height(8.dp))
        BasicText(
            credit.title, maxLines = 1, overflow = TextOverflow.Ellipsis,
            style = PbType.body.copy(fontSize = 14.sp, fontWeight = FontWeight.W600),
        )
        val sub = listOfNotNull(credit.year?.toString(), credit.role).joinToString(" · ")
        if (sub.isNotEmpty()) {
            BasicText(
                sub, maxLines = 1, overflow = TextOverflow.Ellipsis,
                style = PbType.body.copy(fontSize = 13.sp, color = Color.White.copy(alpha = 0.54f)),
            )
        }
    }
}
