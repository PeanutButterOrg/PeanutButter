package app.peanutbutter.tv.ui

import androidx.activity.compose.BackHandler
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.outlined.ClosedCaption
import androidx.compose.material.icons.outlined.Dns
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material.icons.outlined.MovieFilter
import androidx.compose.material.icons.outlined.PhotoLibrary
import androidx.compose.material.icons.outlined.PlayCircleOutline
import androidx.compose.material.icons.outlined.Subtitles
import androidx.compose.material.icons.outlined.SystemUpdate
import androidx.compose.material.icons.outlined.VideoLibrary
import androidx.compose.material.icons.rounded.Apps
import androidx.compose.material.icons.rounded.ArrowDropDown
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.CleaningServices
import androidx.compose.material.icons.rounded.Devices
import androidx.compose.material.icons.rounded.HighQuality
import androidx.compose.material.icons.rounded.Hub
import androidx.compose.material.icons.rounded.SmartDisplay
import androidx.compose.material.icons.rounded.Translate
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Popup
import androidx.compose.ui.window.PopupProperties
import androidx.tv.material3.Icon
import app.peanutbutter.tv.ui.compose.PbColors
import app.peanutbutter.tv.ui.compose.PbRadius
import app.peanutbutter.tv.ui.compose.PbTextField
import app.peanutbutter.tv.ui.compose.PbType
import app.peanutbutter.tv.ui.compose.pbClick
import app.peanutbutter.tv.ui.compose.pbFocusRing

/** What Settings shows; [SettingsActivity] reads and saves it. */
class SettingsState {
    var serverUrl by mutableStateOf("")
    var quality by mutableStateOf("1080p")
    var player by mutableStateOf("")
    var languages by mutableStateOf<Set<String>>(emptySet())
    /** null until the server answers. */
    var sourcesReady by mutableStateOf<Boolean?>(null)
    var totalTitles by mutableStateOf<Int?>(null)
    var subtitlesConfigured by mutableStateOf(false)
    var opensubConfigured by mutableStateOf(false)
    var wyzieConfigured by mutableStateOf(false)
    var opensubEnabled by mutableStateOf(false)
    var opensubKey by mutableStateOf("")
    var wyzieKey by mutableStateOf("")
    var saving by mutableStateOf(false)
    var subsMessage by mutableStateOf<String?>(null)
    var clearOnExit by mutableStateOf(false)
    var cacheMessage by mutableStateOf<String?>(null)
    var appVersion by mutableStateOf("–")
    var serverVersion by mutableStateOf<String?>(null)
}

interface SettingsActions {
    fun back()
    fun setQuality(value: String)
    fun setPlayer(value: String)
    fun toggleLanguage(code: String)
    fun setOpenSubtitles(on: Boolean)
    fun saveSubtitles()
    fun setClearOnExit(on: Boolean)
    fun clearNow()
    fun checkUpdates()
    fun disconnect()
}

class SettingsChoices(
    val qualities: List<Pair<String, String>>,
    val players: List<Pair<String, String>>,
    val languages: List<Pair<String, String>>,
)

/** The desktop's Settings: a header, then sections (name left, a card of rows right). */
@Composable
fun SettingsScreen(state: SettingsState, choices: SettingsChoices, actions: SettingsActions) {
    BackHandler { actions.back() }
    val first = remember { FocusRequester() }
    LaunchedEffect(Unit) { runCatching { first.requestFocus() } }
    LazyColumn(
        modifier = Modifier.fillMaxSize().background(PbColors.ground),
        contentPadding = PaddingValues(start = 48.dp, end = 48.dp, top = 24.dp, bottom = 96.dp),
    ) {
        item { Header(state, actions) }
        item {
            Section("Playback", "How videos look on this TV.") {
                SettingRow(Icons.Rounded.HighQuality, "Preferred quality", "Torrents closest to this are listed first") {
                    MenuButton(
                        choices.qualities.firstOrNull { it.first == state.quality }?.second ?: state.quality,
                        choices.qualities, setOf(state.quality), Modifier.focusRequester(first),
                    ) { actions.setQuality(it) }
                }
                Divider()
                SettingRow(Icons.Rounded.SmartDisplay, "Video player", "ExoPlayer plays most files; try VLC if one won't play") {
                    MenuButton(
                        choices.players.firstOrNull { it.first == state.player }?.second ?: state.player,
                        choices.players, setOf(state.player),
                    ) { actions.setPlayer(it) }
                }
            }
        }
        item {
            Section("Library & sources", "Shared by every device paired with this server.") {
                SettingRow(Icons.Rounded.Translate, "Content languages", "Catalog and torrent search") {
                    val label = if (state.languages.isEmpty()) "All languages"
                    else choices.languages.filter { it.first in state.languages }.joinToString(", ") { it.second }
                    MenuButton(
                        label,
                        listOf("" to "All languages") + choices.languages,
                        if (state.languages.isEmpty()) setOf("") else state.languages,
                        multi = true,
                    ) { actions.toggleLanguage(it) }
                }
                Divider()
                SettingRow(
                    Icons.Rounded.Hub, "Torrent sources",
                    when (state.sourcesReady) {
                        null -> "Connect to see status"
                        true -> "Jackett or Stremio add-ons on the server"
                        false -> "Add Jackett or a Stremio add-on in the server console"
                    },
                ) {
                    StatusPill(
                        when (state.sourcesReady) {
                            null -> "Offline"
                            true -> "Ready"
                            false -> "Not set up"
                        },
                        state.sourcesReady == true,
                    )
                }
                state.totalTitles?.let { total ->
                    Divider()
                    SettingRow(Icons.Outlined.MovieFilter, "Catalog", "Movies, series and anime on the server") {
                        BasicText("$total titles", style = PbType.meta.copy(fontWeight = FontWeight.W600))
                    }
                }
            }
        }
        item {
            Section("Subtitles", "Search and download captions while you watch.") {
                SettingRow(
                    Icons.Outlined.Subtitles, "Online subtitles",
                    if (state.subtitlesConfigured) "A server key is set and used by every device"
                    else "Needs an OpenSubtitles or Wyzie key",
                ) {
                    Switch(state.opensubEnabled) { actions.setOpenSubtitles(!state.opensubEnabled) }
                }
                if (state.opensubEnabled) {
                    Column(Modifier.padding(start = 16.dp, end = 16.dp, top = 4.dp, bottom = 12.dp)) {
                        PbTextField(
                            state.opensubKey, { state.opensubKey = it },
                            if (state.opensubConfigured) "OpenSubtitles key (saved; paste to replace)" else "OpenSubtitles API key",
                            Modifier.fillMaxWidth(), password = true,
                        )
                        Spacer(Modifier.height(10.dp))
                        PbTextField(
                            state.wyzieKey, { state.wyzieKey = it },
                            if (state.wyzieConfigured) "Wyzie key (saved; paste to replace)" else "Wyzie API key (store.wyzie.io)",
                            Modifier.fillMaxWidth(), password = true,
                        )
                    }
                }
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier.fillMaxWidth().padding(start = 16.dp, end = 16.dp, bottom = 14.dp),
                ) {
                    BasicText(
                        state.subsMessage.orEmpty(),
                        style = PbType.meta.copy(fontSize = 14.sp),
                        modifier = Modifier.weight(1f),
                    )
                    Spacer(Modifier.width(12.dp))
                    PillButton(if (state.saving) "Saving…" else "Save", tonal = true) { actions.saveSubtitles() }
                }
            }
        }
        item {
            Section("This device", "Storage on this TV.") {
                SettingRow(Icons.Rounded.CleaningServices, "Clear stream cache when leaving", "Delete downloaded pieces when you close the player or quit") {
                    Switch(state.clearOnExit) { actions.setClearOnExit(!state.clearOnExit) }
                }
                Divider()
                SettingRow(Icons.Outlined.PhotoLibrary, "Cached artwork and streams", state.cacheMessage ?: "Free up space; posters download again as needed") {
                    PillButton("Clear now") { actions.clearNow() }
                }
            }
        }
        item {
            Section("About", null) {
                SettingRow(Icons.Rounded.Apps, "App version", null) {
                    BasicText(state.appVersion, style = PbType.meta.copy(fontWeight = FontWeight.W600))
                }
                Divider()
                SettingRow(Icons.Outlined.SystemUpdate, "Updates", "Check this server for a newer app") {
                    PillButton("Check for updates") { actions.checkUpdates() }
                }
                Divider()
                SettingRow(Icons.Outlined.Dns, "Server version", state.serverUrl.ifBlank { null }) {
                    BasicText(state.serverVersion ?: "–", style = PbType.meta.copy(fontWeight = FontWeight.W600))
                }
            }
        }
        item { DangerZone { actions.disconnect() } }
    }
}

@Composable
private fun Header(state: SettingsState, actions: SettingsActions) {
    Column(Modifier.padding(bottom = 28.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            var focused by remember { mutableStateOf(false) }
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier
                    .offset(x = (-10).dp)
                    .pbFocusRing(focused, CircleShape, 1.1f)
                    .pbClick({ focused = it }, { actions.back() })
                    .size(44.dp)
                    .background(if (focused) PbColors.focusSoft else Color.Transparent, CircleShape),
            ) { Icon(Icons.AutoMirrored.Rounded.ArrowBack, null, tint = PbColors.text, modifier = Modifier.size(26.dp)) }
            BasicText("Settings", style = PbType.h1)
        }
        BasicText(
            if (state.serverUrl.isBlank()) "Not paired with a server" else "Connected to ${state.serverUrl}",
            maxLines = 1, overflow = TextOverflow.Ellipsis,
            style = PbType.meta.copy(color = PbColors.textFaint),
            modifier = Modifier.padding(start = 34.dp, top = 2.dp),
        )
    }
}

/** One group: its name and what it's for on the left, a card of rows on the right. */
@Composable
private fun Section(title: String, description: String?, rows: @Composable () -> Unit) {
    Column {
        Row(Modifier.fillMaxWidth().padding(bottom = 28.dp)) {
            Column(Modifier.width(260.dp)) {
                BasicText(title, style = PbType.h1.copy(fontSize = 26.sp))
                if (description != null) {
                    Spacer(Modifier.height(6.dp))
                    BasicText(description, style = PbType.body.copy(color = PbColors.textMuted, lineHeight = 23.sp))
                }
            }
            Spacer(Modifier.width(40.dp))
            Column(
                Modifier
                    .weight(1f)
                    .background(PbColors.surface, RoundedCornerShape(PbRadius.panel))
                    .border(1.dp, PbColors.line, RoundedCornerShape(PbRadius.panel)),
            ) { rows() }
        }
        Box(Modifier.fillMaxWidth().height(1.dp).background(PbColors.line))
        Spacer(Modifier.height(28.dp))
    }
}

@Composable
private fun Divider() {
    Box(Modifier.padding(start = 66.dp).fillMaxWidth().height(1.dp).background(PbColors.line))
}

/** Icon tile · label and subtitle · the control. */
@Composable
private fun SettingRow(icon: ImageVector, label: String, subtitle: String?, trailing: @Composable () -> Unit) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 72.dp)
            .padding(horizontal = 16.dp, vertical = 12.dp),
    ) {
        Box(
            contentAlignment = Alignment.Center,
            modifier = Modifier
                .size(38.dp)
                .background(Color.White.copy(alpha = 0.06f), RoundedCornerShape(9.dp))
                .border(1.dp, PbColors.line, RoundedCornerShape(9.dp)),
        ) { Icon(icon, null, tint = PbColors.textMuted, modifier = Modifier.size(20.dp)) }
        Spacer(Modifier.width(16.dp))
        Column(Modifier.weight(1f)) {
            BasicText(label, style = PbType.title.copy(fontSize = 17.sp))
            if (subtitle != null) {
                Spacer(Modifier.height(3.dp))
                BasicText(subtitle, style = PbType.meta.copy(fontSize = 14.sp, color = PbColors.textFaint, lineHeight = 18.sp))
            }
        }
        Spacer(Modifier.width(16.dp))
        trailing()
    }
}

/** A setting's value with a drop arrow; its menu opens under it. */
@Composable
private fun MenuButton(
    label: String,
    options: List<Pair<String, String>>,
    selected: Set<String>,
    modifier: Modifier = Modifier,
    multi: Boolean = false,
    onPick: (String) -> Unit,
) {
    var focused by remember { mutableStateOf(false) }
    var open by remember { mutableStateOf(false) }
    val shape = RoundedCornerShape(PbRadius.card + 2.dp)
    Box {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = modifier
                .pbFocusRing(focused, RoundedCornerShape(PbRadius.card + 5.dp), 1.04f)
                .pbClick({ focused = it }, { open = true })
                .height(46.dp)
                .widthIn(max = 280.dp)
                .background(if (focused) PbColors.focusSoft else PbColors.surfaceRaised, shape)
                .border(1.dp, PbColors.line, shape)
                .padding(start = 14.dp, end = 8.dp),
        ) {
            BasicText(label, maxLines = 1, overflow = TextOverflow.Ellipsis, style = PbType.button.copy(fontSize = 15.sp), modifier = Modifier.weight(1f, fill = false))
            Spacer(Modifier.width(6.dp))
            Icon(Icons.Rounded.ArrowDropDown, null, tint = PbColors.textMuted, modifier = Modifier.size(22.dp))
        }
        if (open) {
            Popup(
                alignment = Alignment.TopEnd,
                offset = IntOffset(0, 140),
                onDismissRequest = { open = false },
                properties = PopupProperties(focusable = true),
            ) {
                ChoiceList(options, selected) { value ->
                    onPick(value)
                    if (!multi) open = false
                }
            }
        }
    }
}

@Composable
private fun ChoiceList(options: List<Pair<String, String>>, selected: Set<String>, onPick: (String) -> Unit) {
    val firstOn = remember { FocusRequester() }
    val start = options.indexOfFirst { it.first in selected }.coerceAtLeast(0)
    LaunchedEffect(Unit) { runCatching { firstOn.requestFocus() } }
    val shape = RoundedCornerShape(PbRadius.card + 2.dp)
    LazyColumn(
        state = androidx.compose.foundation.lazy.rememberLazyListState((start - 3).coerceAtLeast(0)),
        modifier = Modifier
            .widthIn(min = 220.dp, max = 300.dp)
            .heightIn(max = 340.dp)
            .background(PbColors.surfaceRaised, shape)
            .border(1.dp, PbColors.line, shape)
            .padding(vertical = 6.dp),
    ) {
        itemsIndexed(options) { i, (value, label) ->
            var focused by remember { mutableStateOf(false) }
            val on = value in selected
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .then(if (i == start) Modifier.focusRequester(firstOn) else Modifier)
                    .pbClick({ focused = it }, { onPick(value) })
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

/** On / off, amber when on. */
@Composable
private fun Switch(on: Boolean, onToggle: () -> Unit) {
    var focused by remember { mutableStateOf(false) }
    val knob by animateDpAsState(if (on) 24.dp else 2.dp, tween(140), label = "knob")
    val track = RoundedCornerShape(PbRadius.pill)
    Box(
        modifier = Modifier
            .pbFocusRing(focused, track, 1.08f)
            .pbClick({ focused = it }, onToggle)
            .size(52.dp, 30.dp)
            .background(if (on) PbColors.primary else PbColors.surfaceRaised, track)
            .border(1.dp, if (on) Color.Transparent else PbColors.line, track),
    ) {
        Box(
            Modifier
                .padding(start = knob, top = 3.dp)
                .size(24.dp)
                .background(if (on) PbColors.onPrimary else PbColors.textMuted, CircleShape),
        )
    }
}

@Composable
private fun PillButton(text: String, tonal: Boolean = false, onClick: () -> Unit) {
    var focused by remember { mutableStateOf(false) }
    val pill = RoundedCornerShape(PbRadius.pill)
    BasicText(
        text,
        maxLines = 1,
        style = PbType.button.copy(fontSize = 15.sp),
        modifier = Modifier
            .pbFocusRing(focused, pill, 1.05f)
            .pbClick({ focused = it }, onClick)
            .background(
                when {
                    focused -> PbColors.focusSoft
                    tonal -> PbColors.surfaceRaised
                    else -> Color.Transparent
                },
                pill,
            )
            .border(1.dp, PbColors.line, pill)
            .padding(horizontal = 18.dp, vertical = 10.dp),
    )
}

@Composable
private fun StatusPill(label: String, ok: Boolean) {
    val pill = RoundedCornerShape(PbRadius.pill)
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .background(PbColors.surfaceRaised, pill)
            .border(1.dp, PbColors.line, pill)
            .padding(horizontal = 12.dp, vertical = 6.dp),
    ) {
        Box(Modifier.size(8.dp).background(if (ok) PbColors.good else PbColors.textFaint, CircleShape))
        Spacer(Modifier.width(8.dp))
        BasicText(label, style = PbType.meta.copy(color = if (ok) PbColors.text else PbColors.textMuted, fontWeight = FontWeight.W600))
    }
}

/** Kept apart from everyday settings so it isn't hit by accident. */
@Composable
private fun DangerZone(onDisconnect: () -> Unit) {
    val red = Color(0xFFFF8A80)
    val shape = RoundedCornerShape(16.dp)
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.SpaceBetween,
        modifier = Modifier
            .fillMaxWidth()
            .background(red.copy(alpha = 0.05f), shape)
            .border(1.dp, red.copy(alpha = 0.25f), shape)
            .padding(start = 18.dp, end = 14.dp, top = 14.dp, bottom = 14.dp),
    ) {
        Column(Modifier.weight(1f)) {
            BasicText("Disconnect this device", style = PbType.title.copy(fontSize = 17.sp))
            Spacer(Modifier.height(3.dp))
            BasicText(
                "Signs this app out of the server. You will need a new pairing code.",
                style = PbType.meta.copy(fontSize = 14.sp, color = Color.White.copy(alpha = 0.54f)),
            )
        }
        Spacer(Modifier.width(16.dp))
        var focused by remember { mutableStateOf(false) }
        val pill = RoundedCornerShape(PbRadius.pill)
        BasicText(
            "Disconnect",
            style = PbType.button.copy(fontSize = 15.sp, color = red),
            modifier = Modifier
                .pbFocusRing(focused, pill, 1.05f)
                .pbClick({ focused = it }, onDisconnect)
                .background(if (focused) red.copy(alpha = 0.15f) else Color.Transparent, pill)
                .border(1.dp, red.copy(alpha = 0.5f), pill)
                .padding(horizontal = 18.dp, vertical = 10.dp),
        )
    }
}
