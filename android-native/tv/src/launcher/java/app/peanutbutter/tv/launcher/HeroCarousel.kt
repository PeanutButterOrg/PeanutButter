package app.peanutbutter.tv.launcher

import android.content.Context
import android.graphics.drawable.Drawable
import android.text.TextUtils
import android.util.TypedValue
import android.view.Gravity
import android.view.KeyEvent
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.TextView
import androidx.core.content.ContextCompat
import androidx.core.view.isVisible
import app.peanutbutter.tv.R
import com.bumptech.glide.Glide
import com.bumptech.glide.load.DataSource
import com.bumptech.glide.load.engine.DiskCacheStrategy
import com.bumptech.glide.load.engine.GlideException
import com.bumptech.glide.request.RequestListener
import com.bumptech.glide.request.target.Target

/**
 * Big rounded card at the top of each tab, like the TV app's banner: the
 * backdrop fills the card, darkened to the left and bottom for the text, and
 * the title's logo art when it has one. Rotates on its own every few
 * seconds; ◀ ▶ flip it while focused; dots show the position.
 */
class HeroCarousel(context: Context) : FrameLayout(context) {
    data class Slide(
        /** Stable identity (title id), so a refresh doesn't restart the carousel. */
        val key: String,
        val kicker: String,
        val title: String,
        val subtitle: String,
        /** Short synopsis, two lines at most. */
        val description: String = "",
        val art: String?,
        val titleLogo: String? = null,
        val progress: Int? = null,
        /** PeanutButter logo instead of artwork (connect / offline cards). */
        val appLogo: Boolean = false,
        val onClick: () -> Unit,
    )

    private fun dp(v: Int) = (v * resources.displayMetrics.density).toInt()

    // Two art layers: the next slide's art loads into the hidden one and
    // cross-fades in only once it has actually loaded (never a grey gap).
    private val artA = art()
    private val artB = art()
    private var front = artA
    private var artUrl: String? = null

    private val appLogo = ImageView(context).apply {
        setImageResource(R.mipmap.ic_launcher)
        Motion.round(this, 24f)
        visibility = View.GONE
    }
    private val kicker = text(14f, R.color.pb_seed, bold = true)
    private val title = text(30f, R.color.pb_white, bold = true)
    private val titleLogo = ImageView(context).apply {
        scaleType = ImageView.ScaleType.FIT_START
        adjustViewBounds = false
        visibility = View.GONE
    }
    private val subtitle = text(15f, R.color.pb_white, bold = false).apply { alpha = 0.85f }
    private val description = text(14f, R.color.pb_muted, bold = false).apply {
        maxLines = 2
        setLineSpacing(0f, 1.15f)
    }
    private val progress = ProgressBar(context, null, android.R.attr.progressBarStyleHorizontal).apply {
        max = 100
        progressDrawable = ContextCompat.getDrawable(context, R.drawable.launcher_progress)
    }
    private val textBlock = LinearLayout(context).apply {
        orientation = LinearLayout.VERTICAL
        addView(kicker)
        addView(title, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(4) })
        addView(titleLogo, LinearLayout.LayoutParams(dp(300), dp(72)).apply { topMargin = dp(8) })
        addView(subtitle, LinearLayout.LayoutParams(dp(520), ViewGroup.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(8) })
        addView(description, LinearLayout.LayoutParams(dp(480), ViewGroup.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(6) })
        addView(progress, LinearLayout.LayoutParams(dp(320), dp(4)).apply { topMargin = dp(14) })
    }
    private val dots = LinearLayout(context).apply { orientation = LinearLayout.HORIZONTAL }

    private var slides: List<Slide> = emptyList()
    private var index = 0
    private val advance = Runnable { show(index + 1, animate = true); schedule() }

    init {
        background = ContextCompat.getDrawable(context, R.drawable.launcher_hero_bg)
        // Rounded corners for the art and a rounded shadow when lifted.
        Motion.round(this, 22f)
        isFocusable = true
        isFocusableInTouchMode = true
        addView(artA, LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        addView(artB, LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        artA.alpha = 0f
        artB.alpha = 0f
        // Same scrims as the TV app's banner.
        addView(View(context).apply { background = ContextCompat.getDrawable(context, R.drawable.hero_scrim_left) },
            LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        addView(View(context).apply { background = ContextCompat.getDrawable(context, R.drawable.hero_scrim_bottom) },
            LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        // Slightly dims the right side too, so the art sits back behind the text.
        addView(View(context).apply { background = ContextCompat.getDrawable(context, R.drawable.launcher_hero_dim) },
            LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        addView(appLogo, LayoutParams(dp(96), dp(96), Gravity.CENTER_VERTICAL).apply { marginStart = dp(40) })
        addView(textBlock, LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.BOTTOM).apply {
            marginStart = dp(40)
            bottomMargin = dp(32)
        })
        addView(dots, LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.BOTTOM or Gravity.END).apply {
            marginEnd = dp(32)
            bottomMargin = dp(32)
        })
        Motion.lift(this, 1.02f)
        setOnClickListener { slides.getOrNull(index)?.onClick?.invoke() }
        setOnKeyListener { _, keyCode, event ->
            if (event.action != KeyEvent.ACTION_DOWN || slides.size < 2) return@setOnKeyListener false
            when (keyCode) {
                KeyEvent.KEYCODE_DPAD_LEFT -> { show(index - 1, animate = true); schedule(); true }
                KeyEvent.KEYCODE_DPAD_RIGHT -> { show(index + 1, animate = true); schedule(); true }
                else -> false
            }
        }
    }

    /** Fills the card, trimming mostly from the bottom (faces and titles sit high in backdrops). */
    private fun art() = TopCropImageView(context).apply {
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
    }

    private fun text(sp: Float, color: Int, bold: Boolean) = TextView(context).apply {
        setTextColor(ContextCompat.getColor(context, color))
        setTextSize(TypedValue.COMPLEX_UNIT_SP, sp)
        if (bold) setTypeface(typeface, android.graphics.Typeface.BOLD)
        maxLines = 1
        ellipsize = TextUtils.TruncateAt.END
    }

    /** New list (tab change, refresh). Same titles in the same order: keep going where it is. */
    fun setSlides(newSlides: List<Slide>) {
        val same = newSlides.map { it.key } == slides.map { it.key }
        val hadSlides = slides.isNotEmpty()
        slides = newSlides
        if (same && hadSlides) return
        dots.removeAllViews()
        if (slides.size > 1) {
            slides.indices.forEach { _ ->
                dots.addView(View(context).apply { background = ContextCompat.getDrawable(context, R.drawable.launcher_dot) },
                    LinearLayout.LayoutParams(dp(6), dp(6)).apply { marginStart = dp(6) })
            }
        }
        preloadArt()
        // Cross-fade when replacing what was on screen (e.g. Movies → Series).
        show(0, animate = hadSlides)
        schedule()
    }

    private fun show(i: Int, animate: Boolean) {
        if (slides.isEmpty()) return
        index = (i + slides.size) % slides.size
        val s = slides[index]
        loadArt(s.art)
        val fill = {
            appLogo.isVisible = s.appLogo
            textBlock.layoutParams = (textBlock.layoutParams as LayoutParams).apply {
                marginStart = if (s.appLogo) dp(168) else dp(40)
                gravity = if (s.appLogo) Gravity.CENTER_VERTICAL else Gravity.BOTTOM
            }
            kicker.text = s.kicker
            title.text = s.title
            bindTitleLogo(s)
            subtitle.text = s.subtitle
            subtitle.isVisible = s.subtitle.isNotBlank()
            description.text = s.description
            description.isVisible = s.description.isNotBlank()
            progress.isVisible = s.progress != null
            progress.progress = s.progress ?: 0
            contentDescription = "${s.kicker}. ${s.title}. ${s.subtitle}"
        }
        if (animate) Motion.crossfade(textBlock, fill) else fill()
        for (d in 0 until dots.childCount) {
            val dot = dots.getChildAt(d)
            val on = d == index
            dot.animate().alpha(if (on) 1f else 0.35f).setDuration(200).start()
            dot.layoutParams = (dot.layoutParams as LinearLayout.LayoutParams).apply { width = dp(if (on) 22 else 6) }
        }
    }

    /** The title's logo art (like the TV app); plain text until it loads or when there is none. */
    private fun bindTitleLogo(s: Slide) {
        Glide.with(titleLogo).clear(titleLogo)
        titleLogo.isVisible = false
        title.isVisible = true
        val url = s.titleLogo ?: return
        Glide.with(titleLogo)
            .load(url)
            .override(dp(300), dp(72))
            .fitCenter()
            .dontAnimate()
            .listener(object : RequestListener<Drawable> {
                override fun onLoadFailed(e: GlideException?, model: Any?, target: Target<Drawable>, isFirstResource: Boolean) = false
                override fun onResourceReady(resource: Drawable, model: Any, t: Target<Drawable>?, dataSource: DataSource, isFirstResource: Boolean): Boolean {
                    if (slides.getOrNull(index)?.titleLogo != url) return false
                    titleLogo.post {
                        titleLogo.isVisible = true
                        title.isVisible = false
                    }
                    return false
                }
            })
            .into(titleLogo)
    }

    private fun artSize(): Pair<Int, Int> =
        (width.takeIf { it > 0 } ?: (resources.displayMetrics.widthPixels - dp(96))) to
            (height.takeIf { it > 0 } ?: dp(292))

    /**
     * Decode every slide's art ahead of time (same size and options as
     * [loadArt], so Glide's memory cache serves them): slide changes are then
     * an instant cross-fade with the right picture, even on a slow TV.
     */
    private fun preloadArt() {
        val (w, h) = artSize()
        slides.mapNotNull { it.art }.distinct().forEach { url ->
            Glide.with(this).load(url).override(w, w).fitCenter()
                .diskCacheStrategy(DiskCacheStrategy.AUTOMATIC).dontAnimate().preload(w, w)
        }
    }

    /** Backdrop decoded at the card's size, cross-faded in once it has loaded. */
    private fun loadArt(url: String?) {
        if (url == artUrl) return
        artUrl = url
        if (url == null) {
            listOf(artA, artB).forEach { it.animate().cancel(); it.animate().alpha(0f).setDuration(250).start() }
            return
        }
        val target = if (front === artA) artB else artA
        // Never leave the previous title's art behind this one: if the new art
        // isn't in quickly (or fails), fade the old one out.
        removeCallbacks(dropStaleArt)
        postDelayed(dropStaleArt, 700)
        val (w, h) = artSize()
        target.animate().cancel()
        target.alpha = 0f
        Glide.with(target)
            .load(url)
            // Whole image at the card's width; TopCropImageView does the crop.
            .override(w, w)
            .fitCenter()
            .diskCacheStrategy(DiskCacheStrategy.AUTOMATIC)
            .dontAnimate()
            .listener(object : RequestListener<Drawable> {
                override fun onLoadFailed(e: GlideException?, model: Any?, t: Target<Drawable>, isFirstResource: Boolean): Boolean {
                    if (artUrl == url) post(dropStaleArt)
                    return false
                }
                override fun onResourceReady(resource: Drawable, model: Any, t: Target<Drawable>?, dataSource: DataSource, isFirstResource: Boolean): Boolean {
                    if (artUrl != url) return false
                    // After Glide has put the image on the view.
                    target.post {
                        if (artUrl != url) return@post
                        removeCallbacks(dropStaleArt)
                        val old = front
                        front = target
                        target.animate().alpha(1f).setDuration(450).start()
                        if (old !== target) old.animate().alpha(0f).setDuration(450).start()
                    }
                    return false
                }
            })
            .into(target)
    }

    /** Fade out whatever art is showing (it belongs to the previous slide). */
    private val dropStaleArt = Runnable { front.animate().alpha(0f).setDuration(250).start() }

    private fun schedule() {
        removeCallbacks(advance)
        if (slides.size > 1 && isAttachedToWindow) postDelayed(advance, 7_000)
    }

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        // A fade cut short while scrolled off-screen would leave the text (or
        // art) invisible: settle the current slide fully when it comes back.
        textBlock.animate().cancel()
        textBlock.alpha = 1f
        if (slides.isNotEmpty()) {
            show(index, animate = false)
            if (front.drawable != null) {
                front.animate().cancel()
                front.alpha = 1f
            }
        }
        schedule()
    }

    override fun onDetachedFromWindow() {
        removeCallbacks(advance)
        removeCallbacks(dropStaleArt)
        super.onDetachedFromWindow()
    }
}
