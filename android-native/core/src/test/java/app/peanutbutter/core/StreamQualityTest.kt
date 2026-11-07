package app.peanutbutter.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class StreamQualityTest {
    private fun src(id: String, score: Int, kind: String = "torrent", url: String = "") = StreamSource(
        id = id,
        title = id,
        magnet = if (kind == "torrent") "magnet:?xt=urn:btih:$id" else "",
        seeders = 0,
        peers = 0,
        size = "",
        tracker = "",
        health = "unknown",
        kind = kind,
        url = url,
        score = score,
    )

    @Test
    fun mergedLanguageListsFollowTheServerScore() {
        val english = listOf(src("en-a", 900), src("en-b", 400))
        val hindi = listOf(src("hi-a", 1000), src("hi-b", 400))
        val ranked = StreamQuality.rankSources(english + hindi)
        assertEquals(listOf("hi-a", "en-a", "en-b", "hi-b"), ranked.map { it.id })
    }

    @Test
    fun directLinksAreKeyedByUrl() {
        val http = src("h", 500, kind = "http", url = "https://cdn.example/a.mkv")
        assertTrue(http.isHttp)
        assertEquals("https://cdn.example/a.mkv", http.key)
        val torrent = src("t", 500)
        assertFalse(torrent.isHttp)
        assertEquals("magnet:?xt=urn:btih:t", torrent.key)
        // "http" without a URL is not playable as a link.
        assertFalse(src("x", 1, kind = "http").isHttp)
    }

    @Test
    fun serviceBadgesUseTheSharedTable() {
        assertEquals("N", ServiceBadges.of(ServiceTag("netflix", "Netflix")).label)
        assertEquals("D+", ServiceBadges.of(ServiceTag("disney", "Disney+")).label)
        // Unknown list: first letters of its name.
        assertEquals("TOP", ServiceBadges.of(ServiceTag("toppicks", "Top Picks")).label)
    }
}
