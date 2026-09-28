package app.peanutbutter.phone

import android.app.Application
import app.peanutbutter.core.ApiClient
import app.peanutbutter.core.AppExitCleanup
import app.peanutbutter.core.SessionStore

class PhoneApp : Application() {
    lateinit var session: SessionStore
        private set
    lateinit var api: ApiClient
        private set

    @Volatile
    var activeStreamSession: String? = null

    override fun onCreate() {
        super.onCreate()
        session = SessionStore(this)
        api = ApiClient(session)
        AppExitCleanup.install(this) {
            val sid = activeStreamSession
            activeStreamSession = null
            if (!sid.isNullOrBlank()) {
                Thread {
                    runCatching { kotlinx.coroutines.runBlocking { api.stopStream(sid) } }
                }.start()
            }
        }
    }
}

fun Application.asPhone(): PhoneApp = this as PhoneApp
