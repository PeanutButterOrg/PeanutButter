package app.peanutbutter.tv.ui.compose

import androidx.compose.ui.text.ExperimentalTextApi
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontVariation
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.TextUnit
import app.peanutbutter.tv.R

/** The desktop's two fonts, bundled as variable fonts (weights from 400 to 800). */
@OptIn(ExperimentalTextApi::class)
object PbFonts {
    private fun weights(res: Int) = FontFamily(
        listOf(400, 500, 600, 700, 800).map { w ->
            Font(res, FontWeight(w), variationSettings = FontVariation.Settings(FontVariation.weight(w)))
        },
    )

    val display: FontFamily = weights(R.font.space_grotesk)
    val body: FontFamily = weights(R.font.inter)
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
