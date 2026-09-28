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
import app.peanutbutter.core.StreamHealth
import app.peanutbutter.core.StreamSource
import app.peanutbutter.tv.R
import kotlinx.coroutines.launch

/** Flutter-style Choose a stream dialog (560dp, not full-screen). */
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
        val sources = requireArguments().getSerializable(ARG_SOURCES) as ArrayList<SourceParcel>

        view.findViewById<TextView>(R.id.subtitle).text =
            getString(R.string.sources_subtitle, title)
        view.findViewById<ImageButton>(R.id.btn_close).setOnClickListener { dismiss() }
        view.findViewById<ImageButton>(R.id.btn_refresh).setOnClickListener { refresh() }

        val list = view.findViewById<RecyclerView>(R.id.list)
        list.layoutManager = LinearLayoutManager(requireContext())
        adapter = Adapter(sources.map { it.toSource() }.toMutableList()) { src ->
            dismiss()
            onPicked?.invoke(src)
        }
        list.adapter = adapter
        list.post { list.getChildAt(0)?.requestFocus() }
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
                adapter?.replaceAll(next)
                view?.findViewById<TextView>(R.id.subtitle)?.text =
                    getString(R.string.sources_subtitle, requireArguments().getString(ARG_TITLE).orEmpty())
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
            root.findViewById<TextView>(R.id.tag_best).isVisible = best
            val health = root.findViewById<TextView>(R.id.tag_health)
            health.text = StreamHealth.label(s.health)
            val healthy = s.seeders >= 20
            health.background = ContextCompat.getDrawable(
                root.context,
                if (healthy || best) R.drawable.source_tag_emphasized else R.drawable.source_tag_muted,
            )
            health.setTextColor(
                ContextCompat.getColor(
                    root.context,
                    if (healthy || best) R.color.pb_seed else R.color.pb_muted,
                ),
            )
            root.findViewById<TextView>(R.id.tag_tracker).text = StreamHealth.sourceLabel(s)
            root.findViewById<TextView>(R.id.source_title).text = s.title
            root.findViewById<TextView>(R.id.source_meta).text = buildString {
                if (s.size.isNotBlank()) append(s.size)
                if (isNotEmpty()) append("  ·  ")
                append("${s.seeders} seeders")
                if (s.peers > 0) append("  ·  ${s.peers} peers")
            }
            root.findViewById<ImageView>(R.id.play_icon).imageTintList =
                ContextCompat.getColorStateList(root.context, if (best) R.color.pb_seed else R.color.pb_muted)
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
            (560 * resources.displayMetrics.density).toInt(),
            ViewGroup.LayoutParams.WRAP_CONTENT,
        )
    }

    companion object {
        private const val ARG_TITLE = "title"
        private const val ARG_SOURCES = "sources"

        fun show(
            fm: FragmentManager,
            title: String,
            sources: List<StreamSource>,
            onRefresh: (suspend () -> List<StreamSource>)? = null,
            onPicked: (StreamSource) -> Unit,
        ) {
            val dlg = SourcesDialog()
            dlg.arguments = Bundle().apply {
                putString(ARG_TITLE, title)
                putSerializable(ARG_SOURCES, ArrayList(sources.map { SourceParcel.from(it) }))
            }
            dlg.onPicked = onPicked
            dlg.onRefresh = onRefresh
            dlg.show(fm, "sources")
        }
    }
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
) : java.io.Serializable {
    fun toSource() = StreamSource(id, title, magnet, seeders, peers, size, tracker, health, indexer, language)

    companion object {
        fun from(s: StreamSource) = SourceParcel(
            s.id, s.title, s.magnet, s.seeders, s.peers, s.size, s.tracker, s.health, s.indexer, s.language,
        )
    }
}
