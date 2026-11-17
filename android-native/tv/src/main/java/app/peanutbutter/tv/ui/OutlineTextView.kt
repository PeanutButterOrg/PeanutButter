package app.peanutbutter.tv.ui

import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.util.AttributeSet
import androidx.appcompat.widget.AppCompatTextView

/** Text drawn as an outline only: the Top 10 rank numbers. */
class OutlineTextView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
) : AppCompatTextView(context, attrs) {
    private val strokePx = 2.5f * resources.displayMetrics.density

    override fun onDraw(canvas: Canvas) {
        paint.style = Paint.Style.STROKE
        paint.strokeWidth = strokePx
        paint.strokeJoin = Paint.Join.ROUND
        super.onDraw(canvas)
    }
}
