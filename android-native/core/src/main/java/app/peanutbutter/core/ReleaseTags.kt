package app.peanutbutter.core

/**
 * What a release name says about the copy, for the quality box in Choose a
 * stream: "4K" + "HDR", "1080" + "BluRay", "HEVC", "5.1". Display only: the
 * server alone ranks sources. Same rules as the desktop app's release_tags.dart.
 */
data class ReleaseTags(
    /** "4K", "1080", "720" or "" when the name doesn't say. */
    val resolution: String = "",
    /** The most telling one of Remux, DV, HDR, BluRay, WEB, HDTV. */
    val source: String = "",
    /** "HEVC", "H.264", "AV1" or "". */
    val codec: String = "",
    /** "Atmos", "7.1", "5.1" or "". */
    val audio: String = "",
) {
    companion object {
        private fun has(s: String, pattern: String) = Regex(pattern, RegexOption.IGNORE_CASE).containsMatchIn(s)

        fun parse(name: String): ReleaseTags {
            val s = " " + name.replace(Regex("[._\\[\\]()-]"), " ") + " "
            val resolution = when {
                has(s, "\\b(2160p|4k|uhd)\\b") -> "4K"
                has(s, "\\b1080[pi]?\\b") -> "1080"
                has(s, "\\b720p?\\b") -> "720"
                else -> ""
            }
            val source = when {
                has(s, "\\bremux\\b") -> "Remux"
                has(s, "\\b(dv|dovi|dolby vision)\\b") -> "DV"
                has(s, "\\bhdr(10)?(\\+|plus)?\\b") -> "HDR"
                has(s, "\\b(blu ?ray|bdrip|brrip|bd)\\b") -> "BluRay"
                has(s, "\\bweb ?(dl|rip)?\\b") -> "WEB"
                has(s, "\\bhdtv\\b") -> "HDTV"
                else -> ""
            }
            val codec = when {
                has(s, "\\b(x265|h ?265|hevc)\\b") -> "HEVC"
                has(s, "\\bav1\\b") -> "AV1"
                has(s, "\\b(x264|h ?264|avc)\\b") -> "H.264"
                else -> ""
            }
            val audio = when {
                has(s, "\\batmos\\b") -> "Atmos"
                has(s, "(?<![0-9])7 1\\b") -> "7.1"
                has(s, "(?<![0-9])5 1\\b") -> "5.1"
                else -> ""
            }
            return ReleaseTags(resolution, source, codec, audio)
        }
    }
}
