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
     * Top 10: draw the digits as tall as the view (their real ink, not the
     * font's line box), sitting on its bottom edge and right-aligned; narrowed
     * only when "10" would not fit the width. Same proportions as desktop.
     */
    var fitToBox = false
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
        val room = height - strokePx * 2
        paint.textSize = 100f
        paint.getTextBounds(s, 0, s.length, ink)
        if (ink.height() <= 0) return
        paint.textSize = 100f * room / ink.height()
        paint.getTextBounds(s, 0, s.length, ink)
        val scaleX = minOf(1f, (width - strokePx * 2) / ink.width().coerceAtLeast(1))
        canvas.save()
        canvas.translate(width - strokePx, height - strokePx)
        canvas.scale(scaleX, 1f)
        canvas.drawText(s, -ink.right.toFloat(), -ink.bottom.toFloat(), paint)
        canvas.restore()
    }
}
