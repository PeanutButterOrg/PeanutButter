package app.peanutbutter.core

/**
 * Shared visual tokens — mirrored from Flutter [AppTheme] / [PtTheme].
 */
object PbTheme {
    const val SEED = 0xFF5B9FFF.toInt()
    const val CANVAS = 0xFF0E0E12.toInt()
    const val PANEL = 0xFF1A1A22.toInt()
    const val FIELD = 0xFF121218.toInt()
    const val SIDEBAR = 0xFF12141A.toInt()
    const val MUTED = 0xFF9A9AA8.toInt()
    const val WHITE = 0xFFFFFFFF.toInt()
    const val RT = 0xFFFA320A.toInt()
    const val COMPLETED = 0xFF7CFFB2.toInt()
    const val HAIRLINE = 0x22FFFFFF

    /** Poster / field corner — Flutter uses 12. */
    const val RADIUS_MD = 12f
    /** Menus / dialogs — Flutter uses 14. */
    const val RADIUS_LG = 14f
    /** Focus ring on TV posters. */
    const val RADIUS_POSTER_INNER = 10f

    const val POSTER_W = 152
    const val POSTER_H = 228
}
