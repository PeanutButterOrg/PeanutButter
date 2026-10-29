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

/**
 * Pick-one list in the same rounded panel as [showRoundDialog] (aspect,
 * audio track, subtitle menus). The current choice is marked and focused.
 */
fun showRoundListDialog(
    activity: Activity,
    title: String,
    options: List<String>,
    checked: Int = -1,
    onPick: (Int) -> Unit,
): AlertDialog {
    val view = LayoutInflater.from(activity).inflate(R.layout.dialog_list, null)
    view.findViewById<TextView>(R.id.dialog_title).text = title
    val list = view.findViewById<android.widget.LinearLayout>(R.id.dialog_list)
    val cancel = view.findViewById<TextView>(R.id.dialog_negative)
    val dialog = AlertDialog.Builder(activity).setView(view).create()
    val density = activity.resources.displayMetrics.density
    val rows = options.mapIndexed { i, label ->
        TextView(activity).apply {
            text = label
            textSize = 16f
            setTextColor(activity.getColor(R.color.pb_white))
            minHeight = (48 * density).toInt()
            gravity = android.view.Gravity.CENTER_VERTICAL
            setPadding((16 * density).toInt(), 0, (16 * density).toInt(), 0)
            isFocusable = true
            isFocusableInTouchMode = true
            setBackgroundResource(R.drawable.bg_dialog_option)
            isSelected = i == checked
            if (i == checked) {
                setCompoundDrawablesRelativeWithIntrinsicBounds(0, 0, R.drawable.ic_check, 0)
            }
            setOnClickListener {
                dialog.dismiss()
                onPick(i)
            }
        }
    }
    rows.forEachIndexed { i, row ->
        val lp = android.widget.LinearLayout.LayoutParams(
            android.widget.LinearLayout.LayoutParams.MATCH_PARENT,
            android.widget.LinearLayout.LayoutParams.WRAP_CONTENT,
        )
        if (i > 0) lp.topMargin = (6 * density).toInt()
        list.addView(row, lp)
    }
    cancel.setOnClickListener { dialog.dismiss() }
    dialog.setOnShowListener {
        dialog.window?.setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT))
        (rows.getOrNull(checked) ?: rows.firstOrNull() ?: cancel).requestFocus()
    }
    dialog.show()
    dialog.window?.setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT))
    return dialog
}
