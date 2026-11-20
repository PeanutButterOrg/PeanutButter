package app.peanutbutter.tv.ui

import android.app.Dialog
import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.ImageButton
import android.widget.ImageView
import android.widget.TextView
import androidx.core.content.ContextCompat
import androidx.core.view.isVisible
import androidx.fragment.app.DialogFragment
import androidx.fragment.app.FragmentManager
import androidx.lifecycle.lifecycleScope
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import app.peanutbutter.core.ReleaseTags
import app.peanutbutter.core.StreamHealth
import app.peanutbutter.core.StreamSource
import app.peanutbutter.tv.R
import kotlinx.coroutines.launch

/** Choose a stream: poster header, Torrents / Direct links tabs, ranked rows (same as desktop). */
class SourcesDialog : DialogFragment() {
    private var onPicked: ((StreamSource) -> Unit)? = null
    private var onRefresh: (suspend () -> List<StreamSource>)? = null
    private var adapter: Adapter? = null
    private var refreshing = false

    override fun onCreateDialog(savedInstanceState: Bundle?): Dialog {
        return Dialog(requireContext(), R.style.Theme_PeanutButter_Dialog).apply {
            setCanceledOnTouchOutside(true)
        }
    }

    override fun onCreateView(inflater: LayoutInflater, container: ViewGroup?, savedInstanceState: Bundle?): View {
        return inflater.inflate(R.layout.dialog_sources, container, false)
    }

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        super.onViewCreated(view, savedInstanceState)
        val title = requireArguments().getString(ARG_TITLE).orEmpty()
        @Suppress("UNCHECKED_CAST")
        val sources = androidx.core.os.BundleCompat.getSerializable(
            requireArguments(),
            ARG_SOURCES,
            ArrayList::class.java,
        ) as ArrayList<SourceParcel>

        view.findViewById<TextView>(R.id.picker_title).text = title
        view.findViewById<TextView>(R.id.subtitle).text = requireArguments().getString(ARG_SUBTITLE).orEmpty()
        requireArguments().getString(ARG_POSTER)?.takeIf { it.isNotBlank() }?.let { url ->
            val poster = view.findViewById<ImageView>(R.id.poster)
            poster.isVisible = true
            poster.clipToOutline = true
            app.peanutbutter.tv.PbGlide.poster(poster, url)
        }
        view.findViewById<ImageButton>(R.id.btn_close).setOnClickListener { dismiss() }
        view.findViewById<ImageButton>(R.id.btn_refresh).setOnClickListener { refresh() }

        val list = view.findViewById<RecyclerView>(R.id.list)
        list.layoutManager = LinearLayoutManager(requireContext())
        all = sources.map { it.toSource() }
        adapter = Adapter(mutableListOf()) { src ->
            dismiss()
            onPicked?.invoke(src)
        }
        list.adapter = adapter
        view.findViewById<TextView>(R.id.tab_torrents).setOnClickListener { showTab(direct = false) }
        view.findViewById<TextView>(R.id.tab_direct).setOnClickListener { showTab(direct = true) }
        showTab(direct = all.none { !it.isHttp })
        list.post { list.getChildAt(0)?.requestFocus() }
    }

    /** Every source, ranked; the tabs show the torrents or the direct links. */
    private var all: List<StreamSource> = emptyList()

    private fun showTab(direct: Boolean) {
        val v = view ?: return
        val torrents = all.count { !it.isHttp }
        val links = all.count { it.isHttp }
        val both = torrents > 0 && links > 0
        v.findViewById<View>(R.id.tabs).isVisible = both
        v.findViewById<TextView>(R.id.tab_torrents).apply {
            text = getString(R.string.tab_torrents, torrents)
            isSelected = !direct
            setTextColor(requireContext().getColor(if (!direct) R.color.pbt_on_primary else R.color.pbt_text_muted))
        }
        v.findViewById<TextView>(R.id.tab_direct).apply {
            text = getString(R.string.tab_direct, links)
            isSelected = direct
            setTextColor(requireContext().getColor(if (direct) R.color.pbt_on_primary else R.color.pbt_text_muted))
        }
        v.findViewById<TextView>(R.id.note).setText(if (direct) R.string.sources_note_direct else R.string.sources_note)
        adapter?.replaceAll(if (both) all.filter { it.isHttp == direct } else all)
    }

    private fun refresh() {
        val refreshFn = onRefresh ?: return
        if (refreshing) return
        refreshing = true
        val btn = view?.findViewById<ImageButton>(R.id.btn_refresh)
        btn?.isEnabled = false
        view?.findViewById<TextView>(R.id.subtitle)?.text = getString(R.string.refreshing_sources)
        lifecycleScope.launch {
            try {
                val next = refreshFn()
                all = next
                showTab(direct = next.none { !it.isHttp })
                view?.findViewById<TextView>(R.id.subtitle)?.text = requireArguments().getString(ARG_SUBTITLE).orEmpty()
                if (next.isEmpty()) {
                    view?.findViewById<TextView>(R.id.subtitle)?.text = getString(R.string.no_sources)
                }
            } catch (e: Exception) {
                view?.findViewById<TextView>(R.id.subtitle)?.text =
                    e.message ?: getString(R.string.no_sources)
            } finally {
                refreshing = false
                btn?.isEnabled = true
            }
        }
    }

    private class Adapter(
        private val items: MutableList<StreamSource>,
        private val onClick: (StreamSource) -> Unit,
    ) : RecyclerView.Adapter<Adapter.VH>() {
        class VH(val root: View) : RecyclerView.ViewHolder(root)

        fun replaceAll(next: List<StreamSource>) {
            items.clear()
            items.addAll(next)
            notifyDataSetChanged()
        }

        override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): VH {
            val v = LayoutInflater.from(parent.context)
                .inflate(R.layout.item_source_card, parent, false)
            val lp = RecyclerView.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
            )
            val gap = (8 * parent.resources.displayMetrics.density).toInt()
            lp.topMargin = gap
            lp.bottomMargin = gap
            v.layoutParams = lp
            return VH(v)
        }

        override fun onBindViewHolder(holder: VH, position: Int) {
            val s = items[position]
            val best = position == 0
            val root = holder.root
            val ctx = root.context
            val tags = ReleaseTags.parse(s.title)
            root.findViewById<TextView>(R.id.q_res).text = tags.resolution.ifEmpty { "HD" }
            root.findViewById<TextView>(R.id.q_src).apply {
                text = tags.source
                isVisible = tags.source.isNotEmpty()
            }
            root.findViewById<SignalBarsView>(R.id.bars).apply {
                isVisible = !s.isHttp
                lit = when (s.health) {
                    "excellent" -> 4
                    "good" -> 3
                    "decent" -> 2
                    else -> 1
                }
            }
            root.findViewById<TextView>(R.id.status).text = if (s.isHttp) {
                ctx.getString(R.string.direct_link)
            } else {
                "${StreamHealth.label(s.health)} · ${s.seeders} seeder${if (s.seeders == 1) "" else "s"}"
            }
            root.findViewById<TextView>(R.id.tag_best).isVisible = best
            root.findViewById<TextView>(R.id.spec).apply {
                text = listOf(s.size.takeIf { it.isNotBlank() && it != "?" }, tags.codec, tags.audio)
                    .filter { !it.isNullOrBlank() }
                    .joinToString(" · ")
                isVisible = text.isNotEmpty()
            }
            root.findViewById<TextView>(R.id.origin).text = listOf(
                languageName(s.language),
                if (s.providers.size > 1) s.providers.joinToString(" + ") else StreamHealth.sourceLabel(s),
            ).filter { it.isNotBlank() }.joinToString(" · ")
            root.findViewById<TextView>(R.id.source_title).text = s.title
            root.findViewById<View>(R.id.play_dot)
                .setBackgroundResource(if (best) R.drawable.play_dot else R.drawable.play_dot_alt)
            root.findViewById<ImageView>(R.id.play_icon).imageTintList =
                ContextCompat.getColorStateList(ctx, if (best) R.color.pbt_on_primary else R.color.pbt_text)
            root.setBackgroundResource(if (best) R.drawable.source_tile_best else R.drawable.source_tile_bg)
            root.setOnClickListener { onClick(s) }
            root.isFocusable = true
            root.isFocusableInTouchMode = true
        }

        override fun getItemCount(): Int = items.size
    }

    override fun onStart() {
        super.onStart()
        dialog?.window?.setLayout(
            (680 * resources.displayMetrics.density).toInt(),
            ViewGroup.LayoutParams.WRAP_CONTENT,
        )
    }

    companion object {
        private const val ARG_TITLE = "title"
        private const val ARG_SOURCES = "sources"
        private const val ARG_SUBTITLE = "subtitle"
        private const val ARG_POSTER = "poster"

        fun show(
            fm: FragmentManager,
            title: String,
            sources: List<StreamSource>,
            /** "Season 2 · Episode 3" or "Movie" under the title. */
            subtitle: String = "",
            posterUrl: String? = null,
            onRefresh: (suspend () -> List<StreamSource>)? = null,
            onPicked: (StreamSource) -> Unit,
        ) {
            val dlg = SourcesDialog()
            dlg.arguments = Bundle().apply {
                putString(ARG_TITLE, title)
                putString(ARG_SUBTITLE, subtitle)
                putString(ARG_POSTER, posterUrl)
                putSerializable(ARG_SOURCES, ArrayList(sources.map { SourceParcel.from(it) }))
            }
            dlg.onPicked = onPicked
            dlg.onRefresh = onRefresh
            dlg.show(fm, "sources")
        }
    }
}

/** "English" for "en"; empty when there's no language. */
private fun languageName(code: String): String {
    val c = code.trim()
    // The server says "unknown" / "und" when the release doesn't say.
    if (c.isEmpty() || c.equals("unknown", true) || c.equals("und", true)) return ""
    val name = java.util.Locale.forLanguageTag(c).getDisplayLanguage(java.util.Locale.ENGLISH)
    return if (name.isBlank() || name.equals(c, true)) c.uppercase() else name
}

/** Serializable stand-in for StreamSource (Parcelable-free). */
class SourceParcel(
    val id: String,
    val title: String,
    val magnet: String,
    val seeders: Int,
    val peers: Int,
    val size: String,
    val tracker: String,
    val health: String,
    val indexer: String,
    val language: String,
    val kind: String,
    val url: String,
    val headers: HashMap<String, String>,
    val score: Int,
    val providers: ArrayList<String>,
) : java.io.Serializable {
    fun toSource() = StreamSource(
        id, title, magnet, seeders, peers, size, tracker, health, indexer, language,
        kind = kind, url = url, headers = headers, score = score, providers = providers,
    )

    companion object {
        fun from(s: StreamSource) = SourceParcel(
            s.id, s.title, s.magnet, s.seeders, s.peers, s.size, s.tracker, s.health, s.indexer, s.language,
            s.kind, s.url, HashMap(s.headers), s.score, ArrayList(s.providers),
        )
    }
}
