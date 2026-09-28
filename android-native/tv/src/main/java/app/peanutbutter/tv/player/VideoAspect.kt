package app.peanutbutter.tv.player

import android.view.Gravity
import android.view.View
import android.widget.FrameLayout

/**
 * Sizes the video surface itself. Many TV decoders stretch the picture to
 * whatever rectangle the surface occupies, so the surface has to be the
 * right shape — a ratio flag on the player is not enough.
 */
internal object VideoAspect {
    data class Box(val width: Int, val height: Int)

    fun target(
        mode: String,
        viewW: Int,
        viewH: Int,
        videoW: Int,
        videoH: Int,
    ): Box {
        val vw = viewW.coerceAtLeast(1)
        val vh = viewH.coerceAtLeast(1)
        if (mode == "stretch") return Box(vw, vh)
        if (mode == "original" && videoW > 0 && videoH > 0) {
            val scale = minOf(vw.toFloat() / videoW, vh.toFloat() / videoH).coerceAtMost(1f)
            return Box(
                (videoW * scale).toInt().coerceAtLeast(1),
                (videoH * scale).toInt().coerceAtLeast(1),
            )
        }
        val ratio = when (mode) {
            "16:9" -> 16f / 9f
            "4:3" -> 4f / 3f
            else -> if (videoW > 0 && videoH > 0) videoW.toFloat() / videoH else 16f / 9f
        }
        val viewRatio = vw.toFloat() / vh
        val cover = mode == "fill"
        return if (ratio > viewRatio) {
            if (cover) Box((vh * ratio).toInt().coerceAtLeast(1), vh)
            else Box(vw, (vw / ratio).toInt().coerceAtLeast(1))
        } else {
            if (cover) Box(vw, (vw / ratio).toInt().coerceAtLeast(1))
            else Box((vh * ratio).toInt().coerceAtLeast(1), vh)
        }
    }

    fun place(frame: View, box: Box) {
        val lp = frame.layoutParams ?: return
        val gravity = (lp as? FrameLayout.LayoutParams)?.gravity ?: Gravity.CENTER
        if (lp.width == box.width && lp.height == box.height) return
        lp.width = box.width
        lp.height = box.height
        if (lp is FrameLayout.LayoutParams) lp.gravity = gravity
        frame.layoutParams = lp
    }

    fun viewport(frame: View): Pair<Int, Int> {
        val parent = frame.parent as? View
        val w = parent?.width ?: 0
        val h = parent?.height ?: 0
        if (w > 0 && h > 0) return w to h
        val dm = frame.resources.displayMetrics
        return dm.widthPixels to dm.heightPixels
    }
}
