package app.peanutbutter.tv.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.peanutbutter.core.TitleItem
import app.peanutbutter.tv.ui.compose.MetaRow
import app.peanutbutter.tv.ui.compose.PbButton
import app.peanutbutter.tv.ui.compose.PbColors
import app.peanutbutter.tv.ui.compose.PbImage
import app.peanutbutter.tv.ui.compose.PbRadius
import app.peanutbutter.tv.ui.compose.PbType

/**
 * The desktop's FeatureCard (Explore's #1, Search's top result): the whole
 * 16:9 backdrop on the right, the copy and Play / My List / More info on the
 * left fading into it.
 */
@Composable
fun FeatureCard(
    item: TitleItem,
    eyebrow: String,
    height: Dp,
    onList: Boolean,
    onPlay: () -> Unit,
    onToggleList: () -> Unit,
    onInfo: () -> Unit,
    modifier: Modifier = Modifier,
    synopsis: Boolean = false,
) {
    val shape = RoundedCornerShape(PbRadius.panel + 4.dp)
    BoxWithConstraints(modifier.height(height).clip(shape).background(PbColors.ground)) {
        val artW = minOf(height * 16f / 9f, maxWidth)
        PbImage(
            item.backdropUrl ?: item.posterUrl,
            Modifier.align(Alignment.CenterEnd).width(artW).height(height),
            artW, height,
        )
        Box(
            Modifier
                .align(Alignment.CenterStart)
                .width(maxWidth - artW * 0.55f)
                .height(height)
                .background(Brush.horizontalGradient(0f to PbColors.ground, 0.55f to PbColors.ground, 1f to Color(0x000E0E12))),
        )
        Box(Modifier.fillMaxSize().background(Brush.verticalGradient(0.5f to Color.Transparent, 1f to Color(0xB30E0E12))))
        Column(
            Modifier
                .align(Alignment.BottomStart)
                .padding(start = 24.dp, end = 24.dp, bottom = 20.dp)
                .widthIn(max = 560.dp),
        ) {
            BasicText(eyebrow.uppercase(), style = PbType.label.copy(color = PbColors.primary, letterSpacing = 1.1.sp))
            Spacer(Modifier.height(4.dp))
            BasicText(
                item.displayTitle, maxLines = 2, overflow = TextOverflow.Ellipsis,
                style = PbType.h1.copy(fontSize = if (synopsis) 32.sp else 26.sp, lineHeight = if (synopsis) 34.sp else 28.sp),
            )
            Spacer(Modifier.height(8.dp))
            MetaRow(item, maxGenres = if (synopsis) 2 else 1)
            if (synopsis && !item.synopsis.isNullOrBlank()) {
                Spacer(Modifier.height(8.dp))
                BasicText(
                    item.synopsis!!, maxLines = 2, overflow = TextOverflow.Ellipsis,
                    style = PbType.body.copy(color = Color(0xFFD6DAE3), lineHeight = 23.sp),
                )
            }
            Spacer(Modifier.height(12.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                PbButton("Play", Icons.Rounded.PlayArrow, primary = true, onClick = onPlay)
                PbButton("My List", if (onList) Icons.Rounded.Check else Icons.Rounded.Add, primary = false, onClick = onToggleList)
                PbButton("More info", Icons.Outlined.Info, primary = false, onClick = onInfo)
            }
        }
    }
}
