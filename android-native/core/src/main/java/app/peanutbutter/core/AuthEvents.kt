package app.peanutbutter.core

import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/**
 * Pairing/auth signals shared by TV and phone.
 *
 * GraphQL 401/403 clears the device token. Navigation to the pairing screen is
 * deferred while a player session is active so local/torrent playback is not
 * yanked mid-stream.
 */
object AuthEvents {
    /**
     * Open player screens. A counter, not a flag: on "Play next" the new player
     * starts before the old one is destroyed, and a plain boolean was reset to
     * false while the new episode was playing.
     */
    private val activePlayers = AtomicInteger(0)

    val playbackActive: Boolean
        get() = activePlayers.get() > 0

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

    /** Call when a player screen opens (onCreate). */
    fun onPlaybackStarted() {
        activePlayers.incrementAndGet()
    }

    /** Call when the player finishes (onDestroy). */
    fun onPlaybackEnded() {
        val left = activePlayers.updateAndGet { (it - 1).coerceAtLeast(0) }
        if (left > 0) return
        if (pendingUnpair.getAndSet(false)) {
            dispatchUnpair()
        }
    }

    fun resetForTests() {
        activePlayers.set(0)
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

    /**
     * Fallback for GraphQL error text. Real auth failures arrive as HTTP 401
     * (handled by status in ApiClient); this only matches the server's own auth
     * messages. Generic words like "unauthorized" also appear in upstream
     * Jackett / OpenSubtitles errors and used to wipe a valid pairing.
     */
    fun looksUnauthorized(message: String?): Boolean {
        val m = message?.lowercase().orEmpty()
        if (m.isEmpty()) return false
        return m.contains("invalid api token") ||
            m.contains("missing api token") ||
            m.contains("device isn't paired") ||
            m.contains("device isn’t paired")
    }
}

class UnauthorizedException(message: String) : ApiException(message)
