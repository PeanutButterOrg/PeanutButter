package app.peanutbutter.core

data class DisplayScore(
    val source: String,
    val label: String,
    val outOfTen: Double,
    val rtScore: Int? = null,
)

data class TitleItem(
    val id: String,
    val kind: String,
    val title: String,
    val originalTitle: String? = null,
    val synopsis: String? = null,
    val year: Int? = null,
    val runtimeMinutes: Int? = null,
    val posterUrl: String? = null,
    val backdropUrl: String? = null,
    val logoUrl: String? = null,
    val imdbRating: Double? = null,
    val tmdbVoteAverage: Double? = null,
    val rtScore: Int? = null,
    val genres: List<String> = emptyList(),
    val positionMs: Long = 0,
    val durationMs: Long = 0,
    val progressPercent: Double = 0.0,
    val watched: Boolean = false,
    val favorite: Boolean = false,
    val trailerYoutubeKey: String? = null,
    val trailers: List<Trailer> = emptyList(),
    val people: List<Person> = emptyList(),
    val seasons: List<Season> = emptyList(),
    val episodeId: String? = null,
    /** Streaming-service lists it's on (Trending row only). */
    val services: List<ServiceTag> = emptyList(),
) {
    /**
     * Prefer original (usually English) title so UI never switches into
     * localized / logo-branded artwork styles.
     */
    val displayTitle: String
        get() = originalTitle?.takeIf { it.isNotBlank() } ?: title
    /** 0..1 watch progress for poster bars (Flutter _progressOf). */
    val watchProgress: Double
        get() {
            if (watched) return 0.0
            // The server's figure covers the whole season for a series, not the episode
            // playing. Keep a sliver so early progress still shows on the card.
            if (progressPercent > 0.0) return progressPercent.coerceIn(0.02, 1.0)
            if (positionMs > 2000L && durationMs > 0L) {
                return (positionMs.toDouble() / durationMs).coerceIn(0.0, 0.98)
            }
            if (positionMs > 2000L) return 0.08
            return 0.0
        }

    val canResume: Boolean get() = !watched && positionMs > 2000

    /** Flutter playableTrailers — non-mobile, largest first, max 1 for TV. */
    val playableTrailers: List<Trailer>
        get() {
            val list = trailers.filter { !it.isMobileSize }.sortedByDescending { it.size ?: 0 }.toMutableList()
            if (list.isEmpty() && !trailerYoutubeKey.isNullOrBlank()) {
                list.add(
                    Trailer(
                        id = "yt-$trailerYoutubeKey",
                        name = "Trailer",
                        youtubeKey = trailerYoutubeKey!!,
                        site = "YouTube",
                        size = 1080,
                    ),
                )
            }
            return if (list.size <= 1) list else list.take(1)
        }

    /** Mirrors Flutter TitleItem.displayScore. */
    val displayScore: DisplayScore?
        get() {
            if (kind.equals("SERIES", true) || kind.equals("TV", true)) {
                tmdbVoteAverage?.takeIf { it > 0 }?.let {
                    return DisplayScore("TMDB", String.format("%.1f", it), it)
                }
            }
            imdbRating?.takeIf { it > 0 }?.let {
                return DisplayScore("IMDb", String.format("%.1f", it), it)
            }
            rtScore?.takeIf { it > 0 }?.let {
                return DisplayScore("RT", "$it%", it / 10.0, rtScore = it)
            }
            tmdbVoteAverage?.takeIf { it > 0 }?.let {
                return DisplayScore("TMDB", String.format("%.1f", it), it)
            }
            return null
        }
}

data class Trailer(
    val id: String,
    val name: String,
    val youtubeKey: String,
    val site: String = "YouTube",
    val size: Int? = null,
) {
    val isMobileSize: Boolean
        get() {
            if (name.contains("mobile", ignoreCase = true)) return true
            val s = size ?: return false
            return s > 0 && s < 720
        }

    val thumbnailUrl: String get() = "https://img.youtube.com/vi/$youtubeKey/hqdefault.jpg"
    val watchUrl: String get() = "https://www.youtube.com/watch?v=$youtubeKey"
}

data class Person(
    val id: String,
    val name: String,
    val department: String = "cast",
    val character: String? = null,
    val job: String? = null,
    val profileUrl: String? = null,
) {
    val role: String get() = character ?: job.orEmpty()
}

data class Season(
    val id: String,
    val seasonNumber: Int,
    val name: String? = null,
    val overview: String? = null,
    val posterPath: String? = null,
    val airDate: String? = null,
    val episodeCount: Int? = null,
    val episodes: List<Episode> = emptyList(),
) {
    val label: String get() = name?.takeIf { it.isNotBlank() } ?: "Season $seasonNumber"
}

data class Episode(
    val id: String,
    val episodeNumber: Int,
    val name: String? = null,
    val overview: String? = null,
    val stillPath: String? = null,
    val airDate: String? = null,
    val runtime: Int? = null,
    val watched: Boolean = false,
    val positionMs: Long = 0,
    val durationMs: Long = 0,
    val progressPercent: Double = 0.0,
) {
    val titleLabel: String
        get() = name?.takeIf { it.isNotBlank() } ?: "Episode $episodeNumber"

    val watchProgress: Double
        get() {
            if (watched) return 0.0
            if (progressPercent > 0.02) return progressPercent.coerceIn(0.0, 1.0)
            if (positionMs < 2000) return 0.0
            if (durationMs <= 0) return 0.08
            return (positionMs.toDouble() / durationMs).coerceIn(0.0, 1.0)
        }
}

/** Pick resume / next / first playable episode (Flutter seriesPlayTarget). */
fun TitleItem.seriesPlayTarget(): Pair<Season, Episode>? {
    // Prefer regular seasons with episodes; fall back to any season that has eps.
    val preferred = seasons.filter { s ->
        s.seasonNumber > 0 &&
            !(s.name.orEmpty().contains("special", ignoreCase = true)) &&
            s.episodes.isNotEmpty()
    }.sortedBy { it.seasonNumber }
    val pool = preferred.ifEmpty {
        seasons.filter { it.episodes.isNotEmpty() }.sortedBy { it.seasonNumber }
    }
    if (pool.isEmpty()) return null
    val flat = pool.flatMap { s -> TorrentFilePicker.inViewingOrder(seasons, s).map { s to it } }
    if (flat.isEmpty()) return null
    val resumeId = episodeId
    var idx = 0
    if (!resumeId.isNullOrBlank()) {
        val found = flat.indexOfFirst { it.second.id == resumeId }
        if (found >= 0) idx = found
    }
    val current = flat[idx]
    if (current.second.watched) {
        for (i in idx + 1 until flat.size) {
            if (!flat[i].second.watched) return flat[i]
        }
    }
    return current
}

data class MediaSegment(
    val kind: String,
    val label: String,
    val startMs: Int,
    val endMs: Int? = null,
) {
    fun contains(positionMs: Int, durationMs: Int): Boolean {
        val start = startMs.coerceAtLeast(0)
        // Same end as skipping to: with a missing or bad end time Skip Intro used
        // to treat the rest of the episode as intro and never went away.
        val end = openingEnd(durationMs) ?: endMs ?: if (durationMs > 0) durationMs else Int.MAX_VALUE / 2
        val activeEnd = if (end > start + 400) end - 250 else end
        return positionMs >= start && positionMs < activeEnd
    }

    /**
     * Where an intro / recap really ends: 90 s from its start when the end time
     * is missing or can't be right (most of the episode, or the end of the file).
     * Null for other segments.
     */
    private fun openingEnd(durationMs: Int): Int? {
        if (!kind.equals("INTRO", true) && !kind.equals("RECAP", true)) return null
        val end = endMs
        val usable = end != null && end > startMs && end - startMs <= 8 * 60 * 1000 &&
            !(durationMs >= 2 * 60 * 1000 && end >= durationMs - 15_000)
        return if (usable) end else startMs + 90_000
    }

    fun skipTargetMs(durationMs: Int): Int {
        val end = openingEnd(durationMs) ?: endMs
        val target = if (end != null && end > startMs) end + 50 else startMs + 90_000
        return if (durationMs > 2000) target.coerceAtMost(durationMs - 2000) else target
    }
}

data class HomeFeed(
    val trending: List<TitleItem>,
    val popular: List<TitleItem>,
    val recent: List<TitleItem>,
    val continueWatching: List<TitleItem>,
)

/** A catalog add-on list a title is on ("Netflix"), tagged on Trending cards. */
data class ServiceTag(val id: String, val name: String)

/**
 * Each service's brand colour (white where the brand is black, so it shows on
 * the dark chip), and a short text mark for services without a logo
 * (see PosterCardPresenter.SERVICE_LOGOS). Same table as the desktop and phone apps.
 */
object ServiceBadges {
    data class Badge(val label: String, val color: Int)

    private val KNOWN: Map<String, Badge> = mapOf(
        "netflix" to Badge("N", 0xFFE50914.toInt()),
        "hbo" to Badge("HBO", 0xFFFFFFFF.toInt()),
        "disney" to Badge("D+", 0xFF0063E5.toInt()),
        "prime" to Badge("prime", 0xFF00A8E1.toInt()),
        "apple" to Badge("tv+", 0xFFFFFFFF.toInt()),
        "hulu" to Badge("hulu", 0xFF1CE783.toInt()),
        "paramount" to Badge("P+", 0xFF0064FF.toInt()),
        "peacock" to Badge("P", 0xFFFFFFFF.toInt()),
        "crunchyroll" to Badge("CR", 0xFFFF5E00.toInt()),
        "hotstar" to Badge("HS", 0xFF3D9BFF.toInt()),
        "zee5" to Badge("Z5", 0xFF8230C6.toInt()),
        "sonyliv" to Badge("SL", 0xFFFFFFFF.toInt()),
        "mubi" to Badge("MUBI", 0xFFFFFFFF.toInt()),
        "starz" to Badge("STARZ", 0xFFFFFFFF.toInt()),
        "showtime" to Badge("SHO", 0xFFB10000.toInt()),
    )

    fun of(tag: ServiceTag): Badge = KNOWN[tag.id]
        ?: Badge(
            tag.name.filter { it.isLetterOrDigit() }.take(3).uppercase().ifBlank { "?" },
            0xFFFFFFFF.toInt(),
        )
}

data class StreamSource(
    val id: String,
    val title: String,
    /** Empty for [isHttp] sources. */
    val magnet: String,
    val seeders: Int,
    val peers: Int,
    val size: String,
    val tracker: String,
    val health: String,
    val indexer: String = "",
    val language: String = "",
    /** "torrent" (played on-device with libtorrent) or "http" (direct link from an add-on). */
    val kind: String = "torrent",
    /** Direct video URL when [isHttp]. */
    val url: String = "",
    /** Headers the player must send with [url] (Stremio proxyHeaders). */
    val headers: Map<String, String> = emptyMap(),
    /** Server rank, higher is better: the only ranking (same on every app). */
    val score: Int = 0,
    /** Every source that returned this result ("Jackett", "Torrentio", …). */
    val providers: List<String> = emptyList(),
) {
    val isHttp: Boolean get() = kind == "http" && url.isNotBlank()

    /** Same result across searches: info hash magnet, or the URL. */
    val key: String get() = if (isHttp) url.trim() else magnet.trim().ifBlank { id }
}

data class StreamBookmark(
    val magnet: String,
    val resumePosition: Int = 0,
    val season: Int? = null,
    val episode: Int? = null,
    val fileIndex: Int? = null,
)

data class StreamStart(
    val sessionId: String,
    val streamUrl: String,
    val title: String,
    val status: String = "starting",
    val localTorrent: Boolean = false,
)

data class StreamSession(
    val id: String,
    val title: String,
    val progress: Double = 0.0,
    val bufferProgress: Double = 0.0,
    val downloadMbps: Double = 0.0,
    val seeders: Int = 0,
    val peers: Int = 0,
    val resumePosition: Int = 0,
    val status: String = "",
    val streamUrl: String = "",
) {
    /** Server only attaches streamUrl once the torrent is playable. */
    val isReady: Boolean
        get() = streamUrl.isNotBlank() &&
            (status.equals("ready", ignoreCase = true) || status.isBlank())
    val isError: Boolean get() = status.startsWith("error", ignoreCase = true)
}

data class ServerInfo(
    val version: String,
    val totalTitles: Int,
    val jackettConfigured: Boolean,
    val preferredLanguages: List<String> = emptyList(),
    val opensubtitlesEnabled: Boolean = false,
    val opensubtitlesConfigured: Boolean = false,
    val wyzieConfigured: Boolean = false,
    val subtitlesConfigured: Boolean = false,
    /** Jackett-harvested announce URLs; LocalTorrentEngine fallback only. */
    val streamTrackers: List<String> = emptyList(),
)

data class FetchedSubtitle(
    val id: String,
    val language: String,
    val label: String,
    val content: String,
)

data class SubtitleHit(
    val id: String,
    val language: String,
    val label: String,
    val format: String,
    val source: String,
    val downloadUrl: String,
)

data class CatalogPage(
    val items: List<TitleItem>,
    val totalCount: Int,
    val hasNextPage: Boolean,
    val page: Int,
)

/** End-of-row "See all" tile. */
data class SeeAllItem(
    val label: String,
    val kind: String?,
    val sort: String,
    val title: String,
)

object StreamHealth {
    fun label(health: String): String = when (health.lowercase()) {
        "excellent" -> "Healthy"
        "good" -> "Good"
        "decent" -> "OK"
        "poor" -> "Weak"
        "unknown" -> "Unlisted seeds"
        "direct" -> "Direct link"
        else -> "Low seeds"
    }

    fun sourceLabel(source: StreamSource): String {
        val indexer = source.indexer.trim()
        val tracker = source.tracker.trim()
        val indexerOk = indexer.isNotEmpty() && !indexer.equals("jackett", true)
        val trackerOk = tracker.isNotEmpty()
        return when {
            indexerOk && trackerOk ->
                if (indexer.equals(tracker, true)) indexer else "$indexer · $tracker"
            indexerOk -> indexer
            trackerOk -> tracker
            else -> "Jackett"
        }
    }
}
