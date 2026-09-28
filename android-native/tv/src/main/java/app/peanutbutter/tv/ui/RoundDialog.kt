package app.peanutbutter.tv.ui

import android.app.Activity
import android.app.AlertDialog
import android.graphics.Color
import android.graphics.drawable.ColorDrawable
import android.view.LayoutInflater
import android.widget.TextView
import app.peanutbutter.tv.R

/** Confirm dialog whose actions use the same rounded buttons as the rest of the app. */
fun showRoundDialog(
    activity: Activity,
    title: Int,
    message: Int,
    negative: Int,
    positive: Int,
    onPositive: () -> Unit,
): AlertDialog {
    val view = LayoutInflater.from(activity).inflate(R.layout.dialog_confirm, null)
    view.findViewById<TextView>(R.id.dialog_title).setText(title)
    view.findViewById<TextView>(R.id.dialog_message).setText(message)
    val stay = view.findViewById<TextView>(R.id.dialog_negative)
    val go = view.findViewById<TextView>(R.id.dialog_positive)
    stay.setText(negative)
    go.setText(positive)
    val dialog = AlertDialog.Builder(activity).setView(view).create()
    stay.setOnClickListener { dialog.dismiss() }
    go.setOnClickListener {
        dialog.dismiss()
        onPositive()
    }
    dialog.setOnShowListener {
        dialog.window?.setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT))
        stay.requestFocus()
    }
    dialog.show()
    dialog.window?.setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT))
    return dialog
}
