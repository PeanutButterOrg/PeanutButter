package app.peanutbutter.phone.ui

import android.content.Intent
import android.os.Bundle
import androidx.appcompat.app.AppCompatActivity
import app.peanutbutter.phone.asPhone
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class SplashActivity : AppCompatActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val app = application.asPhone()
        CoroutineScope(Dispatchers.Main).launch {
            val ok = app.session.isPaired && withContext(Dispatchers.IO) {
                runCatching { app.api.healthOk() }.getOrDefault(false)
            }
            startActivity(
                Intent(
                    this@SplashActivity,
                    if (ok) HomeActivity::class.java else PairingActivity::class.java,
                ),
            )
            finish()
        }
    }
}
