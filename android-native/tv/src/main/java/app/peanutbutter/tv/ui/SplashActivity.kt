package app.peanutbutter.tv.ui

import android.content.Intent
import android.os.Bundle
import androidx.fragment.app.FragmentActivity
import app.peanutbutter.core.Discovery
import app.peanutbutter.tv.asTv
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class SplashActivity : FragmentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val app = application.asTv()
        CoroutineScope(Dispatchers.Main).launch {
            // Refresh saved base if host moved / emulator gateway.
            if (app.session.serverUrl.isNotBlank()) {
                val resolved = withContext(Dispatchers.IO) {
                    Discovery.resolveReachableBase(app.session.serverUrl)
                }
                if (resolved != null) app.session.serverUrl = resolved
            }
            val paired = app.session.isPaired
            val ok = if (paired) {
                withContext(Dispatchers.IO) { runCatching { app.api.healthOk() }.getOrDefault(false) }
            } else {
                false
            }
            if (paired && ok) {
                startActivity(Intent(this@SplashActivity, MainActivity::class.java))
            } else {
                startActivity(Intent(this@SplashActivity, PairingActivity::class.java))
            }
            finish()
        }
    }
}
