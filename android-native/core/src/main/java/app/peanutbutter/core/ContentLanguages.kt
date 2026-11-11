package app.peanutbutter.core

/** Same ISO list as the Flutter settings language menu. */
object ContentLanguages {
    val OPTIONS: List<Pair<String, String>> = listOf(
        "en" to "English",
        "ja" to "Japanese",
        "ko" to "Korean",
        "zh" to "Chinese",
        "hi" to "Hindi",
        "es" to "Spanish",
        "fr" to "French",
        "de" to "German",
        "it" to "Italian",
        "pt" to "Portuguese",
        "ar" to "Arabic",
        "tr" to "Turkish",
        "ru" to "Russian",
        "th" to "Thai",
        "id" to "Indonesian",
    )

    /**
     * Languages offered for subtitle downloads: the chosen content languages
     * in order, then English if it isn't one of them. Subtitles follow what
     * you read, not only what a show is in: Languages = Hindi left English
     * subtitles unreachable.
     */
    fun subtitleLanguages(preferred: Collection<String>): List<String> =
        (normalize(preferred) + "en").toList()

    fun normalize(codes: Collection<String>): Set<String> {
        val known = OPTIONS.map { it.first }.toSet()
        return codes.map { it.trim().lowercase() }
            .filter { it.isNotEmpty() && it != "all" && it in known }
            .toSet()
    }
}
