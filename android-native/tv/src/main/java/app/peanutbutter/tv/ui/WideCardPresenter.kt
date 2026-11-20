package app.peanutbutter.tv.ui

import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.TextView
import androidx.leanback.widget.Presenter
import app.peanutbutter.core.HomeSections
import app.peanutbutter.core.WideTitle
import app.peanutbutter.tv.PbGlide
import app.peanutbutter.tv.R

/** Continue watching card: still, name, time left and an amber bar. */
class WideCardPresenter : Presenter() {
    override fun onCreateViewHolder(parent: ViewGroup): ViewHolder {
        val view = LayoutInflater.from(parent.context).inflate(R.layout.item_wide_card, parent, false)
        view.stateListAnimator = null
        view.findViewById<View>(R.id.poster_frame).clipToOutline = true
        view.setOnFocusChangeListener { v, hasFocus -> PosterCardPresenter.applyCardFocus(v, hasFocus) }
        return ViewHolder(view)
    }

    override fun onBindViewHolder(viewHolder: ViewHolder, item: Any) {
        val title = (item as WideTitle).item
        val root = viewHolder.view
        root.findViewById<TextView>(R.id.title).text = title.displayTitle
        root.findViewById<TextView>(R.id.time_left).text = HomeSections.timeLeft(title)
        PbGlide.backdrop(root.findViewById(R.id.still), title.backdropUrl ?: title.posterUrl)
        val track = root.findViewById<View>(R.id.progress)
        val fill = root.findViewById<View>(R.id.progress_fill)
        val fraction = title.watchProgress.coerceIn(0.02, 1.0)
        fun apply() {
            val w = track.width
            if (w <= 0) return
            val lp = fill.layoutParams as FrameLayout.LayoutParams
            lp.width = (w * fraction).toInt()
            fill.layoutParams = lp
        }
        apply()
        if (track.width <= 0) track.post { apply() }
    }

    override fun onUnbindViewHolder(viewHolder: ViewHolder) {
        PbGlide.clear(viewHolder.view.findViewById<ImageView>(R.id.still))
    }
}
