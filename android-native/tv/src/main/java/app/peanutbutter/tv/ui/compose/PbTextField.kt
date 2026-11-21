package app.peanutbutter.tv.ui.compose

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/**
 * A text field for the remote. Focus alone doesn't open the keyboard (moving
 * past it would); OK does, and Done or leaving the field closes it.
 */
@Composable
fun PbTextField(
    value: String,
    onValueChange: (String) -> Unit,
    placeholder: String,
    modifier: Modifier = Modifier,
    password: Boolean = false,
    keyboardType: KeyboardType = KeyboardType.Text,
    onDone: () -> Unit = {},
) {
    var editing by remember { mutableStateOf(false) }
    var hadFocus by remember { mutableStateOf(false) }
    var focused by remember { mutableStateOf(false) }
    val outer = remember { FocusRequester() }
    val input = remember { FocusRequester() }
    val keyboard = LocalSoftwareKeyboardController.current
    var field by remember { mutableStateOf(TextFieldValue(value, TextRange(value.length))) }
    LaunchedEffect(value) {
        if (value != field.text) field = TextFieldValue(value, TextRange(value.length))
    }
    LaunchedEffect(editing) {
        if (editing) {
            runCatching { input.requestFocus() }
            keyboard?.show()
        }
    }
    val shape = RoundedCornerShape(PbRadius.card + 2.dp)
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = modifier
            .height(50.dp)
            .focusRequester(outer)
            .pbClick({ focused = it }, { editing = true })
            .background(if (focused || editing) PbColors.surfaceRaised else PbColors.ground, shape)
            .border(
                if (focused || editing) 2.dp else 1.dp,
                when {
                    editing -> PbColors.primary
                    focused -> PbColors.focus
                    else -> PbColors.line
                },
                shape,
            )
            .padding(horizontal = 16.dp),
    ) {
        Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.CenterStart) {
            if (editing) {
                BasicTextField(
                    value = field,
                    onValueChange = {
                        field = it
                        onValueChange(it.text)
                    },
                    singleLine = true,
                    textStyle = PbType.body.copy(fontSize = 17.sp),
                    cursorBrush = SolidColor(PbColors.primary),
                    visualTransformation = if (password) PasswordVisualTransformation() else VisualTransformation.None,
                    keyboardOptions = KeyboardOptions(keyboardType = keyboardType, imeAction = ImeAction.Done),
                    keyboardActions = KeyboardActions(onDone = {
                        keyboard?.hide()
                        editing = false
                        runCatching { outer.requestFocus() }
                        onDone()
                    }),
                    modifier = Modifier
                        .fillMaxWidth()
                        .focusRequester(input)
                        .onFocusChanged {
                            if (it.isFocused) hadFocus = true
                            else if (hadFocus && editing) {
                                hadFocus = false
                                editing = false
                            }
                        },
                )
            } else {
                val shown = when {
                    value.isEmpty() -> placeholder
                    password -> "•".repeat(value.length.coerceAtMost(24))
                    else -> value
                }
                BasicText(
                    shown, maxLines = 1, overflow = TextOverflow.Ellipsis,
                    style = PbType.body.copy(fontSize = 17.sp, color = if (value.isEmpty()) PbColors.textFaint else PbColors.text),
                )
            }
        }
    }
}
