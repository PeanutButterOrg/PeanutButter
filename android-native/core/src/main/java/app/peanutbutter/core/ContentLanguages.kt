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

    fun normalize(codes: Collection<String>): Set<String> {
        val known = OPTIONS.map { it.first }.toSet()
        return codes.map { it.trim().lowercase() }
            .filter { it.isNotEmpty() && it != "all" && it in known }
            .toSet()
    }
}
