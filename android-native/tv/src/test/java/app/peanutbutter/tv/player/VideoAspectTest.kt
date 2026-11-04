package app.peanutbutter.tv.player

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

class VideoAspectTest {
    private fun box(mode: String, w: Int = 1920, h: Int = 800) = VideoAspect.target(mode, 1920, 1080, w, h)

    @Test
    fun eachModeGivesItsOwnShapeForAWideFilm() {
        assertEquals(VideoAspect.Box(1920, 800), box("fit"))
        assertEquals(VideoAspect.Box(1920, 1080), box("stretch"))
        assertEquals(VideoAspect.Box(1920, 1080), box("16:9"))
        assertEquals(VideoAspect.Box(1440, 1080), box("4:3"))
        assertEquals(VideoAspect.Box(2592, 1080), box("fill"))
    }

    @Test
    fun switchingModesNeverDependsOnThePreviousOne() {
        val modes = listOf("fit", "original", "fill", "stretch", "16:9", "4:3")
        for (a in modes) for (b in modes) {
            box(a)
            assertEquals("$a then $b", box(b), VideoAspect.target(b, 1920, 1080, 1920, 800))
        }
        assertNotEquals(box("4:3"), box("16:9"))
    }

    @Test
    fun originalNeverScalesUpAndFitsTheScreen() {
        assertEquals(VideoAspect.Box(1280, 720), box("original", 1280, 720))
        assertEquals(VideoAspect.Box(1920, 1080), box("original", 3840, 2160))
    }

    @Test
    fun unknownVideoSizeStillGivesAUsableBox() {
        assertEquals(VideoAspect.Box(1920, 1080), box("fit", 0, 0))
    }
}
