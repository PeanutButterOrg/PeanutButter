package app.peanutbutter.tv.ui

import android.content.Intent
import android.os.Bundle
import android.view.View
import android.widget.Button
import android.widget.EditText
import android.widget.ProgressBar
import android.widget.TextView
import android.widget.Toast
import androidx.fragment.app.FragmentActivity
import app.peanutbutter.core.Discovery
import app.peanutbutter.tv.R
import app.peanutbutter.tv.asTv
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class PairingActivity : FragmentActivity() {
    private val scope = CoroutineScope(Dispatchers.Main + Job())
    private var finding = false
    private var connecting = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_pairing)
        val app = application.asTv()
        val token = findViewById<EditText>(R.id.token)
        val url = findViewById<EditText>(R.id.url)
        val status = findViewById<TextView>(R.id.status)
        val subtitle = findViewById<TextView>(R.id.subtitle)
        val progress = findViewById<ProgressBar>(R.id.progress)
        val foundRow = findViewById<View>(R.id.found_row)
        val foundLabel = findViewById<TextView>(R.id.found_label)
        val connect = findViewById<Button>(R.id.connect)
        val find = findViewById<Button>(R.id.find)
        val change = findViewById<Button>(R.id.change)
        token.closeKeyboardOnIme()
        url.closeKeyboardOnIme()

        val saved = app.session.serverUrl
        if (saved.isNotBlank()) {
            url.setText(saved)
            foundLabel.text = saved
            foundRow.visibility = View.VISIBLE
            subtitle.text = "Server found on this network. Enter the 6-digit pairing code from the console."
        } else {
            autoFind(app.session.serverUrl, subtitle, progress, foundRow, foundLabel, url, status, find)
        }

        change.setOnClickListener {
            foundRow.visibility = View.GONE
            url.visibility = View.VISIBLE
            if (url.text.isNullOrBlank()) url.setText("http://10.0.2.2:3001")
            url.requestFocus()
        }

        find.setOnClickListener {
            autoFind(url.text?.toString(), subtitle, progress, foundRow, foundLabel, url, status, find)
        }

        connect.setOnClickListener {
            if (connecting || finding) return@setOnClickListener
            val code = token.text?.toString().orEmpty()
            var base = url.text?.toString().orEmpty()
                .ifBlank { foundLabel.text?.toString().orEmpty() }
                .ifBlank { app.session.serverUrl }
            if (code.length < 4) {
                Toast.makeText(this, "Enter the pairing code", Toast.LENGTH_SHORT).show()
                return@setOnClickListener
            }
            connecting = true
            connect.isEnabled = false
            status.text = ""
            subtitle.text = "Connecting…"
            scope.launch {
                try {
                    val resolved = withContext(Dispatchers.IO) {
                        Discovery.resolveReachableBase(base)
                    }
                    if (resolved == null) {
                        throw IllegalStateException("Server not reachable. Check URL or Find on this network.")
                    }
                    base = resolved
                    app.session.serverUrl = base
                    app.session.apiToken = code
                    withContext(Dispatchers.IO) {
                        check(app.api.healthOk()) { "Server not reachable at $base" }
                        app.api.serverInfo()
                    }
                    startActivity(Intent(this@PairingActivity, MainActivity::class.java))
                    finish()
                } catch (e: Exception) {
                    status.text = e.message ?: getString(R.string.error_generic)
                    subtitle.text = "Sign in on the server console, create a 6-digit code, then type it here."
                    connect.isEnabled = true
                    connecting = false
                }
            }
        }
    }

    private fun autoFind(
        preferred: String?,
        subtitle: TextView,
        progress: ProgressBar,
        foundRow: View,
        foundLabel: TextView,
        url: EditText,
        status: TextView,
        find: Button,
    ) {
        if (finding) return
        finding = true
        find.isEnabled = false
        progress.visibility = View.VISIBLE
        foundRow.visibility = View.GONE
        url.visibility = View.GONE
        status.text = ""
        subtitle.text = "Looking for a catalog server on this network…"
        scope.launch {
            val found = withContext(Dispatchers.IO) {
                Discovery.resolveReachableBase(preferred)
                    ?: Discovery.findServers(this@PairingActivity, preferred).firstOrNull()
            }
            finding = false
            find.isEnabled = true
            progress.visibility = View.GONE
            if (found == null) {
                subtitle.text = "Sign in on the server console, create a 6-digit code, then type it here."
                url.visibility = View.VISIBLE
                if (url.text.isNullOrBlank()) url.setText("http://10.0.2.2:3001")
                status.text = "No server found — enter URL manually"
            } else {
                url.setText(found)
                foundLabel.text = found
                foundRow.visibility = View.VISIBLE
                subtitle.text = "Server found on this network. Enter the 6-digit pairing code from the console."
            }
        }
    }
}
