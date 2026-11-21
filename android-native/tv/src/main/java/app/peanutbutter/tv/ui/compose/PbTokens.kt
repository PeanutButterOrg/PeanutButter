// Generated from design/tokens.json by scripts/gen-design-tokens.py. Do not edit.
package app.peanutbutter.tv.ui.compose

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/** PeanutButter's colours (see design/tokens.json for what each is for). */
object PbColors {
    /** Page background, behind everything */
    val ground = Color(0xFF0E0E12)
    /** Cards, panels, menus */
    val surface = Color(0xFF16171D)
    /** Hovered or selected surface, inputs */
    val surfaceRaised = Color(0xFF1E2028)
    /** Hairlines and outlines */
    val line = Color(0xFF2A2D37)
    /** Main text */
    val text = Color(0xFFF1F3F7)
    /** Secondary text, captions */
    val textMuted = Color(0xFFA7ADBB)
    /** Hints, disabled text */
    val textFaint = Color(0xFF6E7483)
    /** Peanut amber: the main action (Play, Save) and active chips */
    val primary = Color(0xFFE2A456)
    /** Primary while pressed */
    val primaryPressed = Color(0xFFC98A3E)
    /** Text and icons on primary */
    val onPrimary = Color(0xFF1A1206)
    /** Focus ring (keyboard / remote): soft white, like the text */
    val focus = Color(0xFFF1F3F7)
    /** Focused surface tint on TV */
    val focusSoft = Color(0xFF3A3D48)
    /** The blue 'Butter' in the logo */
    val brand = Color(0xFF5B9FFF)
    /** Healthy, done, on */
    val good = Color(0xFF4ADE80)
    /** Weak, attention */
    val warn = Color(0xFFFBBF24)
    /** Errors, dead, destructive */
    val bad = Color(0xFFF87171)
    /** Rotten Tomatoes red, only on its badge */
    val rt = Color(0xFFFA320A)
    /** Top bar once content scrolls under it */
    val scrimTop = Color(0xF20E0E12)
    /** Hero fade behind text */
    val scrimHero = Color(0xE60E0E12)
}

/** TV type sizes and weights, same scale as desktop. */
object PbTypeSize {
    val hero = 44.sp
    val h1 = 32.sp
    val h2 = 24.sp
    val title = 18.sp
    val body = 16.sp
    val meta = 15.sp
    val label = 12.sp
    val button = 16.sp
}

object PbTypeWeight {
    const val hero = 700
    const val h1 = 700
    const val h2 = 600
    const val title = 600
    const val body = 400
    const val meta = 500
    const val label = 700
    const val button = 600
}

object PbSpace {
    val xxs = 4.dp
    val xs = 8.dp
    val sm = 12.dp
    val md = 16.dp
    val lg = 24.dp
    val xl = 32.dp
    val xxl = 48.dp
    val gutterDesktop = 36.dp
    val gutterTv = 48.dp
}

object PbRadius {
    val badge = 6.dp
    val card = 10.dp
    val panel = 16.dp
    val pill = 999.dp
}

object PbMotion {
    const val fast = 120
    const val base = 180
    const val slow = 280
}
