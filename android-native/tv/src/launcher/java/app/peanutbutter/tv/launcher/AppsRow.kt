package app.peanutbutter.tv.launcher

import android.app.Activity
import android.net.Uri
import android.provider.Settings
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.graphics.drawable.Drawable
import android.view.KeyEvent
import android.view.ViewGroup
import androidx.recyclerview.widget.RecyclerView
import app.peanutbutter.tv.R

/**
 * "Your apps": the apps the user picked, in their order. Until they edit it,
 * every app they installed themselves (no system apps). Hold OK on a tile
 * to move or remove it; the last tile ("Edit") is a checklist of all apps.
 */
class AppsRow(private val context: Context) : RecyclerView.Adapter<RecyclerView.ViewHolder>() {
    data class App(
        val pkg: String,
        val label: String,
        val banner: Drawable?,
        val icon: Drawable?,
        val intent: Intent,
        val system: Boolean,
    )

    private var items: MutableList<App> = mutableListOf()
    private var movingPkg: String? = null
    private var recycler: RecyclerView? = null

    override fun onAttachedToRecyclerView(recyclerView: RecyclerView) {
        recycler = recyclerView
    }

    /** Re-read installed apps (one may have been added or removed). */
    fun reload() {
        if (movingPkg != null) return
        val fresh = chosenApps()
        // Nothing installed/removed/reordered: leave the tiles (and focus) alone.
        if (fresh.map { it.pkg to it.label } == items.map { it.pkg to it.label }) return
        items = fresh.toMutableList()
        notifyDataSetChanged()
    }

    // --- data -------------------------------------------------------------

    private fun installed(): List<App> {
        val pm = context.packageManager
        return listOf(Intent.CATEGORY_LEANBACK_LAUNCHER, Intent.CATEGORY_LAUNCHER)
            .flatMap { pm.queryIntentActivities(Intent(Intent.ACTION_MAIN).addCategory(it), 0) }
            .map { it.activityInfo.packageName }
            .filter { it != context.packageName }
            .distinct()
            .mapNotNull { pkg ->
                val launch = pm.getLeanbackLaunchIntentForPackage(pkg)
                    ?: pm.getLaunchIntentForPackage(pkg)
                    ?: return@mapNotNull null
                val info = runCatching { pm.getApplicationInfo(pkg, 0) }.getOrNull()
                    ?: return@mapNotNull null
                App(
                    pkg = pkg,
                    label = pm.getApplicationLabel(info).toString(),
                    banner = runCatching { pm.getApplicationBanner(pkg) }.getOrNull(),
                    icon = runCatching { pm.getApplicationIcon(pkg) }.getOrNull(),
                    intent = launch,
                    system = info.flags and ApplicationInfo.FLAG_SYSTEM != 0,
                )
            }
            .sortedBy { it.label.lowercase() }
    }

    private fun chosenApps(): List<App> {
        val all = installed()
        val saved = prefs().getString(KEY_APPS, null)?.split(',')?.filter { it.isNotBlank() }
            ?: return all.filterNot { it.system }
        val byPkg = all.associateBy { it.pkg }
        return saved.mapNotNull { byPkg[it] }
    }

    private fun prefs() = context.getSharedPreferences("launcher", Context.MODE_PRIVATE)

    private fun save() {
        prefs().edit().putString(KEY_APPS, items.joinToString(",") { it.pkg }).apply()
    }

    // --- editing ----------------------------------------------------------

    /** Full-screen grid of every app; the picks (in pick order) become the row. */
    private fun showPicker() {
        val activity = context as? Activity ?: return
        AppPicker(activity, installed(), items.map { it.pkg }) { order ->
            prefs().edit().putString(KEY_APPS, order.joinToString(",")).apply()
            reload()
            // Back on the Edit tile.
            focusAfterPanel(items.size)
        }.show()
    }

    /**
     * A closing dialog hands focus back to the view that opened it; when that
     * tile is gone, Android would pick the top bar. Focus [position] instead,
     * once the home screen has its window focus back.
     */
    private fun focusAfterPanel(position: Int) {
        (context as? LauncherActivity)?.focusWhenBack {
            val list = recycler ?: return@focusWhenBack
            list.scrollToPosition(position)
            list.post { list.findViewHolderForAdapterPosition(position)?.itemView?.requestFocus() }
        }
    }

    /** Hold OK on a tile: move, remove, or the app's info page. */
    private fun showAppMenu(holder: AppHolder, app: App) {
        val activity = context as? Activity ?: return
        ControlPanel(activity, app.label, centered = true)
            .action(R.drawable.ic_move, context.getString(R.string.move)) {
                movingPkg = app.pkg
                holder.showMoving(true)
            }
            .action(R.drawable.ic_remove, context.getString(R.string.remove_from_row)) {
                val i = items.indexOfFirst { it.pkg == app.pkg }
                if (i >= 0) {
                    items.removeAt(i)
                    notifyItemRemoved(i)
                    save()
                    // Focus the tile that slid into its place (or the one before, at the end).
                    focusAfterPanel(minOf(i, items.size))
                }
            }
            .action(R.drawable.ic_info, context.getString(R.string.app_info)) {
                TvControls.open(
                    context,
                    Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${app.pkg}")),
                )
            }
            .show()
    }

    /** While moving: ◀ ▶ shift the tile, OK / Back drop it. True when the key was used. */
    private fun onMoveKey(holder: AppHolder, keyCode: Int): Boolean {
        val pkg = movingPkg ?: return false
        val from = items.indexOfFirst { it.pkg == pkg }
        if (from < 0 || holder.bindingAdapterPosition != from) return false
        when (keyCode) {
            KeyEvent.KEYCODE_DPAD_LEFT, KeyEvent.KEYCODE_DPAD_RIGHT -> {
                val to = from + if (keyCode == KeyEvent.KEYCODE_DPAD_LEFT) -1 else 1
                if (to in items.indices) {
                    items.add(to, items.removeAt(from))
                    notifyItemMoved(from, to)
                    recycler?.scrollToPosition(to)
                }
            }
            KeyEvent.KEYCODE_DPAD_CENTER, KeyEvent.KEYCODE_ENTER, KeyEvent.KEYCODE_BACK -> {
                movingPkg = null
                holder.showMoving(false)
                save()
            }
            KeyEvent.KEYCODE_DPAD_UP, KeyEvent.KEYCODE_DPAD_DOWN -> Unit // stay on the tile
            else -> return false
        }
        return true
    }

    // --- views ------------------------------------------------------------

    override fun getItemCount() = items.size + 1
    override fun getItemViewType(position: Int) = if (position < items.size) TYPE_APP else TYPE_EDIT

    override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): RecyclerView.ViewHolder =
        if (viewType == TYPE_APP) AppHolder(parent) else EditHolder(parent)

    override fun onBindViewHolder(holder: RecyclerView.ViewHolder, position: Int) {
        if (holder is AppHolder) holder.bind(items[position])
    }

    private fun dp(v: Int) = (v * context.resources.displayMetrics.density).toInt()

    private fun tileLayout(tile: AppTileView) = tile.apply {
        layoutParams = RecyclerView.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT)
        setPadding(dp(8), dp(12), dp(8), dp(4))
    }

    inner class AppHolder(parent: ViewGroup) : RecyclerView.ViewHolder(tileLayout(AppTileView(parent.context))) {
        private val tile = itemView as AppTileView
        private var app: App? = null

        init {
            tile.setOnClickListener { app?.let { TvControls.open(context, it.intent) } }
            tile.setOnLongClickListener { app?.let { showAppMenu(this, it) }; true }
            tile.setOnKeyListener { _, keyCode, event ->
                event.action == KeyEvent.ACTION_DOWN && onMoveKey(this, keyCode)
            }
        }

        fun bind(app: App) {
            this.app = app
            tile.bind(app)
            showMoving(movingPkg == app.pkg)
        }

        fun showMoving(moving: Boolean) = tile.showMoving(moving)
    }

    inner class EditHolder(parent: ViewGroup) : RecyclerView.ViewHolder(tileLayout(AppTileView(parent.context))) {
        init {
            (itemView as AppTileView).apply {
                bindEdit()
                setOnClickListener { showPicker() }
            }
        }
    }

    companion object {
        private const val KEY_APPS = "apps"
        private const val TYPE_APP = 0
        private const val TYPE_EDIT = 1
    }
}
