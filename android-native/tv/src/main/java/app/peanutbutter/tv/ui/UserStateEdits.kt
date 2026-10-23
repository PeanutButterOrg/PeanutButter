package app.peanutbutter.tv.ui

import android.view.View
import app.peanutbutter.core.TitleItem
import java.util.WeakHashMap

/**
 * Likes / watched marks made on the details screen this session. Cards keep
 * showing the list they were loaded with, so these edits are laid over them
 * and every bound card for that title is redrawn at once (home rows, catalog,
 * search and library screens still in the back stack included).
 */
object UserStateEdits {
    private data class Edit(val favorite: Boolean?, val watched: Boolean?)

    private val edits = HashMap<String, Edit>()
    /** Bound poster card → the item it shows (main thread only). */
    private val bound = WeakHashMap<View, TitleItem>()
    private var redraw: ((View, TitleItem) -> Unit)? = null

    fun setFavorite(id: String, favorite: Boolean) {
        edits[id] = (edits[id] ?: Edit(null, null)).copy(favorite = favorite)
        refresh(id)
    }

    fun setWatched(id: String, watched: Boolean) {
        edits[id] = (edits[id] ?: Edit(null, null)).copy(watched = watched)
        refresh(id)
    }

    fun apply(item: TitleItem): TitleItem {
        val e = edits[item.id] ?: return item
        return item.copy(
            favorite = e.favorite ?: item.favorite,
            watched = e.watched ?: item.watched,
            positionMs = if (e.watched == true) 0 else item.positionMs,
        )
    }

    internal fun track(card: View, item: TitleItem, onRedraw: (View, TitleItem) -> Unit) {
        bound[card] = item
        redraw = onRedraw
    }

    internal fun untrack(card: View) {
        bound.remove(card)
    }

    private fun refresh(id: String) {
        val draw = redraw ?: return
        for ((card, item) in bound.entries.toList()) {
            if (item.id == id) draw(card, apply(item))
        }
    }
}
