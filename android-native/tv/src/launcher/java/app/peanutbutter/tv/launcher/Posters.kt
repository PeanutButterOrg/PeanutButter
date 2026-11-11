package app.peanutbutter.tv.launcher

import android.content.Context
import android.widget.ImageView
import app.peanutbutter.tv.R
import com.bumptech.glide.Glide
import com.bumptech.glide.RequestBuilder
import com.bumptech.glide.load.DecodeFormat
import com.bumptech.glide.load.engine.DiskCacheStrategy
import android.graphics.drawable.Drawable

/**
 * Poster images for the launcher's rows. Loads and preloads use exactly the
 * same size and options, so preloaded posters come straight from memory and
 * a tab switch shows them at once.
 */
object Posters {
    private fun request(context: Context, url: String?): RequestBuilder<Drawable> {
        val d = context.resources.displayMetrics.density
        val w = (HomeContent.POSTER_W * d).toInt()
        val h = (HomeContent.POSTER_H * d).toInt()
        return Glide.with(context)
            .load(url)
            .format(DecodeFormat.PREFER_RGB_565)
            .override(w, h)
            .centerCrop()
            .diskCacheStrategy(DiskCacheStrategy.AUTOMATIC)
            .dontAnimate()
    }

    fun load(view: ImageView, url: String?) {
        request(view.context, url)
            .placeholder(R.drawable.poster_placeholder)
            .error(R.drawable.poster_placeholder)
            .into(view)
    }

    fun preload(context: Context, urls: List<String>) {
        urls.distinct().forEach { request(context, it).preload() }
    }
}
