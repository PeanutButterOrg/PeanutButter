package app.peanutbutter.tv.ui

import android.content.Intent
import android.os.Bundle
import android.view.View
import android.view.ViewGroup
import androidx.leanback.app.RowsSupportFragment
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.launch
import androidx.leanback.widget.ArrayObjectAdapter
import androidx.leanback.widget.ClassPresenterSelector
import androidx.leanback.widget.FocusHighlight
import androidx.leanback.widget.HeaderItem
import androidx.leanback.widget.HorizontalGridView
import androidx.leanback.widget.ListRow
import androidx.leanback.widget.ListRowPresenter
import androidx.leanback.widget.OnItemViewClickedListener
import androidx.leanback.widget.Presenter
import androidx.leanback.widget.PresenterSelector
import app.peanutbutter.core.HomeLayout
import app.peanutbutter.core.RankedTitle
import app.peanutbutter.core.ShelfStyle
import app.peanutbutter.core.WideTitle
import app.peanutbutter.core.SeeAllItem
import app.peanutbutter.core.TitleItem
import app.peanutbutter.tv.R
import app.peanutbutter.tv.asTv

/**
 * Flutter home body: FeaturedBanner + shelves.
 * KindSwitch lives as a fixed overlay in [MainActivity] (banner sits below it).
 */
class MainFragment : RowsSupportFragment() {
    private lateinit var rowsAdapter: ArrayObjectAdapter
    private lateinit var itemSelector: ClassPresenterSelector
    private var kind: String = "MOVIE"

    /** Last focused shelf cell — restored after detail / soft refresh. */
    private var savedRow = 0
    private var savedItem = 0
    private var savedKind: String? = null

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        super.onViewCreated(view, savedInstanceState)
        view.setBackgroundColor(0xFF0E0E12.toInt())
        // Banner art goes edge-to-edge under the fixed KindSwitch overlay (Flutter).
        // No top padding — that caused the black gap above the hero.
        verticalGridView?.clipToPadding = false
        verticalGridView?.clipChildren = false
        verticalGridView?.isVerticalScrollBarEnabled = false
        verticalGridView?.isHorizontalScrollBarEnabled = false
        verticalGridView?.overScrollMode = View.OVER_SCROLL_NEVER
        alignFocusedRows()
        // With a shelf focused, the tall hero row stayed half on screen and its
        // Details button showed through behind the top bar. Fade it out then.
        verticalGridView?.addOnChildViewHolderSelectedListener(
            object : androidx.leanback.widget.OnChildViewHolderSelectedListener() {
                override fun onChildViewHolderSelected(
                    parent: androidx.recyclerview.widget.RecyclerView,
                    child: androidx.recyclerview.widget.RecyclerView.ViewHolder?,
                    position: Int,
                    subposition: Int,
                ) {
                    val hero = parent.findViewHolderForAdapterPosition(0)?.itemView ?: return
                    hero.animate().cancel()
                    hero.animate().alpha(if (position <= 0) 1f else 0f).setDuration(180).start()
                }
            },
        )
        verticalGridView?.setOnChildLaidOutListener { _, child, position, _ ->
            val row = child.findViewById<HorizontalGridView>(androidx.leanback.R.id.row_content)
            row?.keepFocusedItemVisible()
            row?.clipChildren = false
            row?.clipToPadding = false
            if (position == 0) {
                val belowHero = resources.getDimensionPixelSize(R.dimen.hero_shelf_gap)
                child.setPadding(0, 0, 0, belowHero)
                (child.layoutParams as? ViewGroup.MarginLayoutParams)?.topMargin = 0
                row?.setPadding(0, 0, 0, 0)
            }
        }
        // Walk up and disable clipping / scrollbars on Leanback wrappers
        var p: View? = verticalGridView
        while (p != null) {
            if (p is ViewGroup) {
                p.clipChildren = false
                p.clipToPadding = false
            }
            p.isVerticalScrollBarEnabled = false
            p.isHorizontalScrollBarEnabled = false
            p.overScrollMode = View.OVER_SCROLL_NEVER
            p = p.parent as? View
        }

        itemSelector = ClassPresenterSelector().apply {
            val posters = PosterCardPresenter()
            addClassPresenter(TitleItem::class.java, posters)
            addClassPresenter(RankedTitle::class.java, posters)
            addClassPresenter(WideTitle::class.java, WideCardPresenter())
            addClassPresenter(SeeAllItem::class.java, SeeAllTextPresenter())
            addClassPresenter(
                HeroCarousel::class.java,
                HeroBannerPresenter(
                    onDetails = { openDetails(it) },
                    onPlay = { openDetails(it, play = true) },
                    onSetList = { item, on, done -> setOnList(item, on, done) },
                ),
            )
        }

        val plainRow = ListRowPresenter(FocusHighlight.ZOOM_FACTOR_NONE, false).apply {
            headerPresenter = null
            setShadowEnabled(false)
            enableChildRoundedCorners(false)
            selectEffectEnabled = false
        }
        val shelfRow = ListRowPresenter(FocusHighlight.ZOOM_FACTOR_NONE, false).apply {
            headerPresenter = ShelfHeaderPresenter()
            setShadowEnabled(false)
            enableChildRoundedCorners(false)
            selectEffectEnabled = false
        }

        val rowSelector = object : PresenterSelector() {
            override fun getPresenter(item: Any?): Presenter {
                val id = (item as? ListRow)?.headerItem?.id ?: -1L
                return when (id) {
                    HERO_ROW_ID -> plainRow
                    else -> shelfRow
                }
            }

            override fun getPresenters(): Array<Presenter> = arrayOf(plainRow, shelfRow)
        }

        rowsAdapter = ArrayObjectAdapter(rowSelector)
        adapter = rowsAdapter

        onItemViewClickedListener = OnItemViewClickedListener { _, item, _, _ ->
            when (item) {
                is TitleItem -> openDetails(item)
                is RankedTitle -> openDetails(item.item)
                is WideTitle -> openDetails(item.item)
                is HeroCarousel -> item.current()?.let { openDetails(it) }
                is SeeAllItem -> openCatalog(item)
            }
        }
    }

    fun scrollToTop() {
        if (!::rowsAdapter.isInitialized || rowsAdapter.size() == 0) return
        setSelectedPosition(0, false)
        verticalGridView?.scrollToPosition(0)
        alignFocusedRows()
    }

    private fun alignFocusedRows() {
        val grid = verticalGridView ?: return
        grid.keepFocusedItemVisible()
        val bottom = (24 * resources.displayMetrics.density).toInt()
        grid.setPadding(0, 0, 0, bottom)
    }

    /** Snapshot focused row + poster before leaving for Details. */
    fun captureBrowseFocus() {
        if (!::rowsAdapter.isInitialized) return
        val row = selectedPosition.coerceAtLeast(0)
        savedRow = row
        savedItem = 0
        savedKind = kind
        val vh = runCatching { getRowViewHolder(row) }.getOrNull() as? ListRowPresenter.ViewHolder
        savedItem = vh?.gridView?.selectedPosition?.coerceAtLeast(0) ?: 0
    }

    /** Restore focus after returning from Details (adapter unchanged). */
    fun restoreBrowseFocus() {
        if (!::rowsAdapter.isInitialized || rowsAdapter.size() == 0) return
        if (savedKind != null && savedKind != kind) return
        val row = savedRow.coerceIn(0, rowsAdapter.size() - 1)
        setSelectedPosition(row, false)
        view?.post {
            alignFocusedRows()
            val vh = runCatching { getRowViewHolder(row) }.getOrNull() as? ListRowPresenter.ViewHolder
            val grid = vh?.gridView
            if (grid != null && grid.adapter != null) {
                val max = (grid.adapter?.itemCount ?: 1) - 1
                val item = savedItem.coerceIn(0, max.coerceAtLeast(0))
                grid.setSelectedPosition(item)
                grid.requestFocus()
            } else {
                verticalGridView?.requestFocus()
            }
        }
    }

    /**
     * @param section HOME, MOVIE or SERIES (see [app.peanutbutter.core.HomeSections])
     * @param restoreFocus restore previously captured cell after a rebuild
     * @param jumpToHero when true (section switch), select hero without scroll animation
     */
    fun bindLayout(
        section: String,
        layout: HomeLayout,
        restoreFocus: Boolean = false,
        jumpToHero: Boolean = false,
        /** Cached section swap — keep grid visible so the hero doesn't fade thrice. */
        keepVisible: Boolean = false,
    ) {
        if (!::rowsAdapter.isInitialized) return
        this.kind = section
        val grid = verticalGridView
        if (!keepVisible) {
            // Hide shelves during cold rebuild so stale posters never flash under the new hero.
            grid?.alpha = 0f
        }
        rowsAdapter.clear()
        var id = 2L

        if (layout.hero.isNotEmpty()) {
            val heroList = ArrayObjectAdapter(itemSelector)
            heroList.add(HeroCarousel(layout.hero, layout.eyebrows))
            rowsAdapter.add(ListRow(HeaderItem(HERO_ROW_ID, ""), heroList))
        }

        for (shelf in layout.shelves) {
            if (shelf.items.isEmpty()) continue
            val list = ArrayObjectAdapter(itemSelector)
            shelf.items.take(18).forEachIndexed { i, item ->
                list.add(
                    when (shelf.style) {
                        ShelfStyle.TOP10 -> RankedTitle(i + 1, item)
                        ShelfStyle.WIDE -> WideTitle(item)
                        ShelfStyle.POSTER -> item
                    },
                )
            }
            rowsAdapter.add(ListRow(ShelfHeaderItem(id++, shelf.title, shelf.kind, shelf.sort), list))
        }

        when {
            restoreFocus -> {
                view?.post {
                    restoreBrowseFocus()
                    if (!keepVisible) revealBrowse()
                }
            }
            jumpToHero -> {
                setSelectedPosition(0, false)
                view?.post {
                    alignFocusedRows()
                    if (!keepVisible) revealBrowse()
                }
            }
            else -> {
                setSelectedPosition(0, false)
                view?.post {
                    alignFocusedRows()
                    verticalGridView?.requestFocus()
                    if (!keepVisible) revealBrowse()
                }
            }
        }
        if (keepVisible) {
            grid?.animate()?.cancel()
            grid?.alpha = 1f
        }
    }

    /**
     * Update Continue watching in place — no adapter wipe, focus stays put.
     * Removes the shelf (and its header) when the list becomes empty.
     */
    fun updateContinueWatching(items: List<TitleItem>): Boolean {
        if (!::rowsAdapter.isInitialized) return false
        for (i in 0 until rowsAdapter.size()) {
            val row = rowsAdapter[i] as? ListRow ?: continue
            val header = row.headerItem as? ShelfHeaderItem ?: continue
            if (header.sort != "CONTINUE_WATCHING") continue
            if (items.isEmpty()) {
                rowsAdapter.remove(row)
                return true
            }
            val list = row.adapter as? ArrayObjectAdapter ?: return false
            // Diff instead of clear + add: re-adding every card made the whole
            // home screen blink on each return from Details.
            list.setItems(items.take(18).map { WideTitle(it) }, wideDiff)
            return true
        }
        // Shelf missing (was empty) — caller should full-bind if items is non-empty.
        return items.isEmpty()
    }

    private val wideDiff = object : androidx.leanback.widget.DiffCallback<WideTitle>() {
        override fun areItemsTheSame(oldItem: WideTitle, newItem: WideTitle) = oldItem.item.id == newItem.item.id
        override fun areContentsTheSame(oldItem: WideTitle, newItem: WideTitle) = oldItem == newItem
    }

    private fun revealBrowse() {
        val grid = verticalGridView ?: return
        if (grid.alpha >= 0.99f) return
        grid.animate().cancel()
        grid.animate().alpha(1f).setDuration(160L).start()
    }

    private fun openDetails(item: TitleItem, play: Boolean = false) {
        captureBrowseFocus()
        startActivity(
            Intent(requireContext(), DetailsActivity::class.java)
                .putExtra(DetailsActivity.EXTRA_ID, item.id)
                .putExtra(DetailsActivity.EXTRA_TITLE, item.displayTitle)
                .putExtra(DetailsActivity.EXTRA_AUTOPLAY, play),
        )
    }

    /** My List from the hero: the favourite, as on the title page. */
    private fun setOnList(item: TitleItem, on: Boolean, done: (Boolean) -> Unit) {
        val app = requireActivity().application.asTv()
        viewLifecycleOwner.lifecycleScope.launch {
            val ok = runCatching { app.api.setFavorite(item.id, on) }.isSuccess
            if (ok) UserStateEdits.setFavorite(item.id, on)
            done(ok)
        }
    }

    private fun openCatalog(item: SeeAllItem) {
        captureBrowseFocus()
        startActivity(
            Intent(requireContext(), CatalogActivity::class.java)
                .putExtra(CatalogActivity.EXTRA_TITLE, item.title)
                .putExtra(CatalogActivity.EXTRA_KIND, item.kind)
                .putExtra(CatalogActivity.EXTRA_SORT, item.sort),
        )
    }

    companion object {
        const val HERO_ROW_ID = 0L
    }
}
