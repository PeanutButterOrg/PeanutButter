package app.peanutbutter.tv.ui

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.TextView
import androidx.leanback.widget.HeaderItem
import androidx.leanback.widget.Presenter
import androidx.leanback.widget.Row
import androidx.leanback.widget.RowHeaderPresenter
import app.peanutbutter.tv.R

class ShelfHeaderItem(
    id: Long,
    name: String,
    val kind: String?,
    val sort: String,
) : HeaderItem(id, name)

/** Row header matching Flutter: title + See all TextButton. */
class ShelfHeaderPresenter : RowHeaderPresenter() {
    override fun onCreateViewHolder(parent: ViewGroup): Presenter.ViewHolder {
        val view = LayoutInflater.from(parent.context)
            .inflate(R.layout.row_header_shelf, parent, false)
        // Keep full opacity while row is unselected (avoids “fade on scroll up”).
        return ViewHolder(view).also { setSelectLevel(it, 1f) }
    }

    override fun onSelectLevelChanged(holder: ViewHolder) {
        // Keep header fully opaque — Flutter shelf titles don’t dim.
        holder.view.alpha = 1f
    }

    override fun onBindViewHolder(viewHolder: Presenter.ViewHolder, item: Any?) {
        val row = item as? Row
        val header = row?.headerItem
        val root = viewHolder.view
        val title = root.findViewById<TextView>(R.id.shelf_title)
        val seeAll = root.findViewById<TextView>(R.id.shelf_see_all)

        val name = header?.name.orEmpty()
        if (name.isBlank()) {
            root.visibility = View.GONE
            root.layoutParams = root.layoutParams.apply { height = 0 }
            seeAll.setOnClickListener(null)
            return
        }

        root.visibility = View.VISIBLE
        root.layoutParams = root.layoutParams.apply {
            height = ViewGroup.LayoutParams.WRAP_CONTENT
        }
        title.text = name

        val shelf = header as? ShelfHeaderItem
        if (shelf != null) {
            seeAll.visibility = View.VISIBLE
            seeAll.setOnClickListener {
                openCatalog(root.context, name, shelf.kind, shelf.sort)
            }
            // DPAD / click both activate (Leanback sometimes skips OnClickListener)
            seeAll.setOnKeyListener { _, keyCode, event ->
                if (event.action == android.view.KeyEvent.ACTION_UP &&
                    (keyCode == android.view.KeyEvent.KEYCODE_DPAD_CENTER ||
                        keyCode == android.view.KeyEvent.KEYCODE_ENTER)
                ) {
                    openCatalog(root.context, name, shelf.kind, shelf.sort)
                    true
                } else {
                    false
                }
            }
        } else {
            seeAll.visibility = View.GONE
            seeAll.setOnClickListener(null)
            seeAll.setOnKeyListener(null)
        }
    }

    override fun onUnbindViewHolder(viewHolder: Presenter.ViewHolder) {
        val seeAll = viewHolder.view.findViewById<TextView>(R.id.shelf_see_all)
        seeAll.setOnClickListener(null)
        seeAll.setOnKeyListener(null)
    }

    companion object {
        fun openCatalog(context: Context, title: String, kind: String?, sort: String) {
            val activity = context.findActivity() ?: return
            val intent = Intent(activity, CatalogActivity::class.java)
                .putExtra(CatalogActivity.EXTRA_TITLE, title)
                .putExtra(CatalogActivity.EXTRA_SORT, sort)
            if (!kind.isNullOrBlank()) {
                intent.putExtra(CatalogActivity.EXTRA_KIND, kind)
            }
            activity.startActivity(intent)
        }

        private fun Context.findActivity(): Activity? {
            var ctx: Context? = this
            while (ctx is ContextWrapper) {
                if (ctx is Activity) return ctx
                ctx = ctx.baseContext
            }
            return ctx as? Activity
        }
    }
}
