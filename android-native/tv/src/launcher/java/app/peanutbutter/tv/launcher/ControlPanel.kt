package app.peanutbutter.tv.launcher

import android.app.Activity
import android.app.Dialog
import android.graphics.Color
import android.graphics.drawable.ColorDrawable
import android.text.TextUtils
import android.util.TypedValue
import android.view.Gravity
import android.view.KeyEvent
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.ScrollView
import android.widget.TextView
import androidx.core.content.ContextCompat
import app.peanutbutter.tv.R

/**
 * Compact quick-settings panel that drops down at the top right, like the
 * one in recent Android: a title, toggle / list / slider rows, and a link to
 * the full settings page. Built with [rows] and shown with [show].
 */
class ControlPanel(private val activity: Activity, title: String, private val centered: Boolean = false) {
    private val dialog = Dialog(activity)
    private val list = LinearLayout(activity).apply { orientation = LinearLayout.VERTICAL }
    private val root = LinearLayout(activity).apply {
        orientation = LinearLayout.VERTICAL
        background = ContextCompat.getDrawable(activity, R.drawable.launcher_panel_bg)
        setPadding(dp(12), dp(16), dp(12), dp(12))
        addView(
            TextView(activity).apply {
                text = title
                setTextColor(ContextCompat.getColor(activity, R.color.pb_white))
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 20f)
                setTypeface(typeface, android.graphics.Typeface.BOLD)
                setPadding(dp(12), 0, dp(12), dp(10))
            },
        )
        addView(ScrollView(activity).apply { addView(list) }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
    }

    private fun dp(v: Int) = (v * activity.resources.displayMetrics.density).toInt()

    private fun row(icon: Int?, label: String, detail: String?): Triple<LinearLayout, TextView, TextView> {
        val title = TextView(activity).apply {
            text = label
            setTextColor(ContextCompat.getColor(activity, R.color.pb_white))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
            maxLines = 1
            ellipsize = TextUtils.TruncateAt.END
        }
        val sub = TextView(activity).apply {
            text = detail
            visibility = if (detail.isNullOrBlank()) View.GONE else View.VISIBLE
            setTextColor(ContextCompat.getColor(activity, R.color.pb_muted))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
            maxLines = 1
            ellipsize = TextUtils.TruncateAt.END
        }
        val texts = LinearLayout(activity).apply {
            orientation = LinearLayout.VERTICAL
            addView(title)
            addView(sub)
        }
        val row = LinearLayout(activity).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            minimumHeight = dp(56)
            setPadding(dp(12), dp(6), dp(12), dp(6))
            background = ContextCompat.getDrawable(activity, R.drawable.launcher_row_bg)
            isFocusable = true
            isFocusableInTouchMode = true
            if (icon != null) {
                addView(
                    ImageView(activity).apply { setImageResource(icon) },
                    LinearLayout.LayoutParams(dp(22), dp(22)).apply { marginEnd = dp(16) },
                )
            }
            addView(texts, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        }
        list.addView(row, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(2) })
        return Triple(row, title, sub)
    }

    /** Small section title ("PeanutButter", "TV"). */
    fun header(text: String) = apply {
        list.addView(
            TextView(activity).apply {
                this.text = text
                setTextColor(ContextCompat.getColor(activity, R.color.pb_seed))
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
                setTypeface(typeface, android.graphics.Typeface.BOLD)
                setPadding(dp(12), dp(if (list.childCount == 0) 0 else 14), dp(12), dp(4))
            },
        )
    }

    /** Status line, not selectable. */
    fun info(icon: Int?, label: String, detail: String? = null) = apply {
        row(icon, label, detail).first.apply {
            isFocusable = false
            background = null
        }
    }

    /** Selectable row; [dot] adds a status dot (true = green, false = grey). */
    fun action(icon: Int?, label: String, detail: String? = null, dot: Boolean? = null, onClick: () -> Unit) = apply {
        val row = row(icon, label, detail).first
        if (dot != null) {
            row.addView(
                View(activity).apply {
                    background = ContextCompat.getDrawable(
                        activity,
                        if (dot) R.drawable.launcher_dot_on else R.drawable.launcher_dot_off,
                    )
                },
                LinearLayout.LayoutParams(dp(10), dp(10)).apply { marginStart = dp(12) },
            )
        }
        row.setOnClickListener {
            dialog.dismiss()
            onClick()
        }
    }

    /** On/off row. [onToggle] returns the new state (or null if it handed off to settings). */
    fun toggle(icon: Int?, label: String, detail: String?, on: Boolean, onToggle: (Boolean) -> Boolean?) = apply {
        val row = row(icon, label, detail).first
        // Platform switch: works with this app's theme (SwitchCompat needs an AppCompat one).
        val switch = android.widget.Switch(activity).apply {
            showText = false
            isChecked = on
            isFocusable = false
            isClickable = false
            thumbTintList = ContextCompat.getColorStateList(activity, R.color.launcher_switch_thumb)
            trackTintList = ContextCompat.getColorStateList(activity, R.color.launcher_switch_track)
        }
        row.addView(switch)
        row.setOnClickListener {
            when (val now = onToggle(!switch.isChecked)) {
                null -> dialog.dismiss()
                else -> switch.isChecked = now
            }
        }
    }

    /** ◀ ▶ slider row (e.g. volume). [step] gets -1 / +1 and returns the new level. */
    fun slider(icon: Int?, label: String, level: Int, max: Int, step: (Int) -> Int) = apply {
        val (row, title, _) = row(icon, label, null)
        val bar = ProgressBar(activity, null, android.R.attr.progressBarStyleHorizontal).apply {
            this.max = max
            progress = level
            progressDrawable = ContextCompat.getDrawable(activity, R.drawable.launcher_progress)
        }
        val value = TextView(activity).apply {
            text = level.toString()
            setTextColor(ContextCompat.getColor(activity, R.color.pb_white))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
            gravity = Gravity.END
        }
        (title.parent as LinearLayout).addView(bar, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(4)).apply { topMargin = dp(8) })
        row.addView(value, LinearLayout.LayoutParams(dp(40), ViewGroup.LayoutParams.WRAP_CONTENT))
        row.setOnKeyListener { _, keyCode, event ->
            if (event.action != KeyEvent.ACTION_DOWN) return@setOnKeyListener false
            val dir = when (keyCode) {
                KeyEvent.KEYCODE_DPAD_LEFT -> -1
                KeyEvent.KEYCODE_DPAD_RIGHT -> 1
                else -> return@setOnKeyListener false
            }
            val now = step(dir)
            bar.progress = now
            value.text = now.toString()
            true
        }
    }

    /** Footer link to the full settings page. */
    fun link(label: String, onClick: () -> Unit) = action(R.drawable.ic_open, label, null, null, onClick)

    fun show() {
        dialog.requestWindowFeature(android.view.Window.FEATURE_NO_TITLE)
        dialog.setContentView(root)
        dialog.window?.apply {
            setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT))
            if (centered) {
                setGravity(Gravity.CENTER)
                setLayout(dp(380), ViewGroup.LayoutParams.WRAP_CONTENT)
            } else {
                // Drops down under the control bar.
                setGravity(Gravity.TOP or Gravity.END)
                setLayout(dp(400), ViewGroup.LayoutParams.WRAP_CONTENT)
                attributes = attributes.apply {
                    x = dp(40)
                    y = dp(92)
                }
            }
            addFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND)
            setDimAmount(0.35f)
            setWindowAnimations(R.style.LauncherPanelAnimation)
        }
        dialog.show()
        Motion.enter((0 until list.childCount).map { list.getChildAt(it) }, startDelay = 60, step = 25)
        list.getChildAt(0)?.let { first ->
            // Focus the first selectable row.
            (0 until list.childCount).map { list.getChildAt(it) }.firstOrNull { it.isFocusable }?.requestFocus() ?: first.requestFocus()
        }
    }
}
