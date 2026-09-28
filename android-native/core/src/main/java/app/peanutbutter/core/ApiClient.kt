package app.peanutbutter.core

import com.google.gson.Gson
import com.google.gson.JsonArray
import com.google.gson.JsonElement
import com.google.gson.JsonObject
import com.google.gson.JsonParser
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.util.concurrent.TimeUnit

class ApiException(message: String) : Exception(message)

/**
 * Thin GraphQL client for PeanutButter server.
 * Sends [X-Api-Key] pairing token — same contract as the Flutter apps.
 */
class ApiClient(
    private val session: SessionStore,
    private val http: OkHttpClient = defaultClient(),
) {
    private val gson = Gson()
    private val jsonMedia = "application/json; charset=utf-8".toMediaType()

    fun graphqlUrl(): String {
        val base = session.serverUrl.trim().trimEnd('/')
        require(base.isNotBlank()) { "Server URL is empty — pair first." }
        return if (base.endsWith("/graphql")) base else "$base/graphql"
    }

    suspend fun healthOk(): Boolean = withContext(Dispatchers.IO) {
        val base = session.serverUrl.trim().trimEnd('/')
        if (base.isBlank()) return@withContext false
        Discovery.isPeanutButter(base)
    }

    suspend fun serverInfo(): ServerInfo = withContext(Dispatchers.IO) {
        val data = gql(Gql.SERVER_INFO)
        val info = data.getAsJsonObject("serverInfo")
        val sync = info.get("syncStatus")?.takeUnless { it.isJsonNull }?.asJsonObject
        val langs = info.getAsJsonArray("preferredLanguages")?.mapNotNull { el ->
            el.takeUnless { it.isJsonNull }?.asString?.trim()?.lowercase()?.takeIf { it.isNotEmpty() }
        }.orEmpty()
        ServerInfo(
            version = info.getStringOr("version", ""),
            totalTitles = sync?.getIntOr("totalTitles", 0) ?: 0,
            jackettConfigured = info.getBooleanOr("jackettConfigured", false),
            preferredLanguages = langs,
            opensubtitlesEnabled = info.getBooleanOr("opensubtitlesEnabled", false),
            opensubtitlesConfigured = info.getBooleanOr("opensubtitlesConfigured", false),
        )
    }

    suspend fun updatePreferredLanguages(codes: List<String>): Unit = withContext(Dispatchers.IO) {
        gql(Gql.UPDATE_SETTINGS, mapOf("input" to mapOf("preferredLanguages" to codes)))
    }

    suspend fun updateOpenSubtitles(enabled: Boolean, apiKey: String?): Unit = withContext(Dispatchers.IO) {
        val input = mutableMapOf<String, Any?>("opensubtitlesEnabled" to enabled)
        if (!apiKey.isNullOrBlank()) input["opensubtitlesApiKey"] = apiKey.trim()
        gql(Gql.UPDATE_SETTINGS, mapOf("input" to input))
    }

    suspend fun fetchSubtitles(
        titleId: String,
        language: String,
        season: Int?,
        episode: Int?,
    ): List<FetchedSubtitle> = withContext(Dispatchers.IO) {
        val data = gql(
            Gql.FETCH_SUBTITLES,
            mapOf(
                "titleId" to titleId,
                "language" to language,
                "season" to season,
                "episode" to episode,
            ),
        )
        data.getAsJsonArray("fetchSubtitles")?.mapNotNull { el ->
            val row = el.takeUnless { it.isJsonNull }?.asJsonObject ?: return@mapNotNull null
            FetchedSubtitle(
                id = row.getStringOr("id", ""),
                language = row.getStringOr("language", language),
                label = row.getStringOr("label", "Subtitle"),
                content = row.getStringOr("content", ""),
            )
        }.orEmpty()
    }

    suspend fun downloadBytes(url: String, maxBytes: Int = 5 * 1024 * 1024): ByteArray =
        withContext(Dispatchers.IO) {
            val req = Request.Builder()
                .url(url)
                .header("User-Agent", "PeanutButter/0.2")
                .build()
            http.newCall(req).execute().use { res ->
                if (!res.isSuccessful) throw ApiException("Couldn't download that subtitle.")
                val bytes = res.body?.bytes() ?: throw ApiException("That link didn't return a subtitle file.")
                if (bytes.isEmpty()) throw ApiException("That link didn't return a subtitle file.")
                if (bytes.size > maxBytes) throw ApiException("That subtitle is larger than 5 MB.")
                bytes
            }
        }

    suspend fun homeFeed(kind: String = "MOVIE"): HomeFeed = withContext(Dispatchers.IO) {
        val data = gql(Gql.HOME_FEED, mapOf("kind" to kind))
        val feed = data.getAsJsonObject("homeFeed")
        HomeFeed(
            trending = parseTitles(feed.getAsJsonArray("trending")),
            popular = parseTitles(feed.getAsJsonArray("popular")),
            recent = parseTitles(feed.getAsJsonArray("recent")),
            continueWatching = parseTitles(feed.getAsJsonArray("continueWatching")),
        )
    }

    suspend fun title(id: String): TitleItem = withContext(Dispatchers.IO) {
        val data = gql(Gql.TITLE, mapOf("id" to id))
        parseTitle(data.getAsJsonObject("title"))
    }

    suspend fun search(query: String, kind: String? = null): List<TitleItem> = withContext(Dispatchers.IO) {
        val vars = mutableMapOf<String, Any?>("q" to query)
        if (kind != null) vars["kind"] = kind
        val data = gql(Gql.SEARCH, vars)
        val root = data.getAsJsonObject("search")
        parseTitles(root.getAsJsonArray("items"))
    }

    suspend fun genres(): List<String> = withContext(Dispatchers.IO) {
        val data = gql(Gql.GENRES)
        data.getAsJsonArray("genres")?.mapNotNull { el ->
            el.takeUnless { it.isJsonNull }?.asString?.trim()?.takeIf { it.isNotEmpty() }
        }.orEmpty()
    }

    suspend fun catalog(
        kind: String? = null,
        sort: String = "TRENDING",
        dir: String = "DESC",
        page: Int = 1,
        perPage: Int = 48,
        genre: String? = null,
        yearMin: Int? = null,
        yearMax: Int? = null,
        ratingMin: Double? = null,
    ): CatalogPage = withContext(Dispatchers.IO) {
        val vars = mutableMapOf<String, Any?>(
            "sort" to sort,
            "dir" to dir,
            "page" to page,
            "perPage" to perPage,
            "genre" to genre,
            "yearMin" to yearMin,
            "yearMax" to yearMax,
            "ratingMin" to ratingMin,
        )
        if (kind != null) vars["kind"] = kind
        val data = gql(Gql.CATALOG, vars)
        val root = data.getAsJsonObject("catalog")
        CatalogPage(
            items = parseTitles(root.getAsJsonArray("items")),
            totalCount = root.getIntOr("totalCount", 0),
            hasNextPage = root.getBooleanOr("hasNextPage", false),
            page = root.getIntOr("page", page),
        )
    }

    suspend fun streamingSearch(
        query: String,
        kind: String,
        titleId: String?,
        season: Int? = null,
        episode: Int? = null,
        live: Boolean = false,
    ): List<StreamSource> = withContext(Dispatchers.IO) {
        val vars = mutableMapOf<String, Any?>(
            "query" to query,
            "kind" to kind,
            "titleId" to titleId,
            "season" to season,
            "episode" to episode,
            "live" to live,
        )
        val data = gql(Gql.STREAMING_SEARCH, vars)
        val arr = data.getAsJsonArray("streamingSearch") ?: JsonArray()
        arr.mapNotNull { el ->
            val o = el.asJsonObject
            StreamSource(
                id = o.getStringOr("id", ""),
                title = o.getStringOr("title", ""),
                magnet = o.getStringOr("magnet", ""),
                seeders = o.getIntOr("seeders", 0),
                peers = o.getIntOr("peers", 0),
                size = o.getStringOr("size", ""),
                tracker = o.getStringOr("tracker", ""),
                health = o.getStringOr("health", ""),
                indexer = o.getStringOr("indexer", ""),
                language = o.getStringOr("language", ""),
            )
        }
    }

    /**
     * Cache first, then one live Jackett refresh when the cache is empty.
     * Always passing live=true deleted a good cache and showed "no sources"
     * whenever an indexer timed out.
     */
    suspend fun lookupSources(
        query: String,
        kind: String,
        titleId: String?,
        season: Int? = null,
        episode: Int? = null,
    ): List<StreamSource> {
        val cached = streamingSearch(
            query = query,
            kind = kind,
            titleId = titleId,
            season = season,
            episode = episode,
            live = false,
        )
        if (cached.isNotEmpty()) return cached
        return streamingSearch(
            query = query,
            kind = kind,
            titleId = titleId,
            season = season,
            episode = episode,
            live = true,
        )
    }

    /** Last magnet used for this title/episode. Resume replays it without the picker. */
    suspend fun streamBookmark(
        titleId: String,
        season: Int? = null,
        episode: Int? = null,
    ): StreamBookmark? = withContext(Dispatchers.IO) {
        val data = gql(
            Gql.STREAM_BOOKMARK,
            mapOf(
                "titleId" to titleId,
                "season" to season,
                "episode" to episode,
            ),
        )
        val el = data.get("streamBookmark")?.takeUnless { it.isJsonNull } ?: return@withContext null
        val o = el.asJsonObject
        val magnet = o.getStringOr("magnet", "")
        if (magnet.isBlank()) return@withContext null
        StreamBookmark(
            magnet = magnet,
            resumePosition = o.getIntOr("resumePosition", 0),
            season = o.get("season")?.takeUnless { it.isJsonNull }?.asInt,
            episode = o.get("episode")?.takeUnless { it.isJsonNull }?.asInt,
            fileIndex = o.get("fileIndex")?.takeUnless { it.isJsonNull }?.asInt,
        )
    }

    suspend fun startStream(
        magnet: String,
        title: String,
        titleId: String?,
        seeders: Int = 0,
        peers: Int = 0,
        season: Int? = null,
        episode: Int? = null,
        fileIndex: Int? = null,
        resume: Boolean = true,
    ): StreamStart = withContext(Dispatchers.IO) {
        val data = gql(
            Gql.START_STREAM,
            mapOf(
                "magnet" to magnet,
                "title" to title,
                "titleId" to titleId,
                "resume" to resume,
                "seeders" to seeders,
                "peers" to peers,
                "season" to season,
                "episode" to episode,
                "fileIndex" to fileIndex,
            ),
        )
        val s = parseStreamSession(data.getAsJsonObject("startStream"))
        StreamStart(
            sessionId = s.id,
            streamUrl = s.streamUrl,
            title = s.title.ifBlank { title },
            status = s.status,
            localTorrent = false,
        )
    }

    suspend fun streamStatus(sessionId: String): StreamSession = withContext(Dispatchers.IO) {
        val data = gql(Gql.STREAM_STATUS, mapOf("sessionId" to sessionId))
        parseStreamSession(data.getAsJsonObject("streamStatus"))
    }

    /**
     * Poll until the torrent session is ready (or errors / times out).
     * Mirrors Flutter player wait loop (~350ms cadence).
     */
    suspend fun waitUntilStreamReady(
        sessionId: String,
        timeoutMs: Long = 90_000L,
        pollMs: Long = 400L,
        onTick: ((StreamSession) -> Unit)? = null,
    ): StreamSession = withContext(Dispatchers.IO) {
        val deadline = System.currentTimeMillis() + timeoutMs
        var last = streamStatus(sessionId)
        onTick?.invoke(last)
        while (last.streamUrl.isBlank() && !last.isError && System.currentTimeMillis() < deadline) {
            Thread.sleep(pollMs)
            last = streamStatus(sessionId)
            onTick?.invoke(last)
        }
        last
    }

    suspend fun stopStream(sessionId: String) = withContext(Dispatchers.IO) {
        gql(Gql.STOP_STREAM, mapOf("sessionId" to sessionId))
        Unit
    }

    suspend fun setFavorite(titleId: String, favorite: Boolean) = withContext(Dispatchers.IO) {
        gql(Gql.SET_FAVORITE, mapOf("titleId" to titleId, "favorite" to favorite))
        Unit
    }

    suspend fun setWatched(titleId: String, watched: Boolean) = withContext(Dispatchers.IO) {
        gql(Gql.SET_WATCHED, mapOf("titleId" to titleId, "watched" to watched))
        Unit
    }

    /** Persist playback so Continue watching can list this title. */
    suspend fun updateProgress(
        titleId: String,
        episodeId: String?,
        positionMs: Long,
        durationMs: Long?,
        complete: Boolean = false,
    ) = withContext(Dispatchers.IO) {
        val vars = mutableMapOf<String, Any?>(
            "titleId" to titleId,
            "positionMs" to positionMs.coerceIn(0L, Int.MAX_VALUE.toLong()).toInt(),
        )
        if (!episodeId.isNullOrBlank()) vars["episodeId"] = episodeId
        if (durationMs != null && durationMs > 0) {
            vars["durationMs"] = durationMs.coerceIn(0L, Int.MAX_VALUE.toLong()).toInt()
        }
        if (complete) vars["complete"] = true
        gql(Gql.UPDATE_PROGRESS, vars)
        Unit
    }

    /** Rewrite host for emulator + append pairing key. */
    fun playableStreamUrl(url: String): String {
        val resolved = resolveMediaUrl(url) ?: url
        return mediaUrlWithAuth(resolved)
    }

    fun mediaUrlWithAuth(url: String): String {
        if (url.isBlank()) return url
        val token = session.apiToken.trim()
        if (token.isBlank()) return url
        // Flutter parity: prefer bare 6-digit pairing code for ?key=
        val key = token.filter { it.isDigit() }.let { digits ->
            if (digits.length == 6) digits else token
        }
        if (key.isBlank()) return url
        val uri = runCatching { java.net.URI(url) }.getOrNull()
        if (uri != null && !uri.scheme.isNullOrBlank()) {
            val q = uri.query.orEmpty()
            if (q.contains("key=")) return url
            val sep = if (q.isEmpty()) "?" else "&"
            return "$url${sep}key=$key"
        }
        val sep = if (url.contains('?')) '&' else '?'
        return "$url${sep}key=$key"
    }

    /**
     * Mirror Flutter [resolveServerResourceUrl]: rewrite /art|/media|/stream
     * (and loopback hosts) onto the paired server base so emulator/TV can load art.
     */
    fun resolveMediaUrl(url: String?): String? {
        val raw = url?.trim().orEmpty()
        if (raw.isEmpty()) return url
        val base = session.serverUrl.trim().trimEnd('/')
        if (base.isEmpty()) return raw
        val serverUri = runCatching { java.net.URI(base) }.getOrNull() ?: return raw
        if (serverUri.host.isNullOrBlank()) return raw

        val parsed = runCatching { java.net.URI(raw) }.getOrNull()
        if (parsed == null || parsed.scheme.isNullOrBlank() || parsed.host.isNullOrBlank()) {
            // Relative path
            return "$base/${raw.trimStart('/')}"
        }

        val path = parsed.path.orEmpty()
        val isAppMedia = path.startsWith("/stream/") ||
            path.startsWith("/media/") ||
            path.startsWith("/art/")
        val host = parsed.host.lowercase()
        val loopback = host == "127.0.0.1" || host == "localhost" || host == "::1"
        if (!isAppMedia && !loopback) return raw

        val port = if (serverUri.port > 0) serverUri.port else -1
        return runCatching {
            java.net.URI(
                serverUri.scheme,
                null,
                serverUri.host,
                port,
                path,
                parsed.query,
                parsed.fragment,
            ).toString()
        }.getOrDefault(raw)
    }

    private fun gql(query: String, variables: Map<String, Any?> = emptyMap()): JsonObject {
        // Omit nulls — GraphQL servers often reject explicit null for optional ints.
        val cleaned = variables.filterValues { it != null }
        val body = JsonObject().apply {
            addProperty("query", query)
            if (cleaned.isNotEmpty()) {
                add("variables", gson.toJsonTree(cleaned))
            }
        }.toString()
        val builder = Request.Builder()
            .url(graphqlUrl())
            .post(body.toRequestBody(jsonMedia))
            .header("Accept", "application/json")
            .header("Content-Type", "application/json")
        val token = session.apiToken
        if (token.isNotBlank()) builder.header("X-Api-Key", token)

        http.newCall(builder.build()).execute().use { res ->
            val text = res.body?.string().orEmpty()
            if (res.code == 401 || res.code == 403) {
                throw ApiException("Pairing code rejected. Create a new code on the server.")
            }
            if (!res.isSuccessful) {
                throw ApiException("Server error ${res.code}")
            }
            val root = JsonParser.parseString(text).asJsonObject
            val errors = root.getAsJsonArray("errors")
            if (errors != null && errors.size() > 0) {
                val msg = errors[0].asJsonObject.get("message")?.asString ?: "GraphQL error"
                throw ApiException(msg)
            }
            return root.getAsJsonObject("data")
                ?: throw ApiException("Empty GraphQL response")
        }
    }

    private fun parseStreamSession(o: JsonObject?): StreamSession {
        if (o == null) {
            return StreamSession(id = "", title = "", status = "error: empty session")
        }
        return StreamSession(
            id = o.getStringOr("id", ""),
            title = o.getStringOr("title", ""),
            progress = o.get("progress")?.takeUnless { it.isJsonNull }?.asDouble ?: 0.0,
            bufferProgress = o.get("bufferProgress")?.takeUnless { it.isJsonNull }?.asDouble ?: 0.0,
            downloadMbps = o.get("downloadMbps")?.takeUnless { it.isJsonNull }?.asDouble ?: 0.0,
            seeders = o.getIntOr("seeders", 0),
            peers = o.getIntOr("peers", 0),
            resumePosition = o.getIntOr("resumePosition", 0),
            status = o.getStringOr("status", ""),
            streamUrl = o.getStringOr("streamUrl", ""),
        )
    }

    private fun parseTitles(arr: JsonArray?): List<TitleItem> {
        if (arr == null) return emptyList()
        return arr.mapNotNull { runCatching { parseTitle(it.asJsonObject) }.getOrNull() }
    }

    private fun parseTitle(o: JsonObject): TitleItem {
        val ratingsEl = o.get("ratings")
        val ratings = ratingsEl?.takeUnless { it.isJsonNull }?.asJsonObject
        val stateEl = o.get("userState")
        val state = stateEl?.takeUnless { it.isJsonNull }?.asJsonObject
        val genres = o.getAsJsonArray("genres")?.mapNotNull {
            it.takeIf { e -> e.isJsonPrimitive }?.asString
        }.orEmpty()
        return TitleItem(
            id = o.getStringOr("id", ""),
            kind = o.getStringOr("kind", "MOVIE"),
            title = o.getStringOr("title", ""),
            synopsis = o.get("synopsis")?.takeUnless { it.isJsonNull }?.asString,
            year = o.get("year")?.takeUnless { it.isJsonNull }?.asInt,
            runtimeMinutes = o.get("runtimeMinutes")?.takeUnless { it.isJsonNull }?.asInt,
            posterUrl = resolveMediaUrl(o.get("posterUrl")?.takeUnless { it.isJsonNull }?.asString),
            backdropUrl = resolveMediaUrl(o.get("backdropUrl")?.takeUnless { it.isJsonNull }?.asString),
            logoUrl = resolveMediaUrl(o.get("logoUrl")?.takeUnless { it.isJsonNull }?.asString),
            imdbRating = ratings?.get("imdbRating")?.takeUnless { it.isJsonNull }?.asDouble,
            tmdbVoteAverage = ratings?.get("tmdbVoteAverage")?.takeUnless { it.isJsonNull }?.asDouble,
            rtScore = ratings?.get("rtScore")?.takeUnless { it.isJsonNull }?.asInt,
            genres = genres,
            positionMs = state?.getLongOr("positionMs", 0) ?: 0,
            durationMs = state?.getLongOr("durationMs", 0) ?: 0,
            progressPercent = state?.get("progressPercent")?.takeUnless { it.isJsonNull }?.asDouble ?: 0.0,
            watched = state?.getBooleanOr("watched", false) ?: false,
            favorite = state?.getBooleanOr("favorite", false) ?: false,
            trailerYoutubeKey = o.get("trailerYoutubeKey")?.takeUnless { it.isJsonNull }?.asString,
            trailers = o.getAsJsonArray("trailers")?.mapNotNull { el ->
                runCatching {
                    val t = el.asJsonObject
                    Trailer(
                        id = t.getStringOr("id", ""),
                        name = t.getStringOr("name", "Trailer"),
                        youtubeKey = t.getStringOr("youtubeKey", ""),
                        site = t.getStringOr("site", "YouTube"),
                        size = t.get("size")?.takeUnless { it.isJsonNull }?.asInt,
                    ).takeIf { it.youtubeKey.isNotBlank() }
                }.getOrNull()
            }.orEmpty(),
            people = o.getAsJsonArray("people")?.mapNotNull { el ->
                runCatching {
                    val p = el.asJsonObject
                    Person(
                        id = p.getStringOr("id", p.getStringOr("name", "")),
                        name = p.getStringOr("name", ""),
                        department = p.getStringOr("department", "cast"),
                        character = p.get("character")?.takeUnless { it.isJsonNull }?.asString,
                        job = p.get("job")?.takeUnless { it.isJsonNull }?.asString,
                        profileUrl = resolveMediaUrl(
                            p.get("profileUrl")?.takeUnless { it.isJsonNull }?.asString,
                        ),
                    ).takeIf { it.name.isNotBlank() }
                }.getOrNull()
            }.orEmpty(),
            seasons = o.getAsJsonArray("seasons")?.mapNotNull { el ->
                runCatching { parseSeason(el.asJsonObject) }
                    .onFailure { android.util.Log.w("ApiClient", "parseSeason failed", it) }
                    .getOrNull()
            }.orEmpty(),
            episodeId = state?.get("episodeId")?.takeUnless { it.isJsonNull }?.asString,
        )
    }

    private fun parseSeason(o: JsonObject): Season {
        val episodes = o.getAsJsonArray("episodes")?.mapNotNull { el ->
            runCatching {
                val e = el.asJsonObject
                val st = e.get("userState")?.takeUnless { it.isJsonNull }?.asJsonObject
                val id = e.getStringOr("id", "")
                if (id.isBlank()) return@runCatching null
                Episode(
                    id = id,
                    episodeNumber = e.getIntOr("episodeNumber", 0),
                    name = e.get("name")?.takeUnless { it.isJsonNull }?.asString,
                    overview = e.get("overview")?.takeUnless { it.isJsonNull }?.asString,
                    stillPath = resolveMediaUrl(
                        e.get("stillPath")?.takeUnless { it.isJsonNull }?.asString,
                    ),
                    airDate = e.get("airDate")?.takeUnless { it.isJsonNull }?.asString,
                    runtime = e.get("runtime")?.takeUnless { it.isJsonNull }?.asInt,
                    watched = st?.getBooleanOr("watched", false) ?: false,
                    positionMs = st?.getLongOr("positionMs", 0) ?: 0,
                    durationMs = st?.getLongOr("durationMs", 0) ?: 0,
                    progressPercent = st?.get("progressPercent")?.takeUnless { it.isJsonNull }?.asDouble
                        ?: 0.0,
                )
            }.onFailure {
                android.util.Log.w("ApiClient", "parseEpisode failed", it)
            }.getOrNull()
        }.orEmpty()
        return Season(
            id = o.getStringOr("id", ""),
            seasonNumber = o.getIntOr("seasonNumber", 0),
            name = o.get("name")?.takeUnless { it.isJsonNull }?.asString,
            overview = o.get("overview")?.takeUnless { it.isJsonNull }?.asString,
            posterPath = resolveMediaUrl(
                o.get("posterPath")?.takeUnless { it.isJsonNull }?.asString,
            ),
            airDate = o.get("airDate")?.takeUnless { it.isJsonNull }?.asString,
            episodeCount = o.get("episodeCount")?.takeUnless { it.isJsonNull }?.asInt,
            episodes = episodes,
        )
    }

    suspend fun mediaSegments(
        titleId: String,
        season: Int? = null,
        episode: Int? = null,
        durationMs: Int? = null,
    ): List<MediaSegment> = withContext(Dispatchers.IO) {
        val data = gql(
            Gql.MEDIA_SEGMENTS,
            mapOf(
                "titleId" to titleId,
                "season" to season,
                "episode" to episode,
                "durationMs" to durationMs,
            ),
        )
        val root = data.getAsJsonObject("mediaSegments") ?: return@withContext emptyList()
        root.getAsJsonArray("segments")?.mapNotNull { el ->
            runCatching {
                val s = el.asJsonObject
                MediaSegment(
                    kind = s.getStringOr("kind", "").uppercase(),
                    label = s.getStringOr("label", "Skip"),
                    startMs = s.getIntOr("startMs", 0),
                    endMs = s.get("endMs")?.takeUnless { it.isJsonNull }?.asInt,
                )
            }.getOrNull()
        }.orEmpty()
    }

    companion object {
        fun defaultClient(): OkHttpClient = OkHttpClient.Builder()
            .connectTimeout(12, TimeUnit.SECONDS)
            .readTimeout(90, TimeUnit.SECONDS)
            .writeTimeout(30, TimeUnit.SECONDS)
            .build()
    }
}

private fun JsonObject.getStringOr(key: String, fallback: String): String =
    get(key)?.takeUnless { it.isJsonNull }?.asString ?: fallback

private fun JsonObject.getIntOr(key: String, fallback: Int): Int =
    get(key)?.takeUnless { it.isJsonNull }?.asInt ?: fallback

private fun JsonObject.getLongOr(key: String, fallback: Long): Long =
    get(key)?.takeUnless { it.isJsonNull }?.asLong ?: fallback

private fun JsonObject.getBooleanOr(key: String, fallback: Boolean): Boolean =
    get(key)?.takeUnless { it.isJsonNull }?.asBoolean ?: fallback

private fun JsonElement?.asLongSafe(): Long? =
    this?.takeUnless { it.isJsonNull }?.asLong
