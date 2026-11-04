package app.peanutbutter.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MediaSegmentTest {
    private val episode = 22 * 60 * 1000

    private fun intro(end: Int?) = MediaSegment("INTRO", "Skip Intro", 10_000, end)

    @Test
    fun skipGoesAwayWhenTheIntroEnds() {
        val s = intro(40_000)
        assertTrue(s.contains(20_000, episode))
        assertFalse(s.contains(40_000, episode))
        assertFalse(s.contains(60_000, episode))
    }

    @Test
    fun aMissingEndTimeDoesNotKeepSkipUpForTheWholeEpisode() {
        val s = intro(null)
        assertTrue(s.contains(60_000, episode))
        assertFalse(s.contains(100_000, episode))
        assertFalse(s.contains(episode - 5_000, episode))
    }

    @Test
    fun anAbsurdEndTimeIsTreatedAsMissing() {
        val tooLong = intro(15 * 60 * 1000)
        assertFalse(tooLong.contains(5 * 60 * 1000, episode))
        val atTheEnd = intro(episode - 1_000)
        assertFalse(atTheEnd.contains(5 * 60 * 1000, episode))
    }

    @Test
    fun skippingLandsWhereTheButtonStopsShowing() {
        for (s in listOf(intro(40_000), intro(null), intro(15 * 60 * 1000))) {
            assertFalse(s.contains(s.skipTargetMs(episode), episode))
        }
    }

    @Test
    fun creditsStillRunToTheEnd() {
        val credits = MediaSegment("CREDITS", "Credits", 20 * 60 * 1000, null)
        assertTrue(credits.contains(episode - 1_000, episode))
    }
}
