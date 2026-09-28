package app.peanutbutter.tv.ui

import android.content.Context
import android.view.KeyEvent
import android.view.View
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import android.widget.EditText

fun View.hideKeyboard() {
    val imm = context.getSystemService(Context.INPUT_METHOD_SERVICE) as? InputMethodManager
    imm?.hideSoftInputFromWindow(windowToken, 0)
}

/** Hide the keyboard when the IME Done / OK / Search key is pressed. */
fun EditText.closeKeyboardOnIme(onDone: (() -> Unit)? = null) {
    setOnEditorActionListener { v, actionId, event ->
        val submit = actionId == EditorInfo.IME_ACTION_DONE ||
            actionId == EditorInfo.IME_ACTION_SEARCH ||
            actionId == EditorInfo.IME_ACTION_GO ||
            actionId == EditorInfo.IME_ACTION_SEND ||
            (event?.keyCode == KeyEvent.KEYCODE_ENTER && event.action == KeyEvent.ACTION_DOWN)
        if (!submit) return@setOnEditorActionListener false
        v.hideKeyboard()
        onDone?.invoke()
        true
    }
}
