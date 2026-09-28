package app.peanutbutter.core

object Gql {
    const val HOME_FEED = """
query GetHomeFeed(${'$'}kind: TitleKind!) {
  homeFeed(kind: ${'$'}kind) {
    trending { ...T }
    popular { ...T }
    recent { ...T }
    continueWatching { ...T }
  }
}
fragment T on Title {
  id kind title synopsis year runtimeMinutes
  posterUrl backdropUrl logoUrl
  ratings { tmdbVoteAverage imdbRating rtScore }
  genres
  userState { positionMs durationMs progressPercent watched favorite }
}
"""

    const val TITLE = """
query GetTitle(${'$'}id: UUID!) {
  title(id: ${'$'}id) {
    id kind title synopsis year runtimeMinutes
    posterUrl backdropUrl logoUrl
    ratings { tmdbVoteAverage imdbRating rtScore }
    genres
    trailerYoutubeKey
    trailers { id name youtubeKey site size }
    people { id name character job department profileUrl }
    seasons {
      id seasonNumber name overview posterPath airDate episodeCount
      episodes {
        id episodeNumber name overview stillPath airDate runtime
        userState { watched positionMs durationMs progressPercent }
      }
    }
    userState { positionMs durationMs progressPercent fileId episodeId watched favorite }
  }
}
"""

    const val MEDIA_SEGMENTS = """
query MediaSegments(${'$'}titleId: UUID!, ${'$'}season: Int, ${'$'}episode: Int, ${'$'}durationMs: Int) {
  mediaSegments(titleId: ${'$'}titleId, season: ${'$'}season, episode: ${'$'}episode, durationMs: ${'$'}durationMs) {
    segments { kind label startMs endMs }
  }
}
"""

    const val SERVER_INFO = """
query ServerInfo {
  serverInfo {
    version
    jackettConfigured
    preferredLanguages
    opensubtitlesEnabled
    opensubtitlesConfigured
    syncStatus { totalTitles }
  }
}
"""

    const val FETCH_SUBTITLES = """
mutation FetchSubtitles(${'$'}titleId: UUID!, ${'$'}language: String, ${'$'}season: Int, ${'$'}episode: Int) {
  fetchSubtitles(titleId: ${'$'}titleId, language: ${'$'}language, season: ${'$'}season, episode: ${'$'}episode) {
    id language label format content
  }
}
"""

    const val UPDATE_SETTINGS = """
mutation UpdateSettings(${'$'}input: SettingsInput!) {
  updateSettings(input: ${'$'}input) { success message }
}
"""

    const val STREAMING_SEARCH = """
query StreamingSearch(
  ${'$'}query: String!, ${'$'}kind: TitleKind!, ${'$'}titleId: UUID,
  ${'$'}season: Int, ${'$'}episode: Int, ${'$'}live: Boolean
) {
  streamingSearch(
    query: ${'$'}query, kind: ${'$'}kind, titleId: ${'$'}titleId,
    season: ${'$'}season, episode: ${'$'}episode, live: ${'$'}live
  ) {
    id title magnet seeders peers size tracker health indexer language
  }
}
"""

    const val START_STREAM = """
mutation StartStream(
  ${'$'}magnet: String!, ${'$'}title: String!, ${'$'}titleId: UUID,
  ${'$'}resume: Boolean, ${'$'}seeders: Int, ${'$'}peers: Int,
  ${'$'}season: Int, ${'$'}episode: Int, ${'$'}fileIndex: Int
) {
  startStream(
    magnet: ${'$'}magnet, title: ${'$'}title, titleId: ${'$'}titleId,
    resume: ${'$'}resume, seeders: ${'$'}seeders, peers: ${'$'}peers,
    season: ${'$'}season, episode: ${'$'}episode, fileIndex: ${'$'}fileIndex
  ) {
    id title progress bufferProgress downloadMbps
    seeders peers resumePosition status streamUrl
  }
}
"""

    const val STREAM_STATUS = """
query StreamStatus(${'$'}sessionId: String!) {
  streamStatus(sessionId: ${'$'}sessionId) {
    id title progress bufferProgress downloadMbps
    seeders peers resumePosition status streamUrl
  }
}
"""

    const val STOP_STREAM = """
mutation StopStream(${'$'}sessionId: String!) {
  stopStream(sessionId: ${'$'}sessionId)
}
"""

    const val SET_FAVORITE = """
mutation SetFavorite(${'$'}titleId: UUID!, ${'$'}favorite: Boolean!) {
  setFavorite(titleId: ${'$'}titleId, favorite: ${'$'}favorite) { success }
}
"""

    const val UPDATE_PROGRESS = """
mutation UpdateProgress(${'$'}titleId: UUID!, ${'$'}episodeId: UUID, ${'$'}positionMs: Int!, ${'$'}durationMs: Int, ${'$'}complete: Boolean) {
  updateProgress(titleId: ${'$'}titleId, episodeId: ${'$'}episodeId, positionMs: ${'$'}positionMs, durationMs: ${'$'}durationMs, complete: ${'$'}complete) {
    success
  }
}
"""

    const val SET_WATCHED = """
mutation SetWatched(${'$'}titleId: UUID!, ${'$'}watched: Boolean!) {
  setWatched(titleId: ${'$'}titleId, watched: ${'$'}watched) { success }
}
"""

    const val GENRES = """
query Genres { genres }
"""

    const val SEARCH = """
query Search(${'$'}q: String!, ${'$'}kind: TitleKind) {
  search(query: ${'$'}q, kind: ${'$'}kind) {
    items { id kind title year posterUrl backdropUrl synopsis ratings { imdbRating tmdbVoteAverage rtScore } genres }
  }
}
"""

    const val CATALOG = """
query GetCatalog(
  ${'$'}kind: TitleKind, ${'$'}sort: SortField, ${'$'}dir: SortDir,
  ${'$'}page: Int, ${'$'}perPage: Int,
  ${'$'}genre: String, ${'$'}yearMin: Int, ${'$'}yearMax: Int, ${'$'}ratingMin: Float
) {
  catalog(
    filter: { kind: ${'$'}kind, genre: ${'$'}genre, yearMin: ${'$'}yearMin, yearMax: ${'$'}yearMax, ratingMin: ${'$'}ratingMin }
    sort: ${'$'}sort
    dir: ${'$'}dir
    page: ${'$'}page
    perPage: ${'$'}perPage
  ) {
    totalCount
    hasNextPage
    page
    items { ...T }
  }
}
fragment T on Title {
  id kind title synopsis year runtimeMinutes
  posterUrl backdropUrl logoUrl
  ratings { tmdbVoteAverage imdbRating rtScore }
  genres
  userState { positionMs durationMs progressPercent watched favorite }
}
"""
}
