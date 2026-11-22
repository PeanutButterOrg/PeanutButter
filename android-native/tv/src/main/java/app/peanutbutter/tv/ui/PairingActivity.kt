package app.peanutbutter.tv.ui

import app.peanutbutter.tv.ui.compose.setPbContent
import android.content.Intent
import android.os.Bundle
import androidx.activity.compose.setContent
import androidx.compose.animation.core.animateFloat
import androidx.compose.foundation.background
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
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Dns
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
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.fragment.app.FragmentActivity
import androidx.tv.material3.Icon
import app.peanutbutter.core.ApiClient
import app.peanutbutter.core.Discovery
import app.peanutbutter.core.UnauthorizedException
import app.peanutbutter.tv.R
import app.peanutbutter.tv.asTv
import app.peanutbutter.tv.ui.compose.PbButton
import app.peanutbutter.tv.ui.compose.PbColors
import app.peanutbutter.tv.ui.compose.PbTextField
import app.peanutbutter.tv.ui.compose.PbType
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

private const val FOUND = "Server found on this network. Enter the 6-digit pairing code from the console."
private const val SIGN_IN = "Sign in on the server console, create a 6-digit code, then type it here."
private const val LOOKING = "Looking for a catalog server on this network…"

/** What the pairing screen shows. */
private class PairingState {
    var subtitle by mutableStateOf(SIGN_IN)
    var finding by mutableStateOf(false)
    var connecting by mutableStateOf(false)
    /** The server found on the network (shown as a row with Change). */
    var found by mutableStateOf<String?>(null)
    var showUrl by mutableStateOf(false)
    var url by mutableStateOf("")
    var code by mutableStateOf("")
    var error by mutableStateOf<String?>(null)
}

/** Pair this TV with a server, drawn like the desktop's pairing page. */
class PairingActivity : FragmentActivity() {
    private val scope = CoroutineScope(Dispatchers.Main + Job())
    private val ui = PairingState()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val saved = application.asTv().session.serverUrl
        if (saved.isNotBlank()) {
            ui.url = saved
            ui.found = saved
            ui.subtitle = FOUND
        } else {
            autoFind(saved)
        }
        setPbContent {
            PairingScreen(
                ui,
                onChange = {
                    ui.showUrl = true
                    if (ui.url.isBlank()) ui.url = "http://10.0.2.2:3001"
                },
                onConnect = ::connect,
                onFind = { autoFind(ui.url) },
            )
        }
    }

    override fun onDestroy() {
        // Stop LAN scans / connect attempts that would otherwise outlive the screen.
        scope.cancel()
        super.onDestroy()
    }

    private fun connect() {
        if (ui.connecting || ui.finding) return
        val app = application.asTv()
        val code = ui.code.trim()
        var base = ui.url.ifBlank { ui.found.orEmpty() }.ifBlank { app.session.serverUrl }
        if (code.length < 4) {
            ui.error = "Enter the pairing code"
            return
        }
        ui.connecting = true
        ui.error = null
        ui.subtitle = "Connecting…"
        scope.launch {
            try {
                val resolved = withContext(Dispatchers.IO) { Discovery.resolveReachableBase(base) }
                    ?: throw IllegalStateException("Server not reachable. Check the address or Find on this network.")
                base = resolved
                // Confirm the code with the server BEFORE saving anything — a
                // wrong or unchecked code must never be stored. Trade the
                // 6-digit code for this TV's own key and store only the key.
                // Older servers without /pair take the code.
                val token = withContext(Dispatchers.IO) {
                    check(Discovery.isPeanutButter(base)) { "Server not reachable at $base" }
                    val key = when (val r = app.api.exchangePairingCode(base, code)) {
                        is ApiClient.PairResult.Key -> r.key
                        is ApiClient.PairResult.Rejected -> throw UnauthorizedException(r.message)
                        ApiClient.PairResult.Unsupported -> code
                    }
                    app.api.verifyPairing(base, key)
                    key
                }
                app.session.serverUrl = base
                app.session.apiToken = token
                startActivity(homeIntent(this@PairingActivity))
                finish()
            } catch (e: Exception) {
                ui.error = e.message ?: getString(R.string.error_generic)
                ui.subtitle = SIGN_IN
                ui.connecting = false
            }
        }
    }

    private fun autoFind(preferred: String?) {
        if (ui.finding) return
        ui.finding = true
        ui.found = null
        ui.showUrl = false
        ui.error = null
        ui.subtitle = LOOKING
        scope.launch {
            val found = withContext(Dispatchers.IO) {
                Discovery.resolveReachableBase(preferred)
                    ?: Discovery.findServers(this@PairingActivity, preferred).firstOrNull()
            }
            ui.finding = false
            if (found == null) {
                ui.subtitle = SIGN_IN
                ui.showUrl = true
                if (ui.url.isBlank()) ui.url = "http://10.0.2.2:3001"
                ui.error = "No server found. Enter its address."
            } else {
                ui.url = found
                ui.found = found
                ui.subtitle = FOUND
            }
        }
    }
}

@Composable
private fun PairingScreen(ui: PairingState, onChange: () -> Unit, onConnect: () -> Unit, onFind: () -> Unit) {
    val codeFocus = remember { FocusRequester() }
    LaunchedEffect(ui.finding) { if (!ui.finding) runCatching { codeFocus.requestFocus() } }
    Box(Modifier.fillMaxSize().background(PbColors.ground), contentAlignment = Alignment.Center) {
        Column(Modifier.width(520.dp), horizontalAlignment = Alignment.CenterHorizontally) {
            BasicText(
                "PEANUTBUTTER",
                style = PbType.label.copy(color = PbColors.brand, letterSpacing = 2.4.sp, fontWeight = FontWeight.W800, fontSize = 13.sp),
            )
            Spacer(Modifier.height(10.dp))
            BasicText("Pair this device", style = PbType.h1)
            Spacer(Modifier.height(8.dp))
            BasicText(ui.subtitle, style = PbType.body.copy(color = PbColors.textMuted, textAlign = TextAlign.Center, lineHeight = 23.sp))
            Spacer(Modifier.height(28.dp))
            if (ui.finding) {
                Spinner()
                Spacer(Modifier.height(20.dp))
            } else {
                val found = ui.found
                if (found != null && !ui.showUrl) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier
                            .fillMaxWidth()
                            .background(Color(0xFF121218), RoundedCornerShape(12.dp))
                            .padding(start = 16.dp, end = 8.dp, top = 8.dp, bottom = 8.dp),
                    ) {
                        Icon(Icons.Rounded.Dns, null, tint = PbColors.textMuted, modifier = Modifier.size(22.dp))
                        Spacer(Modifier.width(10.dp))
                        BasicText(found, maxLines = 1, overflow = TextOverflow.Ellipsis, style = PbType.body.copy(color = PbColors.textMuted), modifier = Modifier.weight(1f))
                        PbButton("Change", null, primary = false, onClick = onChange, compact = true)
                    }
                    Spacer(Modifier.height(12.dp))
                }
                if (ui.showUrl) {
                    PbTextField(ui.url, { ui.url = it }, "Server address (e.g. http://10.0.0.110:3001)", Modifier.fillMaxWidth(), keyboardType = KeyboardType.Uri)
                    Spacer(Modifier.height(12.dp))
                }
                PbTextField(
                    ui.code, { ui.code = it.filter(Char::isLetterOrDigit).take(12) }, "6-digit pairing code",
                    Modifier.fillMaxWidth().focusRequester(codeFocus), keyboardType = KeyboardType.Number, onDone = onConnect,
                )
                Spacer(Modifier.height(20.dp))
                PbButton(if (ui.connecting) "Connecting…" else "Connect", null, primary = true, onClick = onConnect, modifier = Modifier.fillMaxWidth())
                Spacer(Modifier.height(10.dp))
                PbButton("Find on this network", null, primary = false, onClick = onFind, modifier = Modifier.fillMaxWidth())
            }
            ui.error?.let {
                Spacer(Modifier.height(16.dp))
                BasicText(it, style = PbType.body.copy(color = PbColors.bad, textAlign = TextAlign.Center))
            }
        }
    }
}

@Composable
private fun Spinner() {
    val t = androidx.compose.animation.core.rememberInfiniteTransition(label = "spin")
    val angle by t.animateFloat(
        0f, 360f,
        androidx.compose.animation.core.infiniteRepeatable(
            androidx.compose.animation.core.tween(900, easing = androidx.compose.animation.core.LinearEasing),
        ),
        label = "a",
    )
    androidx.compose.foundation.Canvas(Modifier.size(30.dp)) {
        drawArc(
            PbColors.primary, angle, 270f, false,
            style = androidx.compose.ui.graphics.drawscope.Stroke(2.5.dp.toPx(), cap = androidx.compose.ui.graphics.StrokeCap.Round),
        )
    }
}

/** Where to go once paired: the TV app's home. */
internal fun homeIntent(context: android.content.Context): Intent =
    Intent(context, MainActivity::class.java)
