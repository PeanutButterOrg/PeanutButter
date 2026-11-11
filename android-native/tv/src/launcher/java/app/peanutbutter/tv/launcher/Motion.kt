package app.peanutbutter.tv.launcher

import android.graphics.Outline
import android.view.View
import android.view.ViewOutlineProvider
import android.view.animation.DecelerateInterpolator
import android.view.animation.OvershootInterpolator

/** The launcher's shared motion: focus lift, rounded clipping, entrances. */
object Motion {
    private val settle = OvershootInterpolator(1.2f)
    private val ease = DecelerateInterpolator(2f)

    private fun dp(v: View, value: Float) = value * v.resources.displayMetrics.density

    /** Focused = slightly bigger and raised with a soft shadow (no outline). */
    fun lift(view: View, scale: Float = 1.05f, extra: ((Boolean) -> Unit)? = null) {
        view.setOnFocusChangeListener { v, focused -> liftNow(v, focused, scale); extra?.invoke(focused) }
    }

    fun liftNow(v: View, focused: Boolean, scale: Float) {
        raiseInList(v, focused)
        v.animate().cancel()
        v.animate()
            .scaleX(if (focused) scale else 1f)
            .scaleY(if (focused) scale else 1f)
            .translationZ(if (focused) dp(v, 14f) else 0f)
            .setInterpolator(if (focused) settle else ease)
            .setDuration(if (focused) 220 else 160)
            .start()
    }

    /**
     * Elevation only orders siblings, so a lifted tile would still be drawn
     * under the tile (or row) next to it and look cropped. Raise the list
     * item(s) that contain [v] above their neighbours too — without a shadow
     * of their own, so only the rounded card casts one.
     */
    private fun raiseInList(v: View, focused: Boolean) {
        var child: View = v
        var parent = v.parent
        while (parent is View) {
            if (parent is androidx.recyclerview.widget.RecyclerView) {
                child.outlineProvider = null
                child.translationZ = if (focused) dp(child, 2f) else 0f
            }
            child = parent
            parent = parent.parent
        }
    }

    /** Rounded shadow shape without clipping children (e.g. a badge that sits on the edge). */
    fun roundOutline(view: View, radiusDp: Float) {
        val r = dp(view, radiusDp)
        view.outlineProvider = object : ViewOutlineProvider() {
            override fun getOutline(v: View, outline: Outline) = outline.setRoundRect(0, 0, v.width, v.height, r)
        }
    }

    /**
     * A card's name: just under the card, shown while it is focused. It
     * slides down by however much the lifted card grew, so the gap stays small.
     */
    fun nameUnder(card: View, label: android.widget.TextView, focused: Boolean, scale: Float) {
        val grow = card.height * (scale - 1f) / 2f
        label.animate().cancel()
        label.animate()
            .alpha(if (focused) 1f else 0f)
            .translationY(if (focused) grow else 0f)
            .setDuration(if (focused) 220 else 140)
            .start()
    }

    fun nameLabel(context: android.content.Context) = android.widget.TextView(context).apply {
        setTextColor(androidx.core.content.ContextCompat.getColor(context, app.peanutbutter.tv.R.color.pb_white))
        setTextSize(android.util.TypedValue.COMPLEX_UNIT_SP, 13f)
        gravity = android.view.Gravity.CENTER_HORIZONTAL
        maxLines = 1
        ellipsize = android.text.TextUtils.TruncateAt.END
        alpha = 0f
    }

    /** Clip a view (and its images) to rounded corners. */
    fun round(view: View, radiusDp: Float) {
        val r = dp(view, radiusDp)
        view.outlineProvider = object : ViewOutlineProvider() {
            override fun getOutline(v: View, outline: Outline) = outline.setRoundRect(0, 0, v.width, v.height, r)
        }
        view.clipToOutline = true
    }

    /** Fade + rise in, one after another. */
    fun enter(views: List<View>, startDelay: Long = 0, step: Long = 70) {
        views.forEachIndexed { i, v ->
            v.alpha = 0f
            v.translationY = dp(v, 18f)
            v.animate().alpha(1f).translationY(0f)
                .setStartDelay(startDelay + i * step)
                .setInterpolator(ease)
                .setDuration(320)
                .start()
        }
    }

    /** Quick cross-fade while [change] swaps the content. */
    fun crossfade(view: View, change: () -> Unit) {
        view.animate().cancel()
        view.animate().alpha(0f).setDuration(120).withEndAction {
            change()
            view.animate().alpha(1f).setDuration(220).setInterpolator(ease).start()
        }.start()
    }
}
