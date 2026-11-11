package app.peanutbutter.tv.launcher

import android.content.Context
import android.graphics.Rect
import android.text.TextUtils
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.TextView
import androidx.core.content.ContextCompat
import androidx.core.view.isVisible
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import app.peanutbutter.core.ServiceBadges
import app.peanutbutter.core.TitleItem
import app.peanutbutter.tv.R

/** What a tab shows, top to bottom. */
sealed class Section {
    data class Hero(val slides: List<HeroCarousel.Slide>) : Section()
    object Apps : Section()
    /** [sort] / [kind] open the full grid ("See all"), like the TV app's shelves. */
    data class Posters(val title: String, val items: List<TitleItem>, val sort: String, val kind: String?) : Section()
}

/**
 * The scrolling part of the home screen. Each section is one row; the
 * focused row always settles just under the header (no half-hidden rows).
 */
class HomeContent(
    private val context: Context,
    private val apps: AppsRow,
    private val onTitle: (TitleItem) -> Unit,
    private val onSeeAll: (Section.Posters) -> Unit,
) : RecyclerView.Adapter<RecyclerView.ViewHolder>() {
    private var sections: List<Section> = emptyList()
    private fun dp(v: Int) = (v * context.resources.displayMetrics.density).toInt()

    fun submit(newSections: List<Section>) {
        val old = sections
        sections = newSections
        // Exact inserts / removals / changes, never a full rebuild: the focused
        // view stays attached (a rebuild dropped focus onto the top bar).
        androidx.recyclerview.widget.DiffUtil.calculateDiff(object : androidx.recyclerview.widget.DiffUtil.Callback() {
            override fun getOldListSize() = old.size
            override fun getNewListSize() = newSections.size
            override fun areItemsTheSame(o: Int, n: Int) = identity(old[o]) == identity(newSections[n])
            override fun areContentsTheSame(o: Int, n: Int) = same(old[o], newSections[n])
        }, false).dispatchUpdatesTo(this)
    }

    /** Which row this is: the carousel, the apps, or a poster row by its title. */
    private fun identity(s: Section): String = when (s) {
        is Section.Hero -> "hero"
        Section.Apps -> "apps"
        is Section.Posters -> "posters:${s.title}"
    }

    /** Slides hold click lambdas, so compare what they show. */
    private fun same(a: Section, b: Section): Boolean = when {
        a is Section.Hero && b is Section.Hero -> a.slides.map { it.key to it.progress } == b.slides.map { it.key to it.progress }
        else -> a == b
    }

    /** Vertical list that scrolls the focused section to the top edge. */
    fun layoutManager() = object : LinearLayoutManager(context) {
        override fun requestChildRectangleOnScreen(
            parent: RecyclerView,
            child: View,
            rect: Rect,
            immediate: Boolean,
            focusedChildVisible: Boolean,
        ): Boolean {
            val dy = child.top - parent.paddingTop
            if (dy != 0) {
                if (immediate) parent.scrollBy(0, dy) else parent.smoothScrollBy(0, dy)
            }
            return true
        }
    }

    override fun getItemCount() = sections.size
    override fun getItemViewType(position: Int) = when (sections[position]) {
        is Section.Hero -> 0
        Section.Apps -> 1
        is Section.Posters -> 2
    }

    override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): RecyclerView.ViewHolder = when (viewType) {
        0 -> object : RecyclerView.ViewHolder(
            FrameLayout(context).apply {
                layoutParams = RecyclerView.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(300))
                setPadding(dp(48), 0, dp(48), dp(8))
                clipChildren = false
                clipToPadding = false
                addView(HeroCarousel(context), FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
            },
        ) {}
        1 -> object : RecyclerView.ViewHolder(row(context.getString(R.string.your_apps), apps)) {}
        else -> PosterRowHolder()
    }

    override fun onBindViewHolder(holder: RecyclerView.ViewHolder, position: Int) {
        when (val s = sections[position]) {
            is Section.Hero -> ((holder.itemView as ViewGroup).getChildAt(0) as HeroCarousel).setSlides(s.slides)
            Section.Apps -> Unit
            is Section.Posters -> (holder as PosterRowHolder).bind(s)
        }
    }

    /** Section title + horizontal list. */
    private fun row(title: String, adapter: RecyclerView.Adapter<*>): LinearLayout {
        val list = RecyclerView(context).apply {
            id = R.id.launcher_row_list
            layoutManager = LinearLayoutManager(context, LinearLayoutManager.HORIZONTAL, false)
            this.adapter = adapter
            clipChildren = false
            clipToPadding = false
            setPadding(dp(40), 0, dp(40), 0)
            // No change animations: a background refresh must not swap in a copy
            // of the focused card (that left square shadows and an unlifted card).
            itemAnimator = null
        }
        return LinearLayout(context).apply {
            id = R.id.launcher_row
            orientation = LinearLayout.VERTICAL
            clipChildren = false
            clipToPadding = false
            layoutParams = RecyclerView.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT)
            setPadding(0, dp(18), 0, dp(4))
            addView(TextView(context).apply {
                id = R.id.launcher_row_title
                text = title
                setTextColor(ContextCompat.getColor(context, R.color.pb_white))
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 19f)
                setTypeface(typeface, android.graphics.Typeface.BOLD)
                setPadding(dp(48), 0, dp(48), dp(4))
            })
            addView(list, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        }
    }

    inner class PosterRowHolder : RecyclerView.ViewHolder(row("", PosterAdapter())) {
        private val title = itemView.findViewById<TextView>(R.id.launcher_row_title)
        private val list = itemView.findViewById<RecyclerView>(R.id.launcher_row_list)

        fun bind(s: Section.Posters) {
            title.text = s.title
            (list.adapter as PosterAdapter).submit(s)
        }
    }

    /** Rounded poster cards; lift on focus, title fades in underneath. */
    inner class PosterAdapter : RecyclerView.Adapter<RecyclerView.ViewHolder>() {
        private var items: List<TitleItem> = emptyList()
        private var section: Section.Posters? = null

        fun submit(s: Section.Posters) {
            section = s
            val newItems = s.items
            if (newItems == items) return
            if (newItems.map { it.id } == items.map { it.id }) {
                // Same titles: rebind only the ones whose state changed (watched, favourite, progress).
                val old = items
                items = newItems
                newItems.indices.filter { newItems[it] != old[it] }.forEach { notifyItemChanged(it) }
            } else {
                items = newItems
                notifyDataSetChanged()
            }
        }

        // Last card: "See all".
        override fun getItemCount() = if (items.isEmpty()) 0 else items.size + 1
        override fun getItemViewType(position: Int) = if (position < items.size) 0 else 1

        override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): RecyclerView.ViewHolder {
            if (viewType == 1) return seeAllHolder()
            val image = ImageView(context).apply {
                id = R.id.launcher_poster_image
                scaleType = ImageView.ScaleType.CENTER_CROP
            }
            val bar = ProgressBar(context, null, android.R.attr.progressBarStyleHorizontal).apply {
                id = R.id.launcher_poster_progress
                max = 100
                progressDrawable = ContextCompat.getDrawable(context, R.drawable.launcher_progress)
            }
            // Top-left: the streaming service; top-right: favourite / watched.
            val service = LinearLayout(context).apply {
                id = R.id.launcher_poster_service
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER
                background = ContextCompat.getDrawable(context, R.drawable.launcher_chip_bg)
                setPadding(dp(8), 0, dp(8), 0)
            }
            val state = LinearLayout(context).apply {
                id = R.id.launcher_poster_state
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER
                background = ContextCompat.getDrawable(context, R.drawable.launcher_chip_bg)
                setPadding(dp(7), 0, dp(7), 0)
            }
            val card = FrameLayout(context).apply {
                background = ContextCompat.getDrawable(context, R.drawable.launcher_app_bg)
                Motion.round(this, 16f)
                addView(image, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
                addView(service, FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, dp(22), Gravity.TOP or Gravity.START).apply {
                    setMargins(dp(8), dp(8), 0, 0)
                })
                addView(state, FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, dp(22), Gravity.TOP or Gravity.END).apply {
                    setMargins(0, dp(8), dp(8), 0)
                })
                addView(bar, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(4), Gravity.BOTTOM).apply {
                    setMargins(dp(10), 0, dp(10), dp(10))
                })
            }
            val name = Motion.nameLabel(context).apply { id = R.id.launcher_poster_label }
            val root = LinearLayout(context).apply {
                orientation = LinearLayout.VERTICAL
                // Let the lifted card grow past this item's padding (else its top is cut square).
                clipChildren = false
                clipToPadding = false
                isFocusable = true
                isFocusableInTouchMode = true
                layoutParams = RecyclerView.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT)
                setPadding(dp(8), dp(12), dp(8), dp(4))
                addView(card, LinearLayout.LayoutParams(dp(POSTER_W), dp(POSTER_H)))
                addView(name, LinearLayout.LayoutParams(dp(POSTER_W), ViewGroup.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(4) })
                setOnFocusChangeListener { _, focused ->
                    Motion.liftNow(card, focused, 1.08f)
                    Motion.nameUnder(card, name, focused, 1.08f)
                }
            }
            return object : RecyclerView.ViewHolder(root) {}
        }

        /**
         * "See all" at the end of the row: a round arrow button, centred on the
         * posters' height, with its name under it. Lifts when focused.
         */
        private fun seeAllHolder(): RecyclerView.ViewHolder {
            val circle = FrameLayout(context).apply {
                background = ContextCompat.getDrawable(context, R.drawable.launcher_see_all_circle)
                addView(ImageView(context).apply {
                    setImageResource(R.drawable.ic_arrow_forward)
                    imageTintList = android.content.res.ColorStateList.valueOf(ContextCompat.getColor(context, R.color.pb_white))
                }, FrameLayout.LayoutParams(dp(28), dp(28), Gravity.CENTER))
            }
            val arrow = circle.getChildAt(0) as ImageView
            val name = TextView(context).apply {
                setText(R.string.see_all)
                setTextColor(ContextCompat.getColor(context, R.color.pb_muted))
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
                setTypeface(typeface, android.graphics.Typeface.BOLD)
                gravity = Gravity.CENTER
            }
            val column = LinearLayout(context).apply {
                orientation = LinearLayout.VERTICAL
                gravity = Gravity.CENTER
                clipChildren = false
                addView(circle, LinearLayout.LayoutParams(dp(64), dp(64)))
                addView(name, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(12) })
            }
            val root = FrameLayout(context).apply {
                clipChildren = false
                clipToPadding = false
                isFocusable = true
                isFocusableInTouchMode = true
                layoutParams = RecyclerView.LayoutParams(dp(SEE_ALL_W + 16), ViewGroup.LayoutParams.WRAP_CONTENT)
                setPadding(dp(8), dp(12), dp(8), dp(4))
                // Same height as a poster, so it sits centred on the row.
                addView(column, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(POSTER_H)))
                setOnFocusChangeListener { _, focused ->
                    circle.isSelected = focused
                    name.setTextColor(ContextCompat.getColor(context, if (focused) R.color.pb_white else R.color.pb_muted))
                    Motion.liftNow(circle, focused, 1.12f)
                }
                setOnClickListener { section?.let(onSeeAll) }
                contentDescription = context.getString(R.string.see_all)
            }
            return object : RecyclerView.ViewHolder(root) {}
        }

        override fun onBindViewHolder(holder: RecyclerView.ViewHolder, position: Int) {
            if (position >= items.size) return
            val item = items[position]
            val v = holder.itemView
            Posters.load(v.findViewById(R.id.launcher_poster_image), item.posterUrl ?: item.backdropUrl)
            v.findViewById<ProgressBar>(R.id.launcher_poster_progress).apply {
                // Same rule as the TV app's cards; watched titles get the tick instead.
                val pct = progressPercentOf(item)
                isVisible = pct > 0
                progress = pct
            }
            v.findViewById<TextView>(R.id.launcher_poster_label).text = item.displayTitle
            bindService(v.findViewById(R.id.launcher_poster_service), item)
            bindState(v.findViewById(R.id.launcher_poster_state), item)
            v.contentDescription = item.displayTitle
            v.setOnClickListener { onTitle(item) }
        }
    }

    /** One mark for the service the title is on: its logo in brand colour, or a short text mark. */
    private fun bindService(chip: LinearLayout, item: TitleItem) {
        chip.removeAllViews()
        val tag = item.services.firstOrNull()
        chip.isVisible = tag != null
        if (tag == null) return
        val badge = ServiceBadges.of(tag)
        val logo = SERVICE_LOGOS[tag.id]
        val color = readable(tag.id, badge.color)
        if (logo != null) {
            // Logo at its own proportions, same height in every chip.
            chip.addView(ImageView(context).apply {
                setImageResource(logo)
                imageTintList = android.content.res.ColorStateList.valueOf(color)
                adjustViewBounds = true
                scaleType = ImageView.ScaleType.FIT_CENTER
            }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, dp(13)))
        } else {
            chip.addView(TextView(context).apply {
                text = badge.label
                setTextColor(color)
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 11f)
                setTypeface(typeface, android.graphics.Typeface.BOLD)
                includeFontPadding = false
                gravity = Gravity.CENTER
            }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.MATCH_PARENT))
        }
    }

    /** Brand colour, except Disney+'s dark blue, which vanishes on the dark badge: white. */
    private fun readable(serviceId: String, color: Int): Int =
        if (serviceId in WHITE_ON_BADGE) 0xFFFFFFFF.toInt() else color

    private fun bindState(chip: LinearLayout, item: TitleItem) {
        chip.removeAllViews()
        chip.isVisible = item.favorite || item.watched
        listOfNotNull(
            R.drawable.ic_favorite.takeIf { item.favorite },
            R.drawable.ic_check.takeIf { item.watched },
        ).forEachIndexed { i, icon ->
            chip.addView(ImageView(context).apply { setImageResource(icon) },
                LinearLayout.LayoutParams(dp(14), dp(14)).apply { if (i > 0) marginStart = dp(4) })
        }
    }

    companion object {
        /**
         * 0–100 for the progress bars. The server sends a 0–1 fraction (rounding
         * it as a percentage left every bar empty); a just-started title still
         * gets a visible sliver.
         */
        fun progressPercentOf(item: TitleItem): Int {
            val p = item.watchProgress
            if (item.watched || (p <= 0.0 && !item.canResume)) return 0
            return (p * 100).toInt().coerceIn(8, 98)
        }

        private val WHITE_ON_BADGE = setOf("disney")

        /** Same logo set as the TV app's poster cards. */
        private val SERVICE_LOGOS = mapOf(
            "netflix" to R.drawable.ic_service_netflix,
            "disney" to R.drawable.ic_service_disney,
            "hbo" to R.drawable.ic_service_hbo,
            "apple" to R.drawable.ic_service_apple,
            "paramount" to R.drawable.ic_service_paramount,
            "crunchyroll" to R.drawable.ic_service_crunchyroll,
            "mubi" to R.drawable.ic_service_mubi,
            "starz" to R.drawable.ic_service_starz,
            "showtime" to R.drawable.ic_service_showtime,
        )
        const val SEE_ALL_W = 104
        const val POSTER_W = 128
        const val POSTER_H = 192
    }
}
