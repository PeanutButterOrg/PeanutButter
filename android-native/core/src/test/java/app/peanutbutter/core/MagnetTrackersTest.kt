package app.peanutbutter.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class MagnetTrackersTest {
    private val base = "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&dn=x"
    private fun count(m: String) = Regex("[?&]tr=").findAll(m).count()

    @Test
    fun serverTrackersAreAddedEvenWhenTheMagnetHasSome() {
        // It used to add nothing once a magnet had 6 trackers (often dead ones).
        val six = base + (1..6).joinToString("") { "&tr=udp%3A%2F%2Fold$it%3A1" }
        val out = withTrackers(six, listOf("udp://live:1337/announce"), 20)
        assertTrue(out.contains("udp%3A%2F%2Flive%3A1337%2Fannounce"))
        assertEquals(7, count(out))
    }

    @Test
    fun capsTheTotalAndSkipsDuplicates() {
        val many = (1..40).map { "udp://t$it:1/announce" }
        val out = withTrackers(base + "&tr=udp%3A%2F%2Ft1%3A1%2Fannounce", many, 20)
        assertEquals(20, count(out))
    }

    @Test
    fun leavesNonMagnetsAlone() {
        assertEquals("http://x/y.torrent", withTrackers("http://x/y.torrent", listOf("udp://a:1"), 20))
    }
}
