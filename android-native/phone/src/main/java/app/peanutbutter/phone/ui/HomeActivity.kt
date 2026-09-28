package app.peanutbutter.phone.ui

import android.content.Intent
import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.ImageView
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import androidx.recyclerview.widget.GridLayoutManager
import androidx.recyclerview.widget.RecyclerView
import app.peanutbutter.core.TitleItem
import app.peanutbutter.phone.R
import app.peanutbutter.phone.asPhone
import com.bumptech.glide.Glide
import com.google.android.material.button.MaterialButton
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

class HomeActivity : AppCompatActivity() {
    private val scope = CoroutineScope(Dispatchers.Main + Job())
    private val items = mutableListOf<TitleItem>()
    private lateinit var adapter: PosterAdapter

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_home)
        val app = application.asPhone()
        findViewById<TextView>(R.id.server_label).text = app.session.serverUrl
        findViewById<MaterialButton>(R.id.disconnect).setOnClickListener {
            app.session.clear()
            startActivity(Intent(this, PairingActivity::class.java))
            finish()
        }
        adapter = PosterAdapter(items) { title ->
            startActivity(
                Intent(this, DetailsActivity::class.java)
                    .putExtra(DetailsActivity.EXTRA_ID, title.id)
                    .putExtra(DetailsActivity.EXTRA_TITLE, title.title),
            )
        }
        val list = findViewById<RecyclerView>(R.id.list)
        list.layoutManager = GridLayoutManager(this@HomeActivity, 3)
        list.adapter = adapter
        scope.launch {
            try {
                val feed = app.api.homeFeed("MOVIE")
                items.clear()
                items += feed.continueWatching
                items += feed.trending
                items += feed.popular
                items += feed.recent
                // de-dupe by id preserving order
                val seen = HashSet<String>()
                val unique = items.filter { seen.add(it.id) }
                items.clear()
                items += unique
                adapter.notifyDataSetChanged()
            } catch (e: Exception) {
                Toast.makeText(this@HomeActivity, e.message, Toast.LENGTH_LONG).show()
            }
        }
    }
}

class PosterAdapter(
    private val items: List<TitleItem>,
    private val onClick: (TitleItem) -> Unit,
) : RecyclerView.Adapter<PosterAdapter.VH>() {
    class VH(view: View) : RecyclerView.ViewHolder(view) {
        val poster: ImageView = view.findViewById(R.id.poster)
        val title: TextView = view.findViewById(R.id.title)
        val year: TextView = view.findViewById(R.id.year)
    }

    override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): VH {
        val v = LayoutInflater.from(parent.context).inflate(R.layout.item_poster, parent, false)
        return VH(v)
    }

    override fun getItemCount() = items.size

    override fun onBindViewHolder(holder: VH, position: Int) {
        val item = items[position]
        holder.title.text = item.title
        holder.year.text = item.year?.toString().orEmpty()
        holder.year.visibility = if (item.year != null) View.VISIBLE else View.GONE
        Glide.with(holder.poster)
            .load(item.posterUrl)
            .placeholder(R.drawable.poster_placeholder)
            .into(holder.poster)
        holder.itemView.setOnClickListener { onClick(item) }
    }
}
