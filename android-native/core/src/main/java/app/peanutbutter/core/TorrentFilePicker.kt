package app.peanutbutter.core

/**
 * Picks the one video file to stream from a torrent: the requested episode
 * in a season pack, the feature (not extras or samples) in a movie folder.
 * Same rules as the desktop picker (frontend/lib/torrent_file_picker.dart).
 */
object TorrentFilePicker {
    data class Entry(val index: Int, val path: String, val size: Long)

    private val videoExt = setOf(
        "mkv", "mp4", "m4v", "mov", "avi", "webm", "ts", "m2ts", "mts",
        "mpeg", "mpg", "vob", "flv", "wmv", "ogv", "3gp",
    )

    /** Folder and file words that mark bonus material, not the feature. */
    private val junkWords = listOf(
        "sample", "trailer", "teaser", "extras", "extra", "featurette", "featurettes",
        "bonus", "behind the scenes", "behindthescenes", "deleted scenes", "deleted scene",
        "interview", "interviews", "making of", "gag reel", "bloopers", "promo", "proof",
        "screens", "short films", "specials", "ncop", "nced", "creditless", "opening", "ending",
    )

    private const val MIN_FEATURE_BYTES = 60L * 1024 * 1024

    /**
     * The episode number releases use, when the catalog orders episodes
     * differently. Some shows title episodes with their own number (Samurai
     * Jack: S01E07 is "IX", S02E01 is "XIV"); releases follow that number,
     * so the catalog's S01E07 file is really "VII". Titles like "IX",
     * "Episode 9" or "Chapter 9: …" give the show's number; it counts across
     * seasons when it is past this season's size.
     * @param earlier episodes in the seasons before this one
     * @return the release episode, or null when the title has no number or it agrees
     */
    fun releaseEpisode(title: String?, episode: Int, earlier: Int, seasonSize: Int): Int? {
        val n = numberInTitle(title) ?: return null
        val inSeason = when {
            seasonSize > 0 && n > seasonSize && n - earlier in 1..seasonSize -> n - earlier
            seasonSize <= 0 || n <= seasonSize -> n
            else -> return null
        }
        return inSeason.takeIf { it != episode }
    }

    /** [releaseEpisode] from the title's catalog seasons. */
    fun releaseEpisode(seasons: List<Season>, season: Int, episode: Int): Int? {
        val ordered = seasons.filter { it.seasonNumber > 0 }.sortedBy { it.seasonNumber }
        val cur = ordered.firstOrNull { it.seasonNumber == season } ?: return null
        val ep = cur.episodes.firstOrNull { it.episodeNumber == episode } ?: return null
        // Only shows that number every episode this way, not one odd title.
        val numbered = cur.episodes.count { numberInTitle(it.name) != null }
        if (numbered * 2 < cur.episodes.size) return null
        fun size(s: Season) = maxOf(s.episodes.size, s.episodeCount ?: 0)
        val earlier = ordered.filter { it.seasonNumber < season }.sumOf { size(it) }
        return releaseEpisode(ep.name, episode, earlier, size(cur))
    }

    private fun numberInTitle(title: String?): Int? {
        val head = title?.trim()?.substringBefore(':')?.trim()?.lowercase() ?: return null
        val m = Regex("""^(?:(?:episode|chapter|ep\.?|part)\s*)?([ivxlcdm]+|\d{1,4})\.?$""").find(head)
            ?: return null
        return m.groupValues[1].toIntOrNull() ?: roman(m.groupValues[1])
    }

    private fun roman(s: String): Int? {
        val v = mapOf('i' to 1, 'v' to 5, 'x' to 10, 'l' to 50, 'c' to 100, 'd' to 500, 'm' to 1000)
        var total = 0
        for (i in s.indices) {
            val cur = v[s[i]] ?: return null
            val next = if (i + 1 < s.length) v[s[i + 1]] ?: return null else 0
            total += if (cur < next) -cur else cur
        }
        // Words made of roman letters ("Civil", "Mild") aren't numerals.
        return total.takeIf { it in 1..399 && toRoman(it) == s }
    }

    private fun toRoman(n: Int): String {
        val parts = listOf(
            100 to "c", 90 to "xc", 50 to "l", 40 to "xl", 10 to "x", 9 to "ix", 5 to "v", 4 to "iv", 1 to "i",
        )
        var rest = n
        val sb = StringBuilder()
        for ((v, r) in parts) while (rest >= v) { sb.append(r); rest -= v }
        return sb.toString()
    }

    fun isVideo(path: String): Boolean =
        path.substringAfterLast('.', "").lowercase() in videoExt

    /** The file a Stremio add-on chose (`so=` in the magnet), if any. */
    fun selectedIndex(magnet: String): Int? {
        val q = magnet.substringAfter('?', "")
        for (part in q.split('&')) {
            if (!part.startsWith("so=")) continue
            // BEP 53 allows lists and ranges; add-ons send one index.
            return part.removePrefix("so=").substringBefore(',').substringBefore('-').toIntOrNull()
        }
        return null
    }

    /**
     * The magnet without `so=`. libtorrent applies it as file priorities on
     * the disk thread after metadata, which can land after (and wipe) the
     * streaming piece priorities; the app selects the file per piece itself.
     */
    fun withoutSelection(magnet: String): String {
        val q = magnet.indexOf('?')
        if (q < 0) return magnet
        val kept = magnet.substring(q + 1).split('&').filterNot { it.startsWith("so=") }
        return magnet.substring(0, q + 1) + kept.joinToString("&")
    }

    fun pick(files: List<Entry>, season: Int?, episode: Int?, hint: Int? = null): Int? {
        val videos = files.filter { isVideo(it.path) }
        if (videos.isEmpty()) return files.maxByOrNull { it.size }?.index
        val wantEpisode = season != null && episode != null && season >= 0 && episode > 0

        hint?.let { h ->
            val f = videos.firstOrNull { it.index == h }
            // Trust the add-on unless the name clearly says another episode.
            if (f != null && !isJunk(f, videos) &&
                (!wantEpisode || episodeTag(f.path).let { it == null || it == season to episode })
            ) {
                return f.index
            }
        }

        val features = videos.filterNot { isJunk(it, videos) }.ifEmpty { videos }
        if (wantEpisode) {
            val best = features
                .map { it to episodeScore(it.path, season!!, episode!!) }
                .filter { it.second > 0 }
                .maxWithOrNull(compareBy<Pair<Entry, Int>> { it.second }.thenBy { it.first.size })
            if (best != null) return best.first.index
        }
        return features.maxByOrNull { it.size }?.index
    }

    private fun words(s: String): String =
        " " + s.lowercase().replace(Regex("[^a-z0-9]+"), " ").trim() + " "

    private fun isJunk(f: Entry, all: List<Entry>): Boolean {
        val dirs = f.path.replace('\\', '/').substringBeforeLast('/', "")
        val name = f.path.replace('\\', '/').substringAfterLast('/')
        val inDir = words(dirs)
        val inName = words(name.substringBeforeLast('.'))
        val hit = junkWords.any { w ->
            val k = " $w "
            inDir.contains(k) || inName.contains(k)
        }
        if (hit) return true
        // A tiny clip next to a full-size file is a sample or an extra.
        val biggest = all.maxOf { it.size }
        return f.size in 1 until MIN_FEATURE_BYTES && biggest >= MIN_FEATURE_BYTES * 4
    }

    private val sxe = Regex("""(?<![a-z0-9])s(\d{1,2})[ ._-]?e(\d{1,3})(?!\d)""")
    private val nxn = Regex("""(?<![a-z0-9])(\d{1,2})x(\d{1,3})(?!\d)""")

    /** Season/episode written in the file name itself (S01E05, 1x05). */
    private fun episodeTag(path: String): Pair<Int, Int>? {
        val name = path.replace('\\', '/').substringAfterLast('/').lowercase()
        sxe.find(name)?.let { return it.groupValues[1].toInt() to it.groupValues[2].toInt() }
        nxn.find(name)?.let { return it.groupValues[1].toInt() to it.groupValues[2].toInt() }
        return null
    }

    /**
     * 0 = not this episode. Higher is surer:
     *  4 S01E05 / 1x05 in the name (also S01E04E05 and S01E04-E05 ranges),
     *  3 "Season 1" folder + E05 / Episode 5 / "05 - " in the name,
     *  2 E05 / Episode 5 alone, 1 a bare " 05 " (anime-style numbering).
     */
    fun episodeScore(path: String, season: Int, episode: Int): Int {
        val norm = path.replace('\\', '/').lowercase()
        val name = norm.substringAfterLast('/')
        val dirs = norm.substringBeforeLast('/', "")

        for (m in sxe.findAll(name)) {
            val s = m.groupValues[1].toInt()
            val e = m.groupValues[2].toInt()
            if (s != season) continue
            if (e == episode) return 4
            // Multi-episode file: S01E04E05 or S01E04-E05 / S01E04-05.
            val rest = name.substring(m.range.last + 1)
            val more = Regex("""^(?:[ ._-]?e|-)(\d{1,3})(?!\d)""").find(rest)
            val e2 = more?.groupValues?.get(1)?.toIntOrNull()
            if (e2 != null && episode in e..e2) return 4
        }
        for (m in nxn.findAll(name)) {
            if (m.groupValues[1].toInt() == season && m.groupValues[2].toInt() == episode) return 4
        }
        // The name names a different episode: not this one.
        if (episodeTag(name) != null) return 0

        val ep = """0*$episode(?!\d)"""
        val explicit = Regex("""(?<![a-z0-9])(?:e|ep|episode)[ ._-]?$ep""").containsMatchIn(name)
        val leading = Regex("""^$ep[ ._-]""").containsMatchIn(name) ||
            Regex("""(?<![a-z0-9])-[ ._]?$ep[ ._\[(-]""").containsMatchIn(name)
        val seasonDir = Regex("""(?<![a-z0-9])(?:season|series|s)[ ._-]?0*$season(?!\d)""")
            .containsMatchIn(dirs)
        val otherSeasonDir = Regex("""(?<![a-z0-9])(?:season|series)[ ._-]?0*(\d+)(?!\d)""")
            .findAll(dirs).any { it.groupValues[1].toInt() != season }
        if (otherSeasonDir && !seasonDir) return 0
        return when {
            (explicit || leading) && seasonDir -> 3
            explicit -> 2
            leading -> 1
            // Not "5.1" audio or "x265": the number stands alone.
            Regex("""(?<![a-z0-9.])$ep(?![a-z0-9.])""").containsMatchIn(name.substringBeforeLast('.')) -> 1
            else -> 0
        }
    }
}
