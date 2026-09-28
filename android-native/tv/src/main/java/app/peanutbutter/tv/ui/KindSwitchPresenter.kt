package app.peanutbutter.tv.ui

import android.content.Intent
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.ImageButton
import android.widget.TextView
import androidx.core.content.ContextCompat
import androidx.leanback.widget.Presenter
import app.peanutbutter.tv.R

data class KindSwitchItem(val selected: String)

/** Flutter KindSwitch + Favourites / Watched / Search / Settings. */
class KindSwitchPresenter(
    private val onKindSelected: (String) -> Unit,
) : Presenter() {
    override fun onCreateViewHolder(parent: ViewGroup): ViewHolder {
        val view = LayoutInflater.from(parent.context)
            .inflate(R.layout.item_kind_switch, parent, false)
        val dm = parent.resources.displayMetrics
        view.layoutParams = ViewGroup.LayoutParams(dm.widthPixels, ViewGroup.LayoutParams.WRAP_CONTENT)
        return ViewHolder(view)
    }

    override fun onBindViewHolder(viewHolder: ViewHolder, item: Any) {
        val model = item as KindSwitchItem
        val root = viewHolder.view
        val movies = root.findViewById<TextView>(R.id.kind_movies)
        val series = root.findViewById<TextView>(R.id.kind_series)
        style(movies, series, model.selected)

        fun select(kind: String) {
            if (kind == model.selected) return
            style(movies, series, kind)
            onKindSelected(kind)
        }

        movies.setOnClickListener { select("MOVIE") }
        series.setOnClickListener { select("SERIES") }
        val activate = { kind: String ->
            View.OnKeyListener { _, keyCode, event ->
                if (event.action == android.view.KeyEvent.ACTION_DOWN &&
                    (keyCode == android.view.KeyEvent.KEYCODE_DPAD_CENTER ||
                        keyCode == android.view.KeyEvent.KEYCODE_ENTER)
                ) {
                    select(kind)
                    true
                } else false
            }
        }
        movies.setOnKeyListener(activate("MOVIE"))
        series.setOnKeyListener(activate("SERIES"))

        root.findViewById<ImageButton>(R.id.btn_favourites).setOnClickListener {
            root.context.startActivity(
                Intent(root.context, LibraryActivity::class.java)
                    .putExtra(LibraryActivity.EXTRA_MODE, LibraryActivity.MODE_FAVOURITES),
            )
        }
        root.findViewById<ImageButton>(R.id.btn_watched).setOnClickListener {
            root.context.startActivity(
                Intent(root.context, LibraryActivity::class.java)
                    .putExtra(LibraryActivity.EXTRA_MODE, LibraryActivity.MODE_WATCHED),
            )
        }
        root.findViewById<ImageButton>(R.id.btn_search).setOnClickListener {
            root.context.startActivity(Intent(root.context, SearchActivity::class.java))
        }
        root.findViewById<ImageButton>(R.id.btn_settings).setOnClickListener {
            root.context.startActivity(Intent(root.context, SettingsActivity::class.java))
        }
    }

    override fun onUnbindViewHolder(viewHolder: ViewHolder) {
        viewHolder.view.findViewById<View>(R.id.kind_movies).setOnClickListener(null)
        viewHolder.view.findViewById<View>(R.id.kind_series).setOnClickListener(null)
    }

    private fun style(movies: TextView, series: TextView, selected: String) {
        val seed = ContextCompat.getColor(movies.context, R.color.pb_seed)
        val muted = ContextCompat.getColor(movies.context, R.color.pb_muted)
        movies.setTextColor(if (selected == "MOVIE") seed else muted)
        movies.setTypeface(null, if (selected == "MOVIE") android.graphics.Typeface.BOLD else android.graphics.Typeface.NORMAL)
        series.setTextColor(if (selected == "SERIES") seed else muted)
        series.setTypeface(null, if (selected == "SERIES") android.graphics.Typeface.BOLD else android.graphics.Typeface.NORMAL)
    }
}
