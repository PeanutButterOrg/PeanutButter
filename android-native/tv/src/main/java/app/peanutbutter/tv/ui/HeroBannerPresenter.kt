package app.peanutbutter.tv.ui

import android.os.Handler
import android.os.Looper
import android.util.DisplayMetrics
import android.view.KeyEvent
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.ImageView
import android.widget.TextView
import androidx.core.view.isVisible
import androidx.leanback.widget.Presenter
import app.peanutbutter.core.TitleItem
import app.peanutbutter.tv.PbGlide
import app.peanutbutter.tv.R
import com.bumptech.glide.Glide
import com.bumptech.glide.request.RequestListener

class HeroCarousel(val items: List<TitleItem>) {
    @Volatile
    var index: Int = 0

    fun current(): TitleItem? = items.getOrNull(index % items.size.coerceAtLeast(1))
}

/**
 * Full-bleed featured banner. Auto-advances every 5s with a 900ms crossfade,
 * matching the phone and desktop home carousel (those screens are not paused
 * just because the banner is focused).
 */
class HeroBannerPresenter(
    private val onDetails: (TitleItem) -> Unit,
) : Presenter() {
    override fun onCreateViewHolder(parent: ViewGroup): ViewHolder {
        val view = LayoutInflater.from(parent.context)
            .inflate(R.layout.item_hero_banner, parent, false)
        val dm = parent.resources.displayMetrics
        // Extend under header so art fills to the top edge (no black bar)
        val height = heroHeightPx(dm)
        view.layoutParams = ViewGroup.LayoutParams(dm.widthPixels, height)
        return HeroVH(view)
    }

    override fun onBindViewHolder(viewHolder: ViewHolder, item: Any) {
        val model = item as HeroCarousel
        val vh = viewHolder as HeroVH
        vh.stop()
        if (model.items.isEmpty()) return
        vh.model = model
        vh.onDetails = onDetails
        vh.bindCurrent(animate = false)
        vh.wireControls()
        vh.startAutoScroll()
    }

    override fun onUnbindViewHolder(viewHolder: ViewHolder) {
        val vh = viewHolder as HeroVH
        vh.stop()
        Glide.with(vh.view).clear(vh.view.findViewById<ImageView>(R.id.backdrop))
        Glide.with(vh.view).clear(vh.view.findViewById<ImageView>(R.id.hero_logo))
    }

    private class HeroVH(view: View) : ViewHolder(view) {
        var model: HeroCarousel? = null
        var onDetails: ((TitleItem) -> Unit)? = null
        private val handler = Handler(Looper.getMainLooper())
        private var rotate: Runnable? = null

        fun stop() {
            rotate?.let { handler.removeCallbacks(it) }
            rotate = null
        }

        fun startAutoScroll() {
            stop()
            val m = model ?: return
            if (m.items.size < 2) return
            val tick = object : Runnable {
                override fun run() {
                    val carousel = model
                    if (view.isAttachedToWindow && carousel != null && carousel.items.size > 1) {
                        carousel.index = (carousel.index + 1) % carousel.items.size
                        bindCurrent(animate = true)
                    }
                    handler.postDelayed(this, 5_000L)
                }
            }
            rotate = tick
            handler.postDelayed(tick, 5_000L)
        }

        fun wireControls() {
            val details = view.findViewById<View>(R.id.hero_details)
            details.setOnClickListener {
                model?.current()?.let { onDetails?.invoke(it) }
            }
            details.setOnKeyListener { _, keyCode, event ->
                if (event.action != KeyEvent.ACTION_DOWN) return@setOnKeyListener false
                val m = model ?: return@setOnKeyListener false
                if (m.items.size < 2) return@setOnKeyListener false
                when (keyCode) {
                    KeyEvent.KEYCODE_DPAD_LEFT -> {
                        m.index = (m.index - 1 + m.items.size) % m.items.size
                        bindCurrent(animate = true)
                        startAutoScroll()
                        true
                    }
                    KeyEvent.KEYCODE_DPAD_RIGHT -> {
                        m.index = (m.index + 1) % m.items.size
                        bindCurrent(animate = true)
                        startAutoScroll()
                        true
                    }
                    else -> false
                }
            }
            details.isFocusable = true
            details.isFocusableInTouchMode = true
        }

        fun bindCurrent(animate: Boolean) {
            val title = model?.current() ?: return
            val backdrop = view.findViewById<ImageView>(R.id.backdrop)
            val logo = view.findViewById<ImageView>(R.id.hero_logo)
            val titleView = view.findViewById<TextView>(R.id.hero_title)
            val meta = view.findViewById<TextView>(R.id.hero_meta)
            val synopsis = view.findViewById<TextView>(R.id.hero_synopsis)
            val eyebrow = view.findViewById<TextView>(R.id.hero_eyebrow)

            val apply = {
                eyebrow.text = view.context.getString(R.string.trending_now)
                titleView.text = title.title

                if (!title.logoUrl.isNullOrBlank()) {
                    logo.isVisible = true
                    PbGlide.logo(
                        logo,
                        title.logoUrl,
                        object : RequestListener<android.graphics.drawable.Drawable> {
                            override fun onLoadFailed(
                                e: com.bumptech.glide.load.engine.GlideException?,
                                model: Any?,
                                target: com.bumptech.glide.request.target.Target<android.graphics.drawable.Drawable>,
                                isFirstResource: Boolean,
                            ): Boolean {
                                logo.isVisible = false
                                titleView.isVisible = true
                                return false
                            }

                            override fun onResourceReady(
                                resource: android.graphics.drawable.Drawable,
                                model: Any,
                                target: com.bumptech.glide.request.target.Target<android.graphics.drawable.Drawable>?,
                                dataSource: com.bumptech.glide.load.DataSource,
                                isFirstResource: Boolean,
                            ): Boolean {
                                titleView.isVisible = false
                                logo.isVisible = true
                                return false
                            }
                        },
                    )
                } else {
                    logo.isVisible = false
                    titleView.isVisible = true
                    PbGlide.clear(logo)
                }

                meta.text = buildString {
                    title.year?.let { append(it) }
                    title.runtimeMinutes?.takeIf { it > 0 }?.let {
                        if (isNotEmpty()) append("  ·  ")
                        append("${it} min")
                    }
                    (title.imdbRating ?: title.tmdbVoteAverage)?.let {
                        if (isNotEmpty()) append("  ·  ")
                        append(String.format("%.1f", it))
                    }
                    if (title.genres.isNotEmpty()) {
                        if (isNotEmpty()) append("  ·  ")
                        append(title.genres.take(3).joinToString(", "))
                    }
                }
                synopsis.text = title.synopsis.orEmpty()
                synopsis.isVisible = !title.synopsis.isNullOrBlank()

                val art = title.backdropUrl?.takeIf { it.isNotBlank() } ?: title.posterUrl
                PbGlide.backdrop(backdrop, art)
            }

            if (animate) {
                backdrop.animate().cancel()
                backdrop.animate().alpha(0.35f).setDuration(450).withEndAction {
                    apply()
                    backdrop.animate().alpha(1f).setDuration(450).start()
                }.start()
            } else {
                backdrop.alpha = 1f
                apply()
            }
        }
    }

    companion object {
        /** Flutter HeroBannerFrame TV: ~58% viewport, clamp 460–620. */
        fun heroHeightPx(dm: DisplayMetrics): Int {
            val h = (dm.heightPixels * 0.58f).toInt()
            return h.coerceIn(
                (460 * dm.density).toInt(),
                (620 * dm.density).toInt(),
            )
        }
    }
}
