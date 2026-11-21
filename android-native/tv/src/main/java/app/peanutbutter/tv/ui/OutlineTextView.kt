package app.peanutbutter.tv.ui

import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Rect
import android.util.AttributeSet
import androidx.appcompat.widget.AppCompatTextView

/** Text drawn as an outline only: the Top 10 rank numbers. */
class OutlineTextView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
) : AppCompatTextView(context, attrs) {
    private val strokePx = 2.5f * resources.displayMetrics.density
    private val ink = Rect()

    /**
     * Top 10, as on Netflix: digits in their natural shape (never squeezed),
     * [heightFraction] of the view's height, standing on its bottom edge, and
     * with [tuckFraction] of each digit's width under the poster beside it. "10" is drawn smaller
     * (same shape) when it would not fit.
     */
    var fitToBox = false
        set(value) {
            field = value
            invalidate()
        }

    var heightFraction = 0.78f
        set(value) {
            field = value
            invalidate()
        }

    /** Share of the digits' width that sits under the poster to their right. */
    var tuckFraction = 0f
        set(value) {
            field = value
            invalidate()
        }

    override fun onDraw(canvas: Canvas) {
        paint.style = Paint.Style.STROKE
        paint.strokeWidth = strokePx
        paint.strokeJoin = Paint.Join.ROUND
        if (!fitToBox) {
            super.onDraw(canvas)
            return
        }
        val s = text?.toString().orEmpty()
        if (s.isEmpty() || width <= 0 || height <= 0) return
        paint.color = currentTextColor
        paint.textSize = 100f
        paint.getTextBounds(s, 0, s.length, ink)
        if (ink.height() <= 0 || ink.width() <= 0) return
        val byHeight = 100f * (height - strokePx * 2) * heightFraction / ink.height()
        // Every single digit sized from the widest ("8"), so 1–9 stand equally tall.
        val sizing = if (s.length == 1) "8" else s
        val sizingInk = Rect().also { paint.getTextBounds(sizing, 0, sizing.length, it) }
        val byWidth = 100f * (width - strokePx * 2) / (sizingInk.width() * (1f - tuckFraction))
        paint.textSize = minOf(byHeight, byWidth)
        paint.getTextBounds(s, 0, s.length, ink)
        canvas.drawText(
            s,
            width + ink.width() * tuckFraction - strokePx - ink.right,
            height - strokePx - ink.bottom,
            paint,
        )
    }
}
