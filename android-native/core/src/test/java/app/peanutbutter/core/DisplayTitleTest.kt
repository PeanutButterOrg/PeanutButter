package app.peanutbutter.core

import org.junit.Assert.assertEquals
import org.junit.Test

class DisplayTitleTest {
    @Test
    fun showsTheEnglishTitleNotTheOriginalScript() {
        val item = TitleItem(id = "t", kind = "MOVIE", title = "Pathaan", originalTitle = "पठान")
        assertEquals("Pathaan", item.displayTitle)
    }

    @Test
    fun fallsBackToTheOriginalTitleWhenThereIsNoOther() {
        val item = TitleItem(id = "t", kind = "MOVIE", title = " ", originalTitle = "Amélie")
        assertEquals("Amélie", item.displayTitle)
    }
}
