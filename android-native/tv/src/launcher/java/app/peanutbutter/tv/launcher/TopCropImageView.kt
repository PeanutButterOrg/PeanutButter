package app.peanutbutter.tv.launcher

import android.content.Context
import android.graphics.Matrix
import android.graphics.drawable.Drawable
import android.widget.ImageView

/**
 * Fills the view like centerCrop, but trims mostly from the bottom: backdrop
 * art usually has faces and titles in its upper part, so those stay in the
 * wide carousel card. [bias] 0 = keep the very top, 0.5 = centerCrop.
 */
class TopCropImageView(context: Context, private val bias: Float = 0.2f) : ImageView(context) {
    init {
        scaleType = ScaleType.MATRIX
    }

    override fun setFrame(l: Int, t: Int, r: Int, b: Int): Boolean {
        val changed = super.setFrame(l, t, r, b)
        fit()
        return changed
    }

    override fun setImageDrawable(drawable: Drawable?) {
        super.setImageDrawable(drawable)
        fit()
    }

    private fun fit() {
        val d = drawable ?: return
        val vw = width - paddingLeft - paddingRight
        val vh = height - paddingTop - paddingBottom
        val dw = d.intrinsicWidth
        val dh = d.intrinsicHeight
        if (vw <= 0 || vh <= 0 || dw <= 0 || dh <= 0) return
        val scale = maxOf(vw.toFloat() / dw, vh.toFloat() / dh)
        val dx = (vw - dw * scale) / 2f
        val dy = (vh - dh * scale) * bias
        imageMatrix = Matrix().apply {
            setScale(scale, scale)
            postTranslate(dx, dy)
        }
    }
}
