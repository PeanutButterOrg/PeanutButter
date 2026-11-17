package app.peanutbutter.core

/** How a home shelf draws its cards. */
enum class ShelfStyle { POSTER, TOP10, WIDE }

/** One home shelf. [kind] null: See all opens movies and series. */
data class HomeShelf(
    val title: String,
    val sort: String,
    val kind: String?,
    val items: List<TitleItem>,
    val style: ShelfStyle = ShelfStyle.POSTER,
)

/** What a home section shows: hero slides (each with its eyebrow) and shelves. */
data class HomeLayout(
    val hero: List<TitleItem>,
    val eyebrows: List<String>,
    val shelves: List<HomeShelf>,
) {
    val isEmpty: Boolean get() = hero.isEmpty() && shelves.all { it.items.isEmpty() }
}

/** A poster in a Top 10 shelf, with its rank. */
data class RankedTitle(val rank: Int, val item: TitleItem)

/** A Continue watching card (16:9 still, time left, progress). */
data class WideTitle(val item: TitleItem)

/**
 * The home sections, same on desktop, the TV app and the Launcher:
 * HOME mixes movies and series; MOVIE and SERIES show one kind.
 */
object HomeSections {
    const val HOME = "HOME"

    fun build(section: String, movies: HomeFeed?, series: HomeFeed?): HomeLayout {
        val empty = HomeFeed(emptyList(), emptyList(), emptyList(), emptyList())
        val m = movies ?: empty
        val s = series ?: empty
        if (section == HOME) {
            val heroMovies = m.trending.take(5)
            val heroSeries = s.trending.take(5)
            val hero = interleave(heroMovies, heroSeries)
            val eyebrows = hero.map { item ->
                val im = heroMovies.indexOf(item)
                if (im >= 0) "#${im + 1} trending · Movie" else "#${heroSeries.indexOf(item) + 1} trending · Series"
            }
            return HomeLayout(
                hero,
                eyebrows,
                listOf(
                    HomeShelf("Continue watching", "CONTINUE_WATCHING", null,
                        interleave(m.continueWatching, s.continueWatching), ShelfStyle.WIDE),
                    // One Top 10 for movies and series together, in trending order.
                    HomeShelf("Top 10 today", "TRENDING", null, interleave(m.trending, s.trending).take(10), ShelfStyle.TOP10),
                    HomeShelf("Popular movies", "POPULARITY", "MOVIE", m.popular),
                    HomeShelf("Popular series", "POPULARITY", "SERIES", s.popular),
                    HomeShelf("Recently added", "DATE_ADDED", null, interleave(m.recent, s.recent)),
                ),
            )
        }
        val feed = if (section == "SERIES") s else m
        val noun = if (section == "SERIES") "series" else "movies"
        val label = if (section == "SERIES") "Series" else "Movie"
        val hero = feed.trending.take(8)
        return HomeLayout(
            hero,
            hero.indices.map { "#${it + 1} trending · $label" },
            listOf(
                HomeShelf("Continue watching", "CONTINUE_WATCHING", null, feed.continueWatching, ShelfStyle.WIDE),
                HomeShelf("Top 10 $noun today", "TRENDING", section, feed.trending.take(10), ShelfStyle.TOP10),
                HomeShelf("Trending $noun", "TRENDING", section, feed.trending.drop(10)),
                HomeShelf("Popular $noun", "POPULARITY", section, feed.popular),
                HomeShelf("Recently added", "DATE_ADDED", section, feed.recent),
            ),
        )
    }

    /** "31 min left", "1h 12m left", or "Resume" when the length isn't known. */
    fun timeLeft(item: TitleItem): String {
        val duration = item.durationMs
        val position = item.positionMs
        if (duration <= 0 || position <= 0 || position >= duration) return "Resume"
        val minutes = ((duration - position + 59_999) / 60_000).toInt()
        if (minutes < 60) return "$minutes min left"
        val h = minutes / 60
        val rest = minutes % 60
        return if (rest == 0) "${h}h left" else "${h}h ${rest}m left"
    }

    private fun interleave(a: List<TitleItem>, b: List<TitleItem>): List<TitleItem> {
        val out = ArrayList<TitleItem>(a.size + b.size)
        val seen = HashSet<String>()
        for (i in 0 until maxOf(a.size, b.size)) {
            a.getOrNull(i)?.let { if (seen.add(it.id)) out.add(it) }
            b.getOrNull(i)?.let { if (seen.add(it.id)) out.add(it) }
        }
        return out
    }
}
