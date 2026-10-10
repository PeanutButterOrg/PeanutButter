package app.peanutbutter.phone

import android.app.Application
import android.content.Intent
import android.os.Handler
import android.os.Looper
import app.peanutbutter.core.ApiClient
import app.peanutbutter.core.AppExitCleanup
import app.peanutbutter.core.AuthEvents
import app.peanutbutter.core.LocalTorrentEngine
import app.peanutbutter.core.SessionStore
import app.peanutbutter.phone.ui.PairingActivity

class PhoneApp : Application() {
    lateinit var session: SessionStore
        private set
    lateinit var api: ApiClient
        private set

    @Volatile
    var activeStreamSession: String? = null

    private val mainHandler = Handler(Looper.getMainLooper())

    override fun onCreate() {
        super.onCreate()
        session = SessionStore(this)
        api = ApiClient(session)
        AuthEvents.setUnpairedListener {
            mainHandler.post { openPairingScreen() }
        }
        LocalTorrentEngine.ensureInit(this)
        AppExitCleanup.install(this, shouldWipe = { session.clearCacheOnExit }) { deleteFiles ->
            activeStreamSession = null
            runCatching { LocalTorrentEngine.stop(deleteFiles = deleteFiles) }
        }
    }

    private fun openPairingScreen() {
        val intent = Intent(this, PairingActivity::class.java)
            .addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_CLEAR_TASK or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP,
            )
        startActivity(intent)
    }
}

fun Application.asPhone(): PhoneApp = this as PhoneApp
