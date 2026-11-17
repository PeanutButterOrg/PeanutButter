package app.peanutbutter.core

import org.junit.Assert.assertEquals
import org.junit.Test

class ReleaseTagsTest {
    @Test
    fun readsResolutionSourceCodecAndAudio() {
        assertEquals(
            ReleaseTags("4K", "Remux", "HEVC", "Atmos"),
            ReleaseTags.parse("Interstellar.2014.2160p.UHD.BluRay.REMUX.HDR.HEVC.Atmos-FGT"),
        )
        assertEquals(
            ReleaseTags("1080", "WEB", "HEVC", "5.1"),
            ReleaseTags.parse("Dune Part Two (2024) [1080p] [WEBRip] [x265] [5.1]"),
        )
        assertEquals(ReleaseTags("720", "HDTV", "H.264", ""), ReleaseTags.parse("The.Office.S02E03.720p.HDTV.x264-LOL"))
        assertEquals(
            ReleaseTags("4K", "DV", "HEVC", "5.1"),
            ReleaseTags.parse("Some Movie DV HDR10 2160p WEB-DL DDP5.1 H.265"),
        )
        assertEquals("", ReleaseTags.parse("Plain name").resolution)
    }
}
