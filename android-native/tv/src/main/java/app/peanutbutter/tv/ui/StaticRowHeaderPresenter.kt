package app.peanutbutter.tv.ui

import android.view.View
import androidx.leanback.widget.RowHeaderPresenter

/** Row titles stay fully visible even when focus is on the hero above. */
class StaticRowHeaderPresenter : RowHeaderPresenter() {
    override fun onSelectLevelChanged(holder: ViewHolder) {
        holder.view.alpha = 1f
        holder.view.visibility = View.VISIBLE
    }
}
