package app.peanutbutter.tv.ui

import android.view.LayoutInflater
import android.view.ViewGroup
import android.widget.TextView
import androidx.leanback.widget.Presenter
import app.peanutbutter.core.SeeAllItem
import app.peanutbutter.tv.R

class SeeAllPresenter : Presenter() {
    override fun onCreateViewHolder(parent: ViewGroup): ViewHolder {
        val view = LayoutInflater.from(parent.context)
            .inflate(R.layout.item_see_all, parent, false)
        view.layoutParams = ViewGroup.LayoutParams(
            PosterCardPresenter.dp(parent, PosterCardPresenter.CARD_W),
            PosterCardPresenter.dp(parent, PosterCardPresenter.CARD_H),
        )
        view.isFocusable = true
        view.isFocusableInTouchMode = true
        view.findViewById<ViewGroup>(R.id.see_all_frame).clipToOutline = true
        view.setOnFocusChangeListener { v, hasFocus ->
            v.animate()
                .scaleX(if (hasFocus) 1.05f else 1f)
                .scaleY(if (hasFocus) 1.05f else 1f)
                .setDuration(140)
                .start()
        }
        return ViewHolder(view)
    }

    override fun onBindViewHolder(viewHolder: ViewHolder, item: Any) {
        val see = item as SeeAllItem
        viewHolder.view.layoutParams = ViewGroup.LayoutParams(
            PosterCardPresenter.dp(viewHolder.view, PosterCardPresenter.CARD_W),
            PosterCardPresenter.dp(viewHolder.view, PosterCardPresenter.CARD_H),
        )
        viewHolder.view.scaleX = 1f
        viewHolder.view.scaleY = 1f
        viewHolder.view.findViewById<TextView>(R.id.see_all_label).text = see.label
        viewHolder.view.findViewById<TextView>(R.id.see_all_sub).text = see.title
    }

    override fun onUnbindViewHolder(viewHolder: ViewHolder) = Unit
}
