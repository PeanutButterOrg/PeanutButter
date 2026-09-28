package app.peanutbutter.tv.ui

import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.ImageView
import android.widget.TextView
import androidx.core.content.ContextCompat
import androidx.core.view.isVisible
import androidx.leanback.widget.Presenter
import app.peanutbutter.core.StreamHealth
import app.peanutbutter.core.StreamSource
import app.peanutbutter.tv.R

/** Flutter _TorrentTile — Best match / health / tracker tags + meta line. */
data class SourcePick(val source: StreamSource, val best: Boolean)

class SourceCardPresenter : Presenter() {
    override fun onCreateViewHolder(parent: ViewGroup): ViewHolder {
        val view = LayoutInflater.from(parent.context)
            .inflate(R.layout.item_source_card, parent, false)
        view.isFocusable = true
        view.isFocusableInTouchMode = true
        view.setOnFocusChangeListener { v, hasFocus ->
            v.animate()
                .scaleX(if (hasFocus) 1.02f else 1f)
                .scaleY(if (hasFocus) 1.02f else 1f)
                .setDuration(120)
                .start()
        }
        return ViewHolder(view)
    }

    override fun onBindViewHolder(viewHolder: ViewHolder, item: Any) {
        val pick = when (item) {
            is SourcePick -> item
            is StreamSource -> SourcePick(item, false)
            else -> return
        }
        val s = pick.source
        val root = viewHolder.view
        val best = root.findViewById<TextView>(R.id.tag_best)
        val health = root.findViewById<TextView>(R.id.tag_health)
        val tracker = root.findViewById<TextView>(R.id.tag_tracker)
        val play = root.findViewById<ImageView>(R.id.play_icon)
        val title = root.findViewById<TextView>(R.id.source_title)
        val meta = root.findViewById<TextView>(R.id.source_meta)

        best.isVisible = pick.best
        health.text = StreamHealth.label(s.health)
        val healthy = s.seeders >= 20
        health.background = ContextCompat.getDrawable(
            root.context,
            if (healthy || pick.best) R.drawable.source_tag_emphasized else R.drawable.source_tag_muted,
        )
        health.setTextColor(
            ContextCompat.getColor(
                root.context,
                if (healthy || pick.best) R.color.pb_seed else R.color.pb_muted,
            ),
        )
        tracker.text = StreamHealth.sourceLabel(s)
        play.imageTintList = ContextCompat.getColorStateList(
            root.context,
            if (pick.best) R.color.pb_seed else R.color.pb_muted,
        )
        title.text = s.title.ifBlank { "Torrent" }
        meta.text = buildString {
            if (s.size.isNotBlank()) append(s.size)
            if (isNotEmpty()) append("  ·  ")
            append("${s.seeders} seeders")
            if (s.peers > 0) append("  ·  ${s.peers} peers")
            if (s.language.isNotBlank()) append("  ·  ${s.language}")
        }
        // Emphasize best match border via tag; background selector handles focus
        root.setBackgroundResource(
            if (pick.best) R.drawable.source_tile_best else R.drawable.source_tile_bg,
        )
    }

    override fun onUnbindViewHolder(viewHolder: ViewHolder) = Unit
}
