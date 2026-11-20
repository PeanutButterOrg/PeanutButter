package app.peanutbutter.tv.ui

import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.util.AttributeSet
import android.view.View
import app.peanutbutter.tv.R

/** Four signal bars for a swarm's health: green when healthy, amber when weak. */
class SignalBarsView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
) : View(context, attrs) {
    /** Bars lit, 0–4. */
    var lit: Int = 0
        set(value) {
            field = value.coerceIn(0, 4)
            invalidate()
        }

    private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val rect = RectF()

    override fun onDraw(canvas: Canvas) {
        val gap = width * 0.12f
        val barW = (width - gap * 3) / 4
        val on = context.getColor(if (lit >= 3) R.color.pbt_good else R.color.pbt_warn)
        for (i in 0 until 4) {
            val h = height * (0.35f + 0.65f * i / 3f)
            val left = i * (barW + gap)
            rect.set(left, height - h, left + barW, height.toFloat())
            paint.color = if (i < lit) on else 0x2EFFFFFF
            canvas.drawRoundRect(rect, barW / 3, barW / 3, paint)
        }
    }
}
