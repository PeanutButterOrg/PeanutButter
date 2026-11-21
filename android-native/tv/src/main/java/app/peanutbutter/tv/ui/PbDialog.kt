package app.peanutbutter.tv.ui

import android.app.Activity
import android.content.Context
import android.graphics.Color as AndroidColor
import android.graphics.drawable.ColorDrawable
import android.view.ViewGroup
import androidx.activity.ComponentDialog
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.ComposeView
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import app.peanutbutter.tv.ui.compose.PbButton
import app.peanutbutter.tv.ui.compose.PbColors
import app.peanutbutter.tv.ui.compose.PbRadius
import app.peanutbutter.tv.ui.compose.PbType

/**
 * A full-screen dialog drawn in Compose, for screens that aren't Compose
 * themselves (and to sit over any screen). [content] draws its own scrim and
 * card; Back dismisses unless [cancelable] is false.
 */
fun showPbDialog(
    context: Context,
    cancelable: Boolean = true,
    onDismiss: () -> Unit = {},
    content: @Composable (dismiss: () -> Unit) -> Unit,
): ComponentDialog {
    val dialog = ComponentDialog(context, android.R.style.Theme_Translucent_NoTitleBar)
    dialog.setCancelable(cancelable)
    val view = ComposeView(context).apply {
        setContent { content { dialog.dismiss() } }
    }
    dialog.setContentView(view)
    dialog.window?.apply {
        setBackgroundDrawable(ColorDrawable(AndroidColor.TRANSPARENT))
        setLayout(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
    }
    dialog.setOnDismissListener { onDismiss() }
    dialog.show()
    return dialog
}

/** The app's card over a dim scrim (the player's resume and leave cards). */
@Composable
fun DialogCard(width: Dp = 560.dp, content: @Composable ColumnScope.() -> Unit) {
    val shape = RoundedCornerShape(PbRadius.panel)
    Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.55f)), contentAlignment = Alignment.Center) {
        Column(
            Modifier
                .width(width)
                .shadow(40.dp, shape)
                .background(PbColors.surface, shape)
                .border(1.dp, PbColors.line, shape)
                .padding(start = 26.dp, end = 26.dp, top = 24.dp, bottom = 26.dp),
            content = content,
        )
    }
}

/**
 * Title, message, and two buttons: the safe choice ([negative]) first and
 * focused, the action ([positive]) in amber.
 */
@Composable
fun ConfirmCard(
    title: String,
    message: String,
    negative: String,
    positive: String?,
    onNegative: () -> Unit,
    onPositive: () -> Unit,
    focusPositive: Boolean = false,
) {
    val stay = remember { FocusRequester() }
    val go = remember { FocusRequester() }
    LaunchedEffect(focusPositive, positive) {
        runCatching { if (focusPositive && positive != null) go.requestFocus() else stay.requestFocus() }
    }
    DialogCard {
        BasicText(title, style = PbType.h2)
        Spacer(Modifier.height(8.dp))
        BasicText(message, style = PbType.body.copy(color = PbColors.textMuted))
        Spacer(Modifier.height(24.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp), modifier = Modifier.align(Alignment.End)) {
            PbButton(negative, null, primary = false, onClick = onNegative, modifier = Modifier.focusRequester(stay))
            if (positive != null) {
                PbButton(positive, null, primary = true, onClick = onPositive, modifier = Modifier.focusRequester(go))
            }
        }
    }
}

/** Confirm with the app's card: [negative] keeps things as they are, [positive] runs [onPositive]. */
fun showRoundDialog(
    activity: Activity,
    title: Int,
    message: Int,
    negative: Int,
    positive: Int,
    onPositive: () -> Unit,
): ComponentDialog = showPbDialog(activity) { dismiss ->
    ConfirmCard(
        title = activity.getString(title),
        message = activity.getString(message),
        negative = activity.getString(negative),
        positive = activity.getString(positive),
        onNegative = dismiss,
        onPositive = {
            dismiss()
            onPositive()
        },
    )
}
