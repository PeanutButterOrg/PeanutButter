package app.peanutbutter.tv.launcher

import android.app.Activity
import android.app.Dialog
import android.graphics.drawable.ColorDrawable
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.LinearLayout
import android.widget.TextView
import androidx.core.content.ContextCompat
import androidx.recyclerview.widget.GridLayoutManager
import androidx.recyclerview.widget.RecyclerView
import app.peanutbutter.tv.R

/**
 * Full-screen grid of every app on the TV. Select a tile to add it to Your
 * apps (its number is its place in the row), select again to take it off.
 * Done or Back saves.
 */
class AppPicker(
    private val activity: Activity,
    all: List<AppsRow.App>,
    selected: List<String>,
    private val onDone: (List<String>) -> Unit,
) {
    private val order = selected.toMutableList()
    // The user's own apps first, then system ones.
    private val apps = all.sortedWith(compareBy({ it.system }, { it.label.lowercase() }))
    private val dialog = Dialog(activity, android.R.style.Theme_Black_NoTitleBar_Fullscreen)
    private fun dp(v: Int) = (v * activity.resources.displayMetrics.density).toInt()

    private val adapter = object : RecyclerView.Adapter<RecyclerView.ViewHolder>() {
        override fun getItemCount() = apps.size
        override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): RecyclerView.ViewHolder {
            val tile = AppTileView(activity).apply {
                layoutParams = RecyclerView.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT)
                setPadding(dp(10), dp(12), dp(10), dp(12))
            }
            return object : RecyclerView.ViewHolder(tile) {}
        }

        override fun onBindViewHolder(holder: RecyclerView.ViewHolder, position: Int) {
            val tile = holder.itemView as AppTileView
            val app = apps[position]
            tile.bind(app)
            showState(tile, app)
            tile.setOnClickListener {
                if (!order.remove(app.pkg)) order.add(app.pkg)
                // Numbers after this one shift, so refresh the visible badges.
                notifyItemRangeChanged(0, itemCount, PAYLOAD_BADGE)
            }
        }

        override fun onBindViewHolder(holder: RecyclerView.ViewHolder, position: Int, payloads: MutableList<Any>) {
            if (payloads.contains(PAYLOAD_BADGE)) showState(holder.itemView as AppTileView, apps[position])
            else onBindViewHolder(holder, position)
        }
    }

    private fun showState(tile: AppTileView, app: AppsRow.App) {
        val place = order.indexOf(app.pkg)
        tile.badge.visibility = if (place >= 0) View.VISIBLE else View.GONE
        tile.badge.text = (place + 1).toString()
        tile.body.animate().alpha(if (place >= 0) 1f else 0.45f).setDuration(150).start()
    }

    fun show() {
        val grid = RecyclerView(activity).apply {
            layoutManager = GridLayoutManager(activity, COLUMNS)
            adapter = this@AppPicker.adapter
            clipChildren = false
            clipToPadding = false
            setPadding(dp(38), dp(8), dp(38), dp(48))
            itemAnimator = null
        }
        val done = TextView(activity).apply {
            setText(R.string.launcher_done)
            setTextColor(ContextCompat.getColorStateList(activity, R.color.launcher_bar_fg))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            gravity = Gravity.CENTER
            background = ContextCompat.getDrawable(activity, R.drawable.launcher_done_bg)
            setPadding(dp(28), 0, dp(28), 0)
            isFocusable = true
            isFocusableInTouchMode = true
            Motion.lift(this, 1.06f)
            setOnClickListener { dialog.dismiss() }
        }
        val header = LinearLayout(activity).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(48), dp(36), dp(48), dp(12))
            addView(
                LinearLayout(activity).apply {
                    orientation = LinearLayout.VERTICAL
                    addView(TextView(activity).apply {
                        setText(R.string.choose_apps)
                        setTextColor(ContextCompat.getColor(activity, R.color.pb_white))
                        setTextSize(TypedValue.COMPLEX_UNIT_SP, 28f)
                        setTypeface(typeface, android.graphics.Typeface.BOLD)
                    })
                    addView(TextView(activity).apply {
                        setText(R.string.choose_apps_hint)
                        setTextColor(ContextCompat.getColor(activity, R.color.pb_muted))
                        setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
                        setPadding(0, dp(4), 0, 0)
                    })
                },
                LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f),
            )
            addView(done, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, dp(48)))
        }
        val root = LinearLayout(activity).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(ContextCompat.getColor(activity, R.color.pb_canvas))
            addView(header)
            addView(grid, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
        }
        dialog.setContentView(root)
        dialog.window?.apply {
            setBackgroundDrawable(ColorDrawable(ContextCompat.getColor(activity, R.color.pb_canvas)))
            setWindowAnimations(R.style.LauncherPickerAnimation)
        }
        // Done and Back both keep the choice.
        dialog.setOnDismissListener { onDone(order.toList()) }
        dialog.show()
        Motion.enter(listOf(header, grid), startDelay = 40)
        grid.post { grid.getChildAt(0)?.requestFocus() }
    }

    companion object {
        private const val COLUMNS = 4
        private const val PAYLOAD_BADGE = "badge"
    }
}
