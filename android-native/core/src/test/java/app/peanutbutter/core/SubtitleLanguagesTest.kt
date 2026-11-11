package app.peanutbutter.core

import org.junit.Assert.assertEquals
import org.junit.Test

class SubtitleLanguagesTest {
    @Test
    fun englishIsAlwaysOfferedAfterTheChosenLanguages() {
        assertEquals(listOf("hi", "en"), ContentLanguages.subtitleLanguages(setOf("hi")))
        assertEquals(listOf("hi", "en"), ContentLanguages.subtitleLanguages(listOf("hi", "en")))
        assertEquals(listOf("en", "ja"), ContentLanguages.subtitleLanguages(listOf("EN", "ja")))
        assertEquals(listOf("en"), ContentLanguages.subtitleLanguages(emptySet()))
        assertEquals(listOf("en"), ContentLanguages.subtitleLanguages(listOf("all")))
    }
}
