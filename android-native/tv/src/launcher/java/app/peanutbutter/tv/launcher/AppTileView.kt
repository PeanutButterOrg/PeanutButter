package app.peanutbutter.tv.launcher

import android.content.Context
import android.text.TextUtils
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import androidx.core.content.ContextCompat
import app.peanutbutter.tv.R

/**
 * One app tile: 16:9 rounded banner (or icon + name when the app has no TV
 * banner), lifts when focused, name fades in underneath. [badge] is the
 * picker's tick / order number in the top-right corner.
 */
class AppTileView(context: Context, widthDp: Int = W, heightDp: Int = H) : LinearLayout(context) {
    private fun dp(v: Int) = (v * resources.displayMetrics.density).toInt()

    private val image = ImageView(context)
    private val fallback = TextView(context).apply {
        setTextColor(ContextCompat.getColor(context, R.color.pb_white))
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
        gravity = Gravity.CENTER_HORIZONTAL
        maxLines = 1
        ellipsize = TextUtils.TruncateAt.END
        setPadding(dp(6), 0, dp(6), dp(8))
    }
    val body = FrameLayout(context).apply {
        background = ContextCompat.getDrawable(context, R.drawable.launcher_app_bg)
        addView(image, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        addView(fallback, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.BOTTOM))
        Motion.round(this, 16f)
    }
    val badge = TextView(context).apply {
        setTextColor(ContextCompat.getColor(context, R.color.pb_canvas))
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
        setTypeface(typeface, android.graphics.Typeface.BOLD)
        gravity = Gravity.CENTER
        background = ContextCompat.getDrawable(context, R.drawable.launcher_badge)
        visibility = View.GONE
    }
    val label = Motion.nameLabel(context)

    /** ◀ ▶ on the tile while it is being moved. */
    private val moveHint = TextView(context).apply {
        text = "◀          ▶"
        setTextColor(ContextCompat.getColor(context, R.color.pb_white))
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 18f)
        setTypeface(typeface, android.graphics.Typeface.BOLD)
        gravity = Gravity.CENTER
        setBackgroundColor(0x99000000.toInt())
        alpha = 0f
    }

    private var editTile = false

    private fun showEditFocus(focused: Boolean) {
        body.background = ContextCompat.getDrawable(
            context,
            if (focused) R.drawable.launcher_edit_focused else R.drawable.launcher_edit_rest,
        )
        // Stays white-on-dark; focus is shown by the lift and a lighter surface.
        val fg = ContextCompat.getColor(context, R.color.pb_white)
        image.imageTintList = android.content.res.ColorStateList.valueOf(fg)
        fallback.setTextColor(fg)
    }

    fun showMoving(moving: Boolean) {
        moveHint.animate().alpha(if (moving) 1f else 0f).setDuration(160).start()
    }

    private lateinit var frame: FrameLayout

    init {
        orientation = VERTICAL
        clipChildren = false
        clipToPadding = false
        isFocusable = true
        isFocusableInTouchMode = true
        frame = FrameLayout(context).apply {
            clipChildren = false
            // Rounded shadow when lifted (the frame itself has no background).
            Motion.roundOutline(this, 16f)
            addView(body, FrameLayout.LayoutParams(dp(widthDp), dp(heightDp)))
            body.addView(moveHint, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
            addView(badge, FrameLayout.LayoutParams(dp(26), dp(26), Gravity.TOP or Gravity.END).apply {
                topMargin = dp(8)
                marginEnd = dp(8)
            })
        }
        addView(frame, LayoutParams(dp(widthDp), dp(heightDp)))
        addView(label, LayoutParams(dp(widthDp), ViewGroup.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(4) })
        setOnFocusChangeListener { _, focused ->
            if (editTile) showEditFocus(focused)
            Motion.liftNow(frame, focused, 1.1f)
            Motion.nameUnder(frame, label, focused, 1.1f)
        }
    }

    fun bind(app: AppsRow.App) {
        if (app.banner != null) {
            image.setImageDrawable(app.banner)
            image.scaleType = ImageView.ScaleType.CENTER_CROP
            image.setPadding(0, 0, 0, 0)
            fallback.visibility = View.GONE
        } else {
            // No TV banner: the icon, centred above the app's name.
            val pad = dp(16)
            image.setImageDrawable(app.icon)
            image.scaleType = ImageView.ScaleType.FIT_CENTER
            image.setPadding(pad, pad / 2, pad, pad + pad / 2)
            fallback.text = app.label
            fallback.visibility = View.VISIBLE
        }
        label.text = app.label
        contentDescription = app.label
    }

    /** The "Edit" tile at the end of Your apps. */
    fun bindEdit() {
        // Dashed "+ Edit" tile that fills white (dark "+ Edit") when focused.
        editTile = true
        image.setImageResource(R.drawable.ic_add)
        image.scaleType = ImageView.ScaleType.CENTER
        image.setPadding(0, 0, 0, dp(22))
        fallback.setText(R.string.customise)
        fallback.setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
        fallback.setTypeface(fallback.typeface, android.graphics.Typeface.BOLD)
        fallback.setPadding(dp(6), 0, dp(6), dp(16))
        fallback.visibility = View.VISIBLE
        // No name under this one: "+ Edit" on the tile says it all.
        label.visibility = View.GONE
        showEditFocus(false)
        contentDescription = context.getString(R.string.customise_hint)
    }

    companion object {
        const val W = 176
        const val H = 99
    }
}
