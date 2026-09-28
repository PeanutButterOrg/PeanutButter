package app.peanutbutter.phone.ui

import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.view.View
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import android.widget.ProgressBar
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import app.peanutbutter.core.Discovery
import app.peanutbutter.phone.R
import app.peanutbutter.phone.asPhone
import com.google.android.material.button.MaterialButton
import com.google.android.material.textfield.TextInputEditText
import com.google.android.material.textfield.TextInputLayout
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class PairingActivity : AppCompatActivity() {
    private val scope = CoroutineScope(Dispatchers.Main + Job())
    private var finding = false
    private var connecting = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_pairing)
        val app = application.asPhone()
        val token = findViewById<TextInputEditText>(R.id.token)
        val url = findViewById<TextInputEditText>(R.id.url)
        val urlLayout = findViewById<TextInputLayout>(R.id.url_layout)
        val status = findViewById<TextView>(R.id.status)
        val subtitle = findViewById<TextView>(R.id.subtitle)
        val progress = findViewById<ProgressBar>(R.id.progress)
        val foundRow = findViewById<View>(R.id.found_row)
        val foundLabel = findViewById<TextView>(R.id.found_label)
        val connect = findViewById<MaterialButton>(R.id.connect)
        val find = findViewById<MaterialButton>(R.id.find)
        val change = findViewById<MaterialButton>(R.id.change)
        listOf(token, url).forEach { field ->
            field.setOnEditorActionListener { v, actionId, _ ->
                if (actionId == EditorInfo.IME_ACTION_DONE || actionId == EditorInfo.IME_ACTION_GO) {
                    val imm = getSystemService(Context.INPUT_METHOD_SERVICE) as? InputMethodManager
                    imm?.hideSoftInputFromWindow(v.windowToken, 0)
                    true
                } else {
                    false
                }
            }
        }

        val saved = app.session.serverUrl
        if (saved.isNotBlank()) {
            url.setText(saved)
            foundLabel.text = saved
            foundRow.visibility = View.VISIBLE
            subtitle.text = "Server found on this network. Enter the 6-digit pairing code from the console."
        } else {
            autoFind(null, subtitle, progress, foundRow, foundLabel, url, urlLayout, status, find)
        }

        change.setOnClickListener {
            foundRow.visibility = View.GONE
            urlLayout.visibility = View.VISIBLE
            if (url.text.isNullOrBlank()) url.setText("http://10.0.2.2:3001")
        }

        find.setOnClickListener {
            autoFind(url.text?.toString(), subtitle, progress, foundRow, foundLabel, url, urlLayout, status, find)
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
                    } ?: throw IllegalStateException("Server not reachable")
                    base = resolved
                    app.session.serverUrl = base
                    app.session.apiToken = code
                    withContext(Dispatchers.IO) {
                        check(app.api.healthOk()) { "Unreachable at $base" }
                        app.api.serverInfo()
                    }
                    startActivity(Intent(this@PairingActivity, HomeActivity::class.java))
                    finish()
                } catch (e: Exception) {
                    status.text = e.message
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
        url: TextInputEditText,
        urlLayout: TextInputLayout,
        status: TextView,
        find: MaterialButton,
    ) {
        if (finding) return
        finding = true
        find.isEnabled = false
        progress.visibility = View.VISIBLE
        foundRow.visibility = View.GONE
        urlLayout.visibility = View.GONE
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
                urlLayout.visibility = View.VISIBLE
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
