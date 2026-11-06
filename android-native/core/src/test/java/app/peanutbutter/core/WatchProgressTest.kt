package app.peanutbutter.core

import org.junit.Assert.assertEquals
import org.junit.Test

class WatchProgressTest {
    private fun title(
        position: Long = 0,
        duration: Long = 0,
        percent: Double = 0.0,
        watched: Boolean = false,
    ) = TitleItem(
        id = "t",
        title = "Show",
        kind = "SERIES",
        positionMs = position,
        durationMs = duration,
        progressPercent = percent,
        watched = watched,
    )

    @Test
    fun seriesCardShowsTheSeasonNotThePlayingEpisode() {
        // 90% through an episode, but only 15% of the season.
        val item = title(position = 2_700_000, duration = 3_000_000, percent = 0.15)
        assertEquals(0.15, item.watchProgress, 1e-9)
    }

    @Test
    fun finishedEpisodeWithNoResumePositionKeepsItsBar() {
        assertEquals(0.3, title(percent = 0.3).watchProgress, 1e-9)
    }

    @Test
    fun tinyProgressStaysVisible() {
        assertEquals(0.02, title(percent = 0.001).watchProgress, 1e-9)
    }

    @Test
    fun fallsBackToPositionWithoutAServerFigure() {
        assertEquals(0.5, title(position = 5_000, duration = 10_000).watchProgress, 1e-9)
    }

    @Test
    fun watchedTitlesShowNoBar() {
        assertEquals(0.0, title(percent = 1.0, watched = true).watchProgress, 1e-9)
    }
}
