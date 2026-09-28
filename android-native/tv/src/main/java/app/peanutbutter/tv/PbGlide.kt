package app.peanutbutter.tv

import android.graphics.drawable.Drawable
import android.widget.ImageView
import com.bumptech.glide.Glide
import com.bumptech.glide.Priority
import com.bumptech.glide.load.DecodeFormat
import com.bumptech.glide.load.engine.DiskCacheStrategy
import com.bumptech.glide.request.RequestListener
import com.bumptech.glide.request.RequestOptions

/**
 * Glide helpers tuned for low-end Android TV:
 * RGB_565, sized decode, disk cache, no crossfade jank, low priority for shelves.
 */
object PbGlide {
    private fun base(widthPx: Int, heightPx: Int): RequestOptions {
        val w = widthPx.coerceAtLeast(1)
        val h = heightPx.coerceAtLeast(1)
        return RequestOptions()
            .format(DecodeFormat.PREFER_RGB_565)
            .disallowHardwareConfig()
            .diskCacheStrategy(DiskCacheStrategy.AUTOMATIC)
            .override(w, h)
            .centerCrop()
            .dontAnimate()
    }

    fun poster(view: ImageView, url: String?) {
        val w = view.width.takeIf { it > 0 } ?: dp(view, 152)
        val h = view.height.takeIf { it > 0 } ?: dp(view, 228)
        Glide.with(view)
            .load(url)
            .apply(base(w, h).priority(Priority.LOW))
            .placeholder(R.drawable.poster_placeholder)
            .error(R.drawable.poster_placeholder)
            .into(view)
    }

    fun backdrop(view: ImageView, url: String?, placeholderColor: Int = R.color.pb_panel) {
        val dm = view.resources.displayMetrics
        val w = (dm.widthPixels * 0.75f).toInt().coerceIn(640, 1280)
        val h = (dm.heightPixels * 0.55f).toInt().coerceIn(360, 720)
        Glide.with(view)
            .load(url)
            .apply(base(w, h).priority(Priority.NORMAL))
            .placeholder(placeholderColor)
            .into(view)
    }

    fun logo(
        view: ImageView,
        url: String?,
        listener: RequestListener<Drawable>? = null,
    ) {
        val w = dp(view, 260)
        val h = dp(view, 72)
        val req = Glide.with(view)
            .load(url)
            .apply(
                RequestOptions()
                    .format(DecodeFormat.PREFER_RGB_565)
                    .disallowHardwareConfig()
                    .diskCacheStrategy(DiskCacheStrategy.AUTOMATIC)
                    .override(w, h)
                    .fitCenter()
                    .dontAnimate(),
            )
        if (listener != null) req.listener(listener)
        req.into(view)
    }

    fun thumb(view: ImageView, url: String?, wDp: Int = 88, hDp: Int = 120) {
        val w = view.width.takeIf { it > 0 } ?: dp(view, wDp)
        val h = view.height.takeIf { it > 0 } ?: dp(view, hDp)
        Glide.with(view)
            .load(url)
            .apply(base(w, h).priority(Priority.LOW))
            .placeholder(R.drawable.poster_placeholder)
            .error(R.drawable.poster_placeholder)
            .into(view)
    }

    fun clear(view: ImageView) {
        Glide.with(view).clear(view)
    }

    private fun dp(view: ImageView, value: Int): Int =
        (value * view.resources.displayMetrics.density).toInt()
}
