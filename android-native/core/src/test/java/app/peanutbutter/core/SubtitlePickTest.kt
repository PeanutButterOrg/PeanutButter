package app.peanutbutter.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class SubtitlePickTest {
    private fun sub(id: String, lang: String, content: String = "1\n00:00:01,000 --> 00:00:02,000\nHi") =
        FetchedSubtitle(id = id, language = lang, label = lang, content = content)

    @Test
    fun picksTheRequestedLanguageNotTheOldestRow() {
        // Hindi was downloaded first; the reply lists it before English.
        val rows = listOf(sub("1", "hi"), sub("2", "en"))
        assertEquals("2", FetchedSubtitle.pick(rows, "en")?.id)
        assertEquals("1", FetchedSubtitle.pick(rows, "hi")?.id)
    }

    @Test
    fun noRowInThatLanguageMeansNone() {
        assertNull(FetchedSubtitle.pick(listOf(sub("1", "hi")), "en"))
    }

    @Test
    fun skipsRowsWithoutCues() {
        val rows = listOf(sub("1", "en", content = "not a subtitle"), sub("2", "EN"))
        assertEquals("2", FetchedSubtitle.pick(rows, "en")?.id)
    }
}
