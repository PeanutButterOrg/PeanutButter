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

    /** Higher = better match to preferred quality (for ranking Jackett hits). */
    fun matchScore(title: String, preferred: String): Int {
        val t = title.lowercase()
        val pref = normalize(preferred)
        val has4k = t.contains("2160") || t.contains("4k") || t.contains("uhd")
        val has1080 = t.contains("1080")
        val has720 = t.contains("720")
        val has480 = t.contains("480") || t.contains("sd")
        val detected = when {
            has4k -> "2160p"
            has1080 -> "1080p"
            has720 -> "720p"
            has480 -> "480p"
            else -> null
        }
        return when {
            detected == pref -> 100
            detected == null -> 40
            pref == "2160p" && detected == "1080p" -> 70
            pref == "1080p" && detected == "720p" -> 70
            pref == "1080p" && detected == "2160p" -> 55
            pref == "720p" && detected == "1080p" -> 60
            pref == "720p" && detected == "480p" -> 50
            else -> 20
        }
    }

    fun rankSources(sources: List<StreamSource>, preferred: String): List<StreamSource> {
        val pref = normalize(preferred)
        return sources.sortedWith(
            compareByDescending<StreamSource> { matchScore(it.title, pref) }
                .thenByDescending { it.seeders },
        )
    }
}
