package app.peanutbutter.core

import java.util.concurrent.atomic.AtomicBoolean

/**
 * Pairing/auth signals shared by TV and phone.
 *
 * GraphQL 401/403 clears the device token. Navigation to the pairing screen is
 * deferred while a player session is active so local/torrent playback is not
 * yanked mid-stream.
 */
object AuthEvents {
    @Volatile
    var playbackActive: Boolean = false

    private val pendingUnpair = AtomicBoolean(false)
    private val dispatched = AtomicBoolean(false)

    @Volatile
    private var onUnpaired: (() -> Unit)? = null

    fun setUnpairedListener(listener: (() -> Unit)?) {
        onUnpaired = listener
    }

    /** Call from [ApiClient] when the server rejects the pairing token. */
    fun noteUnauthorized(session: SessionStore) {
        if (session.apiToken.isBlank()) return
        session.clearToken()
        if (playbackActive) {
            pendingUnpair.set(true)
            return
        }
        dispatchUnpair()
    }

    /** Call when the player finishes (onDestroy). */
    fun onPlaybackEnded() {
        playbackActive = false
        if (pendingUnpair.getAndSet(false)) {
            dispatchUnpair()
        }
    }

    fun resetForTests() {
        playbackActive = false
        pendingUnpair.set(false)
        dispatched.set(false)
        onUnpaired = null
    }

    private fun dispatchUnpair() {
        if (!dispatched.compareAndSet(false, true)) return
        try {
            onUnpaired?.invoke()
        } finally {
            // Allow a future re-pair → revoke cycle in the same process.
            dispatched.set(false)
        }
    }

    fun looksUnauthorized(message: String?): Boolean {
        val m = message?.lowercase().orEmpty()
        if (m.isEmpty()) return false
        return m.contains("unauthorized") ||
            m.contains("invalid api token") ||
            m.contains("missing api token") ||
            m.contains("isn't paired") ||
            m.contains("isn’t paired") ||
            m.contains("not paired") ||
            m.contains("pairing code rejected") ||
            m.contains("pairing screen")
    }
}

class UnauthorizedException(message: String) : ApiException(message)
