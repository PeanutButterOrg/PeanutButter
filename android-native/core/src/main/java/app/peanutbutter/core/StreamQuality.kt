package app.peanutbutter.core

/** Flutter defaultQuality values: 480p / 720p / 1080p / 2160p (label 4K). */
object StreamQuality {
    val OPTIONS: List<Pair<String, String>> = listOf(
        "480p" to "480p",
        "720p" to "720p",
        "1080p" to "1080p",
        "2160p" to "4K",
    )

    fun normalize(raw: String?): String {
        val q = raw.orEmpty().trim().lowercase()
        return when {
            q == "4k" || q == "2160" || q == "2160p" || q.contains("uhd") -> "2160p"
            q == "1080" || q == "1080p" || q.contains("1080") -> "1080p"
            q == "720" || q == "720p" || q.contains("720") -> "720p"
            q == "480" || q == "480p" || q.contains("480") -> "480p"
            else -> "1080p"
        }
    }

    /**
     * Best first, by the server's score. The server is the one place that
     * ranks (resolution against the quality setting, seeders and peers, size
     * sanity, languages), so the TV, desktop and phone apps all agree; this
     * only re-sorts lists merged on the device (one search per language).
     */
    fun rankSources(sources: List<StreamSource>): List<StreamSource> =
        sources.sortedByDescending { it.score }
}
