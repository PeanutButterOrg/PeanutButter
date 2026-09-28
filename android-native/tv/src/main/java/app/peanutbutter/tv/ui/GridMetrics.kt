package app.peanutbutter.tv.ui

import android.content.Context
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import androidx.leanback.widget.BaseGridView
import androidx.leanback.widget.VerticalGridView
import app.peanutbutter.tv.R

/**
 * Poster size for catalog, search, and library grids.
 * Columns and card size are chosen so two full rows fit the current screen
 * and a row of cards fills the width without running past it.
 */
object GridMetrics {
    var columns: Int = 7
        private set
    var cardWidthPx: Int = 0
        private set
    var cardHeightPx: Int = 0
        private set

    fun ensure(context: Context) {
        if (cardWidthPx > 0) return
        val dm = context.resources.displayMetrics
        val density = dm.density
        val pad = (12 * density).toInt()
        val header = (64 * density).toInt()
        val vSpace = (8 * density).toInt()
        val availW = (dm.widthPixels - pad * 2).coerceAtLeast(1)
        val availH = (dm.heightPixels - header - pad * 2 - vSpace).coerceAtLeast(1)
        val rowBudget = (availH / 2).coerceAtLeast(1)
        var cols = 6
        while (cols < 12) {
            val w = availW / cols
            val h = (w * 1.42f).toInt()
            if (h <= rowBudget) break
            cols++
        }
        columns = cols
        cardWidthPx = (availW / cols).coerceAtLeast(1)
        cardHeightPx = (cardWidthPx * 1.42f).toInt().coerceAtMost(rowBudget).coerceAtLeast(1)
    }

    /** Columns and card size for a measured area, so the row fills that width and two rows fit its height. */
    fun fit(widthPx: Int, heightPx: Int, padH: Int, padV: Int, vSpace: Int): PosterGridFit {
        val availW = (widthPx - padH * 2).coerceAtLeast(1)
        val availH = (heightPx - padV * 2 - vSpace).coerceAtLeast(1)
        val rowBudget = (availH / 2).coerceAtLeast(1)
        var cols = 5
        while (cols < 14) {
            val w = availW / cols
            val h = (w * 1.42f).toInt()
            if (h <= rowBudget) break
            cols++
        }
        val cardW = (availW / cols).coerceAtLeast(1)
        val cardH = (cardW * 1.42f).toInt().coerceAtMost(rowBudget).coerceAtLeast(1)
        return PosterGridFit(cols, cardW, cardH)
    }
}

data class PosterGridFit(val columns: Int, val width: Int, val height: Int)

/**
 * Keep the focused item on the center keyline so D-pad scrolling shows the
 * whole card. The first and last items still rest against the edges, so a
 * row is not cut off and is not floated into the middle of the screen.
 */
fun BaseGridView.keepFocusedItemVisible() {
    windowAlignment = BaseGridView.WINDOW_ALIGN_BOTH_EDGE
    windowAlignmentOffset = 0
    windowAlignmentOffsetPercent = 50f
    itemAlignmentOffset = 0
    itemAlignmentOffsetPercent = 50f
    setWindowAlignmentPreferKeyLineOverLowEdge(false)
    setWindowAlignmentPreferKeyLineOverHighEdge(false)
}

/**
 * Leanback's vertical grid is wrap_content and layout_gravity=center, so a short
 * row (favourites, watched, one search hit) sits in the middle of the screen.
 * Stretch the grid to the full width and pack items to the start.
 */
fun VerticalGridView.pinPosterGrid() {
    keepFocusedItemVisible()
    setGravity(Gravity.START or Gravity.TOP)
    clipChildren = false
    clipToPadding = false
    isVerticalScrollBarEnabled = false
    isHorizontalScrollBarEnabled = false
    overScrollMode = View.OVER_SCROLL_NEVER
    val density = resources.displayMetrics.density
    val padH = resources.getDimensionPixelSize(R.dimen.shelf_inset)
    val padV = (8 * density).toInt()
    val gap = (8 * density).toInt()
    setPadding(padH, padV, padH, padV)
    setHorizontalSpacing(0)
    setVerticalSpacing(gap)
    val lp = layoutParams
    if (lp != null) {
        lp.width = ViewGroup.LayoutParams.MATCH_PARENT
        lp.height = ViewGroup.LayoutParams.MATCH_PARENT
        if (lp is FrameLayout.LayoutParams) lp.gravity = Gravity.START or Gravity.TOP
        layoutParams = lp
    }
    (parent as? ViewGroup)?.apply {
        clipChildren = false
        clipToPadding = false
    }
}
