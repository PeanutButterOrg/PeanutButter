package app.peanutbutter.phone.ui

import android.content.Intent
import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.ImageView
import android.widget.ProgressBar
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import app.peanutbutter.core.LocalTorrentEngine
import app.peanutbutter.core.StreamSource
import app.peanutbutter.core.TitleItem
import app.peanutbutter.core.seriesPlayTarget
import app.peanutbutter.phone.R
import app.peanutbutter.phone.asPhone
import com.bumptech.glide.Glide
import com.google.android.material.button.MaterialButton
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

class DetailsActivity : AppCompatActivity() {
    private val scope = CoroutineScope(Dispatchers.Main + Job())
    private var searching = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_details)
        val id = intent.getStringExtra(EXTRA_ID).orEmpty()
        val app = application.asPhone()
        scope.launch {
            try {
                val item = app.api.title(id)
                bind(item)
            } catch (e: Exception) {
                Toast.makeText(this@DetailsActivity, e.message, Toast.LENGTH_LONG).show()
            }
        }
    }

    private fun bind(item: TitleItem) {
        findViewById<TextView>(R.id.title).text = item.displayTitle
        findViewById<TextView>(R.id.meta).text = buildString {
            item.year?.let { append(it) }
            item.imdbRating?.let {
                if (isNotEmpty()) append(" · ")
                append(String.format("%.1f IMDb", it))
            }
            if (item.genres.isNotEmpty()) {
                if (isNotEmpty()) append(" · ")
                append(item.genres.take(3).joinToString(", "))
            }
        }
        findViewById<TextView>(R.id.synopsis).text = item.synopsis.orEmpty()
        Glide.with(this)
            .load(item.backdropUrl ?: item.posterUrl)
            .into(findViewById(R.id.backdrop))
        findViewById<MaterialButton>(R.id.stream).setOnClickListener { findSources(item) }
        findViewById<MaterialButton>(R.id.stream_best).setOnClickListener { quickStream(item) }
    }

    private fun findSources(item: TitleItem) {
        if (searching) return
        searching = true
        val busy = findViewById<ProgressBar>(R.id.sources_busy)
        val list = findViewById<RecyclerView>(R.id.sources)
        busy.visibility = View.VISIBLE
        Toast.makeText(this, "Looking up sources…", Toast.LENGTH_SHORT).show()
        val app = application.asPhone()
        val lookup = sourceLookup(item)
        scope.launch {
            try {
                val sources = app.api.lookupSources(
                    query = lookup.query,
                    kind = item.kind.ifBlank { "MOVIE" },
                    titleId = item.id,
                    season = lookup.season,
                    episode = lookup.episode,
                ).sortedByDescending { it.seeders }
                if (sources.isEmpty()) {
                    Toast.makeText(this@DetailsActivity, "No healthy sources", Toast.LENGTH_LONG).show()
                    return@launch
                }
                list.layoutManager = LinearLayoutManager(this@DetailsActivity)
                list.adapter = SourceAdapter(sources) { playSource(item, it, lookup) }
                list.visibility = View.VISIBLE
                findViewById<TextView>(R.id.sources_label).visibility = View.VISIBLE
            } catch (e: Exception) {
                Toast.makeText(this@DetailsActivity, e.message, Toast.LENGTH_LONG).show()
            } finally {
                busy.visibility = View.GONE
                searching = false
            }
        }
    }

    private fun quickStream(item: TitleItem) {
        if (searching) return
        searching = true
        Toast.makeText(this, "Looking up sources…", Toast.LENGTH_SHORT).show()
        val app = application.asPhone()
        val lookup = sourceLookup(item)
        scope.launch {
            try {
                val sources = app.api.lookupSources(
                    query = lookup.query,
                    kind = item.kind.ifBlank { "MOVIE" },
                    titleId = item.id,
                    season = lookup.season,
                    episode = lookup.episode,
                ).sortedByDescending { it.seeders }
                if (sources.isEmpty()) {
                    Toast.makeText(this@DetailsActivity, "No healthy sources", Toast.LENGTH_LONG).show()
                    return@launch
                }
                playSource(item, sources.first(), lookup)
            } catch (e: Exception) {
                Toast.makeText(this@DetailsActivity, e.message, Toast.LENGTH_LONG).show()
            } finally {
                searching = false
            }
        }
    }

    private fun sourceLookup(item: TitleItem): SourceLookup {
        val isSeries = item.kind.equals("SERIES", true) ||
            item.kind.equals("ANIME", true) ||
            item.kind.equals("TV", true)
        if (!isSeries) return SourceLookup(item.displayTitle, null, null)
        val target = item.seriesPlayTarget() ?: return SourceLookup(item.displayTitle, null, null)
        val season = target.first.seasonNumber
        val episode = target.second.episodeNumber
        return SourceLookup(
            String.format("%s S%02dE%02d", item.displayTitle, season, episode),
            season,
            episode,
        )
    }

    private fun playSource(item: TitleItem, source: StreamSource, lookup: SourceLookup) {
        val app = application.asPhone()
        Toast.makeText(this, "Starting stream…", Toast.LENGTH_SHORT).show()
        scope.launch {
            try {
                val started = LocalTorrentEngine.start(
                    context = this@DetailsActivity,
                    magnet = source.magnet,
                    season = lookup.season,
                    episode = lookup.episode,
                    resumeMs = item.positionMs,
                    durationMs = item.durationMs,
                )
                if (started.sessionId.isBlank() || started.url.isBlank()) {
                    Toast.makeText(this@DetailsActivity, "Couldn't start stream", Toast.LENGTH_LONG).show()
                    return@launch
                }
                startActivity(
                    Intent(this@DetailsActivity, PlayerActivity::class.java)
                        .putExtra(PlayerActivity.EXTRA_TITLE, item.displayTitle)
                        .putExtra(PlayerActivity.EXTRA_SESSION, started.sessionId)
                        .putExtra(PlayerActivity.EXTRA_URL, started.url)
                        .putExtra(PlayerActivity.EXTRA_LOCAL, true),
                )
            } catch (e: Exception) {
                Toast.makeText(this@DetailsActivity, e.message, Toast.LENGTH_LONG).show()
            }
        }
    }

    companion object {
        const val EXTRA_ID = "title_id"
        const val EXTRA_TITLE = "title_name"
    }
}

private data class SourceLookup(
    val query: String,
    val season: Int?,
    val episode: Int?,
)

private class SourceAdapter(
    private val items: List<StreamSource>,
    private val onClick: (StreamSource) -> Unit,
) : RecyclerView.Adapter<SourceAdapter.VH>() {
    class VH(val root: View) : RecyclerView.ViewHolder(root) {
        val title: TextView = root.findViewById(R.id.source_title)
        val meta: TextView = root.findViewById(R.id.source_meta)
        val health: TextView = root.findViewById(R.id.source_health)
    }

    override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): VH {
        val v = LayoutInflater.from(parent.context)
            .inflate(R.layout.item_source, parent, false)
        return VH(v)
    }

    override fun onBindViewHolder(holder: VH, position: Int) {
        val s = items[position]
        holder.title.text = s.title.ifBlank { "Torrent" }
        holder.meta.text = buildString {
            append("${s.seeders} seeders")
            if (s.size.isNotBlank()) append(" · ${s.size}")
            if (s.tracker.isNotBlank()) append(" · ${s.tracker}")
        }
        holder.health.text = s.health.replaceFirstChar { it.uppercase() }
        holder.root.setOnClickListener { onClick(s) }
    }

    override fun getItemCount(): Int = items.size
}
