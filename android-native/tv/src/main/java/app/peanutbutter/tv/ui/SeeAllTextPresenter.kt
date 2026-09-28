package app.peanutbutter.tv.ui

import android.util.TypedValue
import android.view.Gravity
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.TextView
import androidx.core.content.ContextCompat
import androidx.leanback.widget.Presenter
import app.peanutbutter.core.SeeAllItem
import app.peanutbutter.tv.R

/**
 * First item in each poster rail — D-pad down from previous shelf lands here
 * (Flutter See-all zigzag). Header also has See all; no end-of-rail duplicate.
 */
class SeeAllTextPresenter : Presenter() {
    override fun onCreateViewHolder(parent: ViewGroup): ViewHolder {
        val density = parent.resources.displayMetrics.density
        val label = TextView(parent.context).apply {
            id = R.id.see_all_label
            layoutParams = FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT,
                (40 * density).toInt(),
            )
            minWidth = (64 * density).toInt()
            setPadding((14 * density).toInt(), 0, (14 * density).toInt(), 0)
            gravity = Gravity.CENTER
            text = parent.context.getString(R.string.see_all)
            setTextColor(ContextCompat.getColor(parent.context, R.color.pb_seed))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
            background = ContextCompat.getDrawable(parent.context, R.drawable.see_all_focus_bg)
            isFocusable = false
            isClickable = false
        }
        val wrap = FrameLayout(parent.context).apply {
            layoutParams = ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT,
                PosterCardPresenter.dp(parent, PosterCardPresenter.CARD_H),
            )
            isFocusable = true
            isFocusableInTouchMode = true
            clipChildren = false
            clipToPadding = false
            addView(
                label,
                FrameLayout.LayoutParams(
                    FrameLayout.LayoutParams.WRAP_CONTENT,
                    (40 * density).toInt(),
                    Gravity.CENTER_VERTICAL,
                ),
            )
            setOnFocusChangeListener { _, hasFocus ->
                label.isSelected = hasFocus
                label.setTypeface(
                    null,
                    if (hasFocus) android.graphics.Typeface.BOLD else android.graphics.Typeface.NORMAL,
                )
                // No scale bounce — focus ring only (avoids double-zoom with Leanback)
            }
        }
        return ViewHolder(wrap)
    }

    override fun onBindViewHolder(viewHolder: ViewHolder, item: Any) {
        val see = item as SeeAllItem
        val label = (viewHolder.view as ViewGroup).getChildAt(0) as TextView
        label.text = see.label.ifBlank { viewHolder.view.context.getString(R.string.see_all) }
    }

    override fun onUnbindViewHolder(viewHolder: ViewHolder) = Unit
}
