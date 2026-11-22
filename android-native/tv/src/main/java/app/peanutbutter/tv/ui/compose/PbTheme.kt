package app.peanutbutter.tv.ui.compose

import androidx.activity.compose.setContent
import androidx.compose.ui.text.ExperimentalTextApi
import androidx.compose.ui.text.TextStyle
import android.content.Context
import android.os.Build
import androidx.compose.ui.text.font.AndroidFont
import androidx.compose.ui.text.font.FontLoadingStrategy
import androidx.compose.ui.text.font.FontStyle
import androidx.core.content.res.ResourcesCompat
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontVariation
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.TextUnit
import app.peanutbutter.tv.R

/**
 * The desktop's two fonts, bundled as variable fonts. Each weight is its own
 * typeface built with that 'wght' value (Compose's resource fonts drew some
 * weights at the font's default, so the hero title came out light).
 */
object PbFonts {
    private fun weights(res: Int) = FontFamily(listOf(400, 500, 600, 700, 800).map { VariableFont(res, it) })

    val display: FontFamily = weights(R.font.space_grotesk)
    val body: FontFamily = weights(R.font.inter)
}

@OptIn(ExperimentalTextApi::class)
private class VariableFont(val res: Int, w: Int) : AndroidFont(FontLoadingStrategy.Blocking, Loader, FontVariation.Settings()) {
    override val weight = FontWeight(w)
    override val style = FontStyle.Normal

    private object Loader : AndroidFont.TypefaceLoader {
        private val cache = HashMap<Pair<Int, Int>, android.graphics.Typeface?>()

        override fun loadBlocking(context: Context, font: AndroidFont): android.graphics.Typeface? {
            font as VariableFont
            val w = font.weight.weight
            return synchronized(cache) {
                cache.getOrPut(font.res to w) { build(context, font.res, w) }
            }
        }

        override suspend fun awaitLoad(context: Context, font: AndroidFont) = loadBlocking(context, font)

        private fun build(context: Context, res: Int, w: Int): android.graphics.Typeface? = runCatching {
            when {
                Build.VERSION.SDK_INT >= 29 -> {
                    val f = android.graphics.fonts.Font.Builder(context.resources, res)
                        .setFontVariationSettings("'wght' $w")
                        .setWeight(w)
                        .build()
                    android.graphics.Typeface.CustomFallbackBuilder(
                        android.graphics.fonts.FontFamily.Builder(f).build(),
                    ).build()
                }
                Build.VERSION.SDK_INT >= 26 -> {
                    // Typeface.Builder needs a file: copy the font out once.
                    val file = java.io.File(context.cacheDir, "pbfont-$res.ttf")
                    if (!file.exists()) {
                        context.resources.openRawResource(res).use { input ->
                            file.outputStream().use { input.copyTo(it) }
                        }
                    }
                    android.graphics.Typeface.Builder(file).setFontVariationSettings("'wght' $w").setWeight(w).build()
                }
                else -> ResourcesCompat.getFont(context, res)
            }
        }.getOrNull() ?: ResourcesCompat.getFont(context, res)
    }
}

/** Text styles named like the desktop's PbType. */
object PbType {
    val hero = TextStyle(fontFamily = PbFonts.display, fontWeight = FontWeight(PbTypeWeight.hero), fontSize = PbTypeSize.hero, color = PbColors.text)
    val h1 = TextStyle(fontFamily = PbFonts.display, fontWeight = FontWeight(PbTypeWeight.h1), fontSize = PbTypeSize.h1, color = PbColors.text)
    val h2 = TextStyle(fontFamily = PbFonts.display, fontWeight = FontWeight(PbTypeWeight.h2), fontSize = PbTypeSize.h2, color = PbColors.text)
    val title = TextStyle(fontFamily = PbFonts.body, fontWeight = FontWeight(PbTypeWeight.title), fontSize = PbTypeSize.title, color = PbColors.text)
    val body = TextStyle(fontFamily = PbFonts.body, fontWeight = FontWeight(PbTypeWeight.body), fontSize = PbTypeSize.body, color = PbColors.text)
    val meta = TextStyle(fontFamily = PbFonts.body, fontWeight = FontWeight(PbTypeWeight.meta), fontSize = PbTypeSize.meta, color = PbColors.textMuted)
    val label = TextStyle(fontFamily = PbFonts.body, fontWeight = FontWeight(PbTypeWeight.label), fontSize = PbTypeSize.label, color = PbColors.textFaint)
    val button = TextStyle(fontFamily = PbFonts.body, fontWeight = FontWeight(PbTypeWeight.button), fontSize = PbTypeSize.button, color = PbColors.text)
}

fun TextStyle.size(size: TextUnit) = copy(fontSize = size)
fun TextStyle.weight(w: Int) = copy(fontWeight = FontWeight(w))

/**
 * How large the TV UI is drawn: dp and sp are scaled by this, so a 1080p TV
 * at 2x lays out as 1200×675 instead of 960×540. At 1.0 everything was too
 * big for the screen and long text got cut off.
 */
const val PB_UI_SCALE = 0.8f

/**
 * The app's UI at [PB_UI_SCALE]. Every screen, dialog and overlay draws
 * through this, and the screen size it reports matches the scaled density.
 */
@androidx.compose.runtime.Composable
fun PbScaled(content: @androidx.compose.runtime.Composable () -> Unit) {
    val density = androidx.compose.ui.platform.LocalDensity.current
    val config = androidx.compose.ui.platform.LocalConfiguration.current
    val scaled = androidx.compose.runtime.remember(density, config) {
        androidx.compose.ui.unit.Density(density.density * PB_UI_SCALE, density.fontScale)
    }
    val scaledConfig = androidx.compose.runtime.remember(config) {
        android.content.res.Configuration(config).apply {
            screenWidthDp = (config.screenWidthDp / PB_UI_SCALE).toInt()
            screenHeightDp = (config.screenHeightDp / PB_UI_SCALE).toInt()
            smallestScreenWidthDp = (config.smallestScreenWidthDp / PB_UI_SCALE).toInt()
            densityDpi = (config.densityDpi * PB_UI_SCALE).toInt()
        }
    }
    androidx.compose.runtime.CompositionLocalProvider(
        androidx.compose.ui.platform.LocalDensity provides scaled,
        androidx.compose.ui.platform.LocalConfiguration provides scaledConfig,
        content = content,
    )
}

/** [androidx.activity.compose.setContent] at the app's UI scale. */
fun androidx.activity.ComponentActivity.setPbContent(content: @androidx.compose.runtime.Composable () -> Unit) {
    setContent { PbScaled(content) }
}
