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

class HeroCarousel(
    val items: List<TitleItem>,
    /** One line per slide, e.g. "#1 trending · Movie". */
    val eyebrows: List<String> = emptyList(),
) {
    @Volatile
    var index: Int = 0

    /** My List taps not yet in the feed (title id -> on the list). */
    val listed = HashMap<String, Boolean>()

    fun current(): TitleItem? = items.getOrNull(index % items.size.coerceAtLeast(1))

    fun eyebrow(): String? = eyebrows.getOrNull(index % items.size.coerceAtLeast(1))

    fun onList(item: TitleItem): Boolean = listed[item.id] ?: item.favorite
}

/**
 * Full-bleed featured banner. Auto-advances every 5s with a 900ms crossfade,
 * matching the phone and desktop home carousel (those screens are not paused
 * just because the banner is focused).
 */
class HeroBannerPresenter(
    private val onDetails: (TitleItem) -> Unit,
    /** Play: open the title and start it. */
    private val onPlay: (TitleItem) -> Unit = onDetails,
    /** My List: set the favourite; the callback reports whether it worked. */
    private val onSetList: (TitleItem, Boolean, (Boolean) -> Unit) -> Unit = { _, _, done -> done(false) },
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
        vh.onPlay = onPlay
        vh.onSetList = onSetList
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
        var onPlay: ((TitleItem) -> Unit)? = null
        var onSetList: ((TitleItem, Boolean, (Boolean) -> Unit) -> Unit)? = null
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
                    // hasWindowFocus: pause while the player / another screen is on
                    // top — attached-but-hidden banners kept reloading art every 5 s.
                    if (view.isAttachedToWindow && view.hasWindowFocus() &&
                        carousel != null && carousel.items.size > 1
                    ) {
                        carousel.index = (carousel.index + 1) % carousel.items.size
                        bindCurrent(animate = true)
                    }
                    handler.postDelayed(this, ROTATE_MS)
                }
            }
            rotate = tick
            handler.postDelayed(tick, ROTATE_MS)
        }

        fun wireControls() {
            val play = view.findViewById<View>(R.id.hero_details)
            val list = view.findViewById<View>(R.id.hero_mylist)
            val info = view.findViewById<View>(R.id.hero_info)
            play.setOnClickListener { model?.current()?.let { onPlay?.invoke(it) } }
            info.setOnClickListener { model?.current()?.let { onDetails?.invoke(it) } }
            list.setOnClickListener {
                val m = model ?: return@setOnClickListener
                val item = m.current() ?: return@setOnClickListener
                val next = !m.onList(item)
                m.listed[item.id] = next
                bindListButton()
                onSetList?.invoke(item, next) { ok ->
                    if (!ok) {
                        m.listed[item.id] = !next
                        bindListButton()
                    }
                }
            }
            // Moving between the buttons gives the slide a fresh 8 s before it turns.
            for (button in listOf(play, list, info)) {
                button.isFocusable = true
                button.isFocusableInTouchMode = true
                button.setOnFocusChangeListener { _, has -> if (has) startAutoScroll() }
            }
            play.nextFocusLeftId = play.id
            info.nextFocusRightId = info.id
        }

        fun bindListButton() {
            val item = model?.current() ?: return
            val on = model?.onList(item) == true
            view.findViewById<ImageView>(R.id.hero_mylist_icon)
                .setImageResource(if (on) R.drawable.ic_check else R.drawable.ic_add)
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
                eyebrow.text = model?.eyebrow() ?: view.context.getString(R.string.trending_now)
                bindListButton()
                titleView.text = title.displayTitle
                // Always show plain app typography — never movie/series logo art.
                logo.isVisible = false
                titleView.isVisible = true
                PbGlide.clear(logo)

                meta.text = heroMeta(view.context, title)
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
        private const val ROTATE_MS = 8_000L

        /** "★ 8.7 IMDb · 2014 · 2h 49m · Adventure, Sci-Fi" with an amber star. */
        fun heroMeta(context: android.content.Context, title: TitleItem): CharSequence {
            val out = android.text.SpannableStringBuilder()
            val sep = "  ·  "
            title.displayScore?.let { score ->
                if (score.rtScore == null) {
                    out.append("★", android.text.style.ForegroundColorSpan(context.getColor(R.color.pbt_primary)), 0)
                    out.append(" ")
                }
                val start = out.length
                out.append(score.label)
                out.setSpan(android.text.style.ForegroundColorSpan(context.getColor(R.color.pbt_text)), start, out.length, 0)
                out.append(" ").append(score.source)
            }
            fun add(piece: String) {
                if (out.isNotEmpty()) out.append(sep)
                out.append(piece)
            }
            title.year?.let { add(it.toString()) }
            title.runtimeMinutes?.takeIf { it > 0 }?.let { m ->
                add(if (m < 60) "${m}m" else if (m % 60 == 0) "${m / 60}h" else "${m / 60}h ${m % 60}m")
            }
            if (title.genres.isNotEmpty()) add(title.genres.take(2).joinToString(" · "))
            return out
        }

        /** Flutter HeroBannerFrame TV: ~58% viewport, clamp 460–620. */
        fun heroHeightPx(dm: DisplayMetrics): Int {
            val h = (dm.heightPixels * 0.64f).toInt()
            return h.coerceIn(
                (460 * dm.density).toInt(),
                (660 * dm.density).toInt(),
            )
        }
    }
}
