package app.peanutbutter.tv.ui

import android.view.LayoutInflater
import android.view.ViewGroup
import android.widget.TextView
import androidx.leanback.widget.Presenter
import androidx.leanback.widget.Row
import androidx.leanback.widget.RowHeaderPresenter
import app.peanutbutter.tv.R

/** Large row titles — hide blank headers (hero row). */
class ModernRowHeaderPresenter : RowHeaderPresenter() {
    override fun onCreateViewHolder(parent: ViewGroup): Presenter.ViewHolder {
        val view = LayoutInflater.from(parent.context)
            .inflate(R.layout.row_header_modern, parent, false) as TextView
        return ViewHolder(view)
    }

    override fun onBindViewHolder(viewHolder: Presenter.ViewHolder, item: Any?) {
        val header = (item as? Row)?.headerItem?.name.orEmpty()
        val tv = viewHolder.view as TextView
        tv.text = header
        if (header.isBlank()) {
            tv.visibility = android.view.View.GONE
            tv.layoutParams = tv.layoutParams.apply { height = 0 }
        } else {
            tv.visibility = android.view.View.VISIBLE
            tv.layoutParams = tv.layoutParams.apply {
                height = ViewGroup.LayoutParams.WRAP_CONTENT
            }
        }
    }

    override fun onUnbindViewHolder(viewHolder: Presenter.ViewHolder) {
        (viewHolder.view as TextView).text = null
    }
}
