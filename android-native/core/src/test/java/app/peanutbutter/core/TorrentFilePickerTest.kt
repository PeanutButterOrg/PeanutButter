package app.peanutbutter.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class TorrentFilePickerTest {
    private val gb = 1024L * 1024 * 1024
    private val mb = 1024L * 1024

    private fun files(vararg p: Pair<String, Long>) =
        p.mapIndexed { i, (path, size) -> TorrentFilePicker.Entry(i, path, size) }

    private fun pick(f: List<TorrentFilePicker.Entry>, s: Int?, e: Int?, hint: Int? = null) =
        TorrentFilePicker.pick(f, s, e, hint)?.let { f[it].path }

    private val pack = files(
        "Show S01/Show.S01E01.1080p.mkv" to 2 * gb,
        "Show S01/Show.S01E02.1080p.mkv" to 2 * gb,
        "Show S01/Show.S01E07.1080p.mkv" to 1 * gb,
        "Show S01/Show.S01E10.1080p.mkv" to 3 * gb,
        "Show S01/Sample/Show.S01E07.sample.mkv" to 40 * mb,
        "Show S01/Show.nfo" to 1_000,
    )

    @Test fun sxxeyy() {
        assertEquals("Show S01/Show.S01E07.1080p.mkv", pick(pack, 1, 7))
        assertEquals("Show S01/Show.S01E01.1080p.mkv", pick(pack, 1, 1))
        // E1 must not match E10, nor E10 match E1.
        assertEquals("Show S01/Show.S01E10.1080p.mkv", pick(pack, 1, 10))
    }

    @Test fun unpaddedAndSpaced() {
        val f = files("s1e5.mkv" to gb, "s1e6.mkv" to 2 * gb, "S01 E07 x.mkv" to gb, "1x08 y.mkv" to gb)
        assertEquals("s1e5.mkv", pick(f, 1, 5))
        assertEquals("S01 E07 x.mkv", pick(f, 1, 7))
        assertEquals("1x08 y.mkv", pick(f, 1, 8))
    }

    @Test fun completeSeriesPicksTheRightSeason() {
        val f = files(
            "Show/Season 1/Show S01E03.mkv" to gb,
            "Show/Season 2/Show S02E03.mkv" to 2 * gb,
            "Show/Season 3/Show S03E03.mkv" to 3 * gb,
        )
        assertEquals("Show/Season 2/Show S02E03.mkv", pick(f, 2, 3))
    }

    @Test fun seasonFolderWithBareNumbers() {
        val f = files(
            "Show/Season 1/03 - Title.mkv" to gb,
            "Show/Season 2/03 - Other.mkv" to 2 * gb,
            "Show/Season 2/04 - Next.mkv" to 3 * gb,
        )
        assertEquals("Show/Season 2/03 - Other.mkv", pick(f, 2, 3))
    }

    @Test fun animeStyle() {
        val f = files(
            "[Grp] Show - 06 [1080p].mkv" to gb,
            "[Grp] Show - 07 [1080p].mkv" to gb,
            "[Grp] Show - 17 [1080p].mkv" to 2 * gb,
        )
        assertEquals("[Grp] Show - 07 [1080p].mkv", pick(f, 1, 7))
    }

    @Test fun multiEpisodeFile() {
        val f = files("Show.S01E01E02.mkv" to 2 * gb, "Show.S01E03.mkv" to gb)
        assertEquals("Show.S01E01E02.mkv", pick(f, 1, 2))
        val g = files("Show.S01E01-E03.mkv" to 2 * gb, "Show.S01E04.mkv" to gb)
        assertEquals("Show.S01E01-E03.mkv", pick(g, 1, 2))
    }

    @Test fun movieSkipsExtrasAndSamples() {
        val f = files(
            "Movie (2020)/Featurettes/Making Of.mkv" to 3 * gb,
            "Movie (2020)/Movie.2020.1080p.mkv" to 2 * gb,
            "Movie (2020)/Movie.2020.sample.mkv" to 50 * mb,
            "Movie (2020)/Trailer.mp4" to 100 * mb,
        )
        assertEquals("Movie (2020)/Movie.2020.1080p.mkv", pick(f, null, null))
    }

    @Test fun addOnHintWinsUnlessItNamesAnotherEpisode() {
        assertEquals("Show S01/Show.S01E02.1080p.mkv", pick(pack, null, null, hint = 1))
        assertEquals("Show S01/Show.S01E07.1080p.mkv", pick(pack, 1, 7, hint = 2))
        // Hint points at E10 while E7 is wanted: the name wins.
        assertEquals("Show S01/Show.S01E07.1080p.mkv", pick(pack, 1, 7, hint = 3))
    }

    @Test fun audioChannelsArentEpisodes() {
        val f = files("Show.S01.DDP5.1/Show.Ep01.mkv" to gb, "Show.S01.DDP5.1/Show.Ep05.mkv" to gb)
        assertEquals("Show.S01.DDP5.1/Show.Ep05.mkv", pick(f, 1, 5))
        assertEquals("Show.S01.DDP5.1/Show.Ep01.mkv", pick(f, 1, 1))
    }

    @Test fun selectedIndexFromMagnet() {
        assertEquals(3, TorrentFilePicker.selectedIndex("magnet:?xt=urn:btih:abc&dn=x&so=3"))
        assertNull(TorrentFilePicker.selectedIndex("magnet:?xt=urn:btih:abc&dn=x"))
        assertEquals(
            "magnet:?xt=urn:btih:abc&dn=x&tr=t",
            TorrentFilePicker.withoutSelection("magnet:?xt=urn:btih:abc&dn=x&so=3&tr=t"),
        )
    }

    private fun season(n: Int, titles: List<String>) = Season(
        id = "s$n",
        seasonNumber = n,
        episodes = titles.mapIndexed { i, t -> Episode(id = "s${n}e${i + 1}", episodeNumber = i + 1, name = t) },
    )

    @Test fun samuraiJackNumbering() {
        // Catalog (air order) vs the show's own numerals that releases use.
        val s1 = season(1, listOf("I", "II", "III", "IV", "VII", "V", "IX", "X", "VIII", "XI", "VI", "XII", "XIII"))
        val s2 = season(2, listOf("XIV", "XV", "XVI", "XVII", "XVIII", "XIX", "XX", "XXI", "XXII", "XXIII", "XXIV", "XXV", "XXVI"))
        val seasons = listOf(s1, s2)
        assertEquals(9, TorrentFilePicker.releaseEpisode(seasons, 1, 7))
        assertEquals(7, TorrentFilePicker.releaseEpisode(seasons, 1, 5))
        assertNull(TorrentFilePicker.releaseEpisode(seasons, 1, 1))
        assertNull(TorrentFilePicker.releaseEpisode(seasons, 2, 1))
    }

    @Test fun normalTitlesDontChangeTheNumber() {
        val s = season(1, listOf("Pilot", "Civil War", "Mild", "X", "Chapter Two"))
        assertNull(TorrentFilePicker.releaseEpisode(listOf(s), 1, 4))
        val mando = listOf(
            season(1, (1..8).map { "Chapter $it: Title" }),
            season(2, (9..16).map { "Chapter $it: Title" }),
        )
        assertNull(TorrentFilePicker.releaseEpisode(mando, 2, 1))
    }
}
