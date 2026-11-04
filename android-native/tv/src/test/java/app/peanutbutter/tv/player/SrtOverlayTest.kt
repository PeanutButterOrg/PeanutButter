package app.peanutbutter.tv.player

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class SrtOverlayTest {
    private val srt = "1\n00:00:01,000 --> 00:00:02,500\nHello\n\n2\n00:00:03,000 --> 00:00:04,000\n<i>World</i>\n"

    @Test
    fun parsesCuesAndStripsTags() {
        val cues = SrtOverlay.parse(srt)
        assertEquals(2, cues.size)
        assertEquals(1_000L, cues[0].startMs)
        assertEquals(2_500L, cues[0].endMs)
        assertEquals("World", cues[1].text)
    }

    @Test
    fun aByteOrderMarkDoesNotLoseTheFirstCue() {
        assertEquals(2, SrtOverlay.parse("\uFEFF" + srt).size)
    }

    @Test
    fun parsesWebVttAndWindowsLineEndings() {
        val vtt = "WEBVTT\r\n\r\n00:01.000 --> 00:02.000\r\nHi\r\n"
        assertEquals("Hi", SrtOverlay.parse(vtt).single().text)
    }

    @Test
    fun rubbishGivesNoCues() {
        assertTrue(SrtOverlay.parse("not a subtitle file").isEmpty())
    }
}
