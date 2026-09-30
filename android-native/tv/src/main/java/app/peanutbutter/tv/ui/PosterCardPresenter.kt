package app.peanutbutter.tv.ui

import android.util.TypedValue
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import androidx.core.view.isVisible
import androidx.leanback.widget.Presenter
import app.peanutbutter.core.TitleItem
import app.peanutbutter.tv.PbGlide
import app.peanutbutter.tv.R

/** Flutter PosterCard — star chip, title+year, progress; single 1.08 scale on focus. */
class PosterCardPresenter(
    private val widthPx: Int = 0,
    private val heightPx: Int = 0,
) : Presenter() {
    override fun onCreateViewHolder(parent: ViewGroup): ViewHolder {
        val view = LayoutInflater.from(parent.context)
            .inflate(R.layout.item_poster_card, parent, false)
        view.layoutParams = ViewGroup.MarginLayoutParams(cardWidth(parent), cardHeight(parent))
        view.isFocusable = true
        view.isFocusableInTouchMode = true
        view.stateListAnimator = null
        val frame = view.findViewById<ViewGroup>(R.id.poster_frame)
        frame.clipToOutline = true
        frame.stateListAnimator = null
        // Single scale on the face — skip if already at target (stops zoom-in→out→move glitch)
        view.setOnFocusChangeListener { v, hasFocus ->
            applyFocusScale(v.findViewById(R.id.poster_frame), hasFocus)
        }
        return ViewHolder(view)
    }

    override fun onBindViewHolder(viewHolder: ViewHolder, item: Any) {
        val title = item as TitleItem
        val root = viewHolder.view
        val lp = root.layoutParams
        if (lp is ViewGroup.MarginLayoutParams) {
            lp.width = cardWidth(root)
            lp.height = cardHeight(root)
            root.layoutParams = lp
        } else {
            root.layoutParams = ViewGroup.MarginLayoutParams(cardWidth(root), cardHeight(root))
        }
        val face = root.findViewById<ViewGroup>(R.id.poster_frame)
        // Don't reset scale while focused — rebind during scroll would flash zoom-out
        if (!root.hasFocus()) {
            face.animate().cancel()
            face.scaleX = 1f
            face.scaleY = 1f
        }

        val poster = root.findViewById<ImageView>(R.id.poster)
        val titleView = root.findViewById<TextView>(R.id.title)
        val metaView = root.findViewById<TextView>(R.id.meta)
        val scoreChip = root.findViewById<LinearLayout>(R.id.score_chip)
        val scoreValue = root.findViewById<TextView>(R.id.score_value)
        val scoreSource = root.findViewById<TextView>(R.id.score_source)
        val scoreStar = root.findViewById<ImageView>(R.id.score_star)
        val progress = root.findViewById<ViewGroup>(R.id.progress)
        val progressFill = root.findViewById<View>(R.id.progress_fill)

        titleView.text = title.displayTitle
        // Flutter: year only under title (no rating / genres / runtime)
        metaView.text = title.year?.toString().orEmpty()
        metaView.isVisible = title.year != null

        val score = title.displayScore
        scoreChip.isVisible = score != null
        if (score != null) {
            scoreValue.text = score.label
            scoreSource.text = score.source
            scoreStar.isVisible = score.rtScore == null
            scoreValue.setTextColor(
                root.context.getColor(
                    when {
                        score.rtScore == null -> R.color.pb_white
                        score.rtScore!! >= 60 -> R.color.pb_rt
                        else -> R.color.pb_completed
                    },
                ),
            )
        }

        val p = title.watchProgress
        // Continue-watching / resume items often sit at ~1% — still show a clear bar.
        if (p > 0.0 || title.canResume) {
            val fraction = when {
                p <= 0.0 -> 0.08
                p < 0.08 -> 0.08 // minimum visible chunk on 10-foot UI
                else -> p.coerceAtMost(0.98)
            }
            progress.isVisible = true
            progress.bringToFront()
            fun applyFill() {
                val trackW = progress.width.takeIf { it > 0 } ?: face.width
                if (trackW <= 0) return
                val lp = progressFill.layoutParams as FrameLayout.LayoutParams
                lp.width = (trackW * fraction).toInt().coerceAtLeast(dp(root, 12))
                progressFill.layoutParams = lp
            }
            applyFill()
            if (progress.width <= 0) progress.post { applyFill() }
        } else {
            progress.isVisible = false
        }

        PbGlide.poster(poster, title.posterUrl)
    }

    override fun onUnbindViewHolder(viewHolder: ViewHolder) {
        val poster = viewHolder.view.findViewById<ImageView>(R.id.poster)
        PbGlide.clear(poster)
    }

    private fun cardWidth(host: android.view.View): Int =
        if (widthPx > 0) widthPx else dp(host, CARD_W)

    private fun cardHeight(host: android.view.View): Int =
        if (heightPx > 0) heightPx else dp(host, CARD_H)

    companion object {
        const val CARD_W = 168
        const val CARD_H = 252
        private const val FOCUS_SCALE = 1.08f
        private const val FOCUS_ELEVATION = 28f
        private const val REST_ELEVATION = 4f

        fun applyFocusScale(face: ViewGroup, hasFocus: Boolean, elevate: Boolean = false) {
            face.animate().cancel()
            val target = if (hasFocus) FOCUS_SCALE else 1f
            if (elevate) {
                face.elevation = if (hasFocus) FOCUS_ELEVATION else REST_ELEVATION
            }
            if (kotlin.math.abs(face.scaleX - target) < 0.01f) {
                face.scaleX = target
                face.scaleY = target
                return
            }
            face.animate()
                .scaleX(target)
                .scaleY(target)
                .setDuration(140)
                .start()
        }

        /** Cast / trailer — Flutter uses elevation, not a focus stroke. */
        fun applyFocusScaleElevate(face: ViewGroup, hasFocus: Boolean) =
            applyFocusScale(face, hasFocus, elevate = true)

        fun dp(host: ViewGroup, value: Int): Int =
            TypedValue.applyDimension(
                TypedValue.COMPLEX_UNIT_DIP,
                value.toFloat(),
                host.resources.displayMetrics,
            ).toInt()

        fun dp(host: android.view.View, value: Int): Int =
            TypedValue.applyDimension(
                TypedValue.COMPLEX_UNIT_DIP,
                value.toFloat(),
                host.resources.displayMetrics,
            ).toInt()
    }
}
