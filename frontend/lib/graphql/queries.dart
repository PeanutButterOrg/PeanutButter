const String titleFields = r'''
  id
  kind
  title
  originalTitle
  synopsis
  description
  year
  runtimeMinutes
  posterUrl
  backdropUrl
  ratings {
    tmdbVoteAverage
    tmdbVoteCount
    imdbRating
    imdbVotes
    anilistScore
    anilistPopularity
  }
  genres
''';

const String GET_CATALOG = r'''
query GetCatalog(
  $kind: TitleKind
  $genre: String
  $yearMin: Int
  $yearMax: Int
  $ratingMin: Float
  $sort: SortField
  $dir: SortDir
  $page: Int
  $perPage: Int
) {
  catalog(
    filter: {
      kind: $kind
      genre: $genre
      yearMin: $yearMin
      yearMax: $yearMax
      ratingMin: $ratingMin
    }
    sort: $sort
    dir: $dir
    page: $page
    perPage: $perPage
  ) {
    totalCount
    hasNextPage
    page
    perPage
    items {
      id
      kind
      title
      originalTitle
      synopsis
      year
      runtimeMinutes
      posterUrl
      backdropUrl
      logoUrl
      thumbUrl
      ratings {
        tmdbVoteAverage
        imdbRating
        anilistScore
        rtScore
      }
      genres
      trailerYoutubeKey
      availablePeers
      bestQuality
      contentRating
      videoCodec
      audioCodec
      container
      userState {
        watched
        positionMs
        durationMs
        fileId
        episodeId
      }
    }
  }
}
''';

const String GET_TITLE = r'''
query GetTitle($id: UUID!) {
  title(id: $id) {
    id
    kind
    title
    originalTitle
    synopsis
    description
    year
    runtimeMinutes
    posterUrl
    backdropUrl
    logoUrl
    thumbUrl
    ratings {
      tmdbVoteAverage
      tmdbVoteCount
      imdbRating
      imdbVotes
      anilistScore
      anilistPopularity
      rtScore
    }
    genres
    trailers {
      id
      name
      youtubeKey
      site
      size
    }
    fileReferences {
      id
      kind
      quality
      container
      codec
      audioCodec
      sizeBytes
      availablePeers
      playbackUrl
      episodeId
    }
    seasons {
      id
      seasonNumber
      name
      overview
      posterPath
      airDate
      episodeCount
      episodes {
        id
        episodeNumber
        name
        overview
        stillPath
        airDate
        runtime
      }
    }
    people {
      id
      name
      character
      job
      department
      profileUrl
    }
    userState {
      favorite
      watched
      positionMs
      durationMs
      episodeId
      fileId
    }
    trailerYoutubeKey
    contentRating
    videoCodec
    audioCodec
    container
  }
}
''';

const String SEARCH_TITLES = r'''
query SearchTitles($query: String!, $kind: TitleKind, $page: Int, $perPage: Int) {
  search(query: $query, kind: $kind, page: $page, perPage: $perPage) {
    totalCount
    hasNextPage
    page
    items {
      id
      kind
      title
      originalTitle
      year
      posterUrl
      ratings {
        tmdbVoteAverage
        imdbRating
        anilistScore
        rtScore
      }
      genres
      trailerYoutubeKey
      availablePeers
      bestQuality
      contentRating
      videoCodec
      audioCodec
      container
    }
  }
}
''';

const String GET_SERVER_INFO = r'''
query GetServerInfo {
  serverInfo {
    version
    libraryPath
    tmdbConfigured
    omdbConfigured
    anilistConfigured
    jackettEnabled
    jackettConfigured
    jackettUrl
    streamingResolution
    jackettCatalog {
      ready
      syncing
      done
      total
      lastError
    }
    opensubtitlesEnabled
    opensubtitlesConfigured
    syncStatus {
      lastSyncAt
      totalTitles
      syncing
    }
  }
}
''';

const String GET_HOME_FEED = r'''
query GetHomeFeed($kind: TitleKind!) {
  homeFeed(kind: $kind) {
    trending { ...HomeTitle }
    popular { ...HomeTitle }
    recent { ...HomeTitle }
    continueWatching { ...HomeTitle }
  }
}

fragment HomeTitle on Title {
  id
  kind
  title
  originalTitle
  synopsis
  year
  runtimeMinutes
  posterUrl
  backdropUrl
  logoUrl
  thumbUrl
  ratings {
    tmdbVoteAverage
    imdbRating
    anilistScore
    rtScore
  }
  genres
  trailerYoutubeKey
  availablePeers
  bestQuality
  contentRating
  videoCodec
  audioCodec
  container
  userState {
    watched
    positionMs
    durationMs
    fileId
    episodeId
  }
}
''';

const String GET_GENRES = r'''
query GetGenres {
  genres
}
''';

const String REFRESH_TITLE = r'''
mutation RefreshTitle($id: UUID!) {
  refreshTitle(id: $id) {
    id
    title
  }
}
''';

const String TRIGGER_SYNC = r'''
mutation TriggerSync {
  triggerSync {
    success
    message
  }
}
''';

const String CREATE_TITLE = r'''
mutation CreateTitle($input: TitleInput!) {
  createTitle(input: $input) {
    id
    title
    kind
    year
  }
}
''';

const String UPDATE_TITLE = r'''
mutation UpdateTitle($id: UUID!, $input: TitleInput!) {
  updateTitle(id: $id, input: $input) {
    id
    title
    kind
    year
  }
}
''';

const String UPDATE_SETTINGS = r'''
mutation UpdateSettings($input: SettingsInput!) {
  updateSettings(input: $input) {
    success
    message
  }
}
''';

const String DELETE_TITLE = r'''
mutation DeleteTitle($id: UUID!) {
  deleteTitle(id: $id) {
    success
    message
  }
}
''';

const String SET_FAVORITE = r'''
mutation SetFavorite($titleId: UUID!, $favorite: Boolean!) {
  setFavorite(titleId: $titleId, favorite: $favorite) {
    success
    message
  }
}
''';

const String SET_WATCHED = r'''
mutation SetWatched($titleId: UUID!, $watched: Boolean!) {
  setWatched(titleId: $titleId, watched: $watched) {
    success
    message
  }
}
''';

const String UPDATE_PROGRESS = r'''
mutation UpdateProgress($titleId: UUID!, $fileId: UUID, $episodeId: UUID, $positionMs: Int!, $durationMs: Int) {
  updateProgress(titleId: $titleId, fileId: $fileId, episodeId: $episodeId, positionMs: $positionMs, durationMs: $durationMs) {
    success
  }
}
''';

const String NEXT_PLAYBACK = r'''
query NextPlayback($fileId: UUID!) {
  nextPlayback(fileId: $fileId) {
    id
    playbackUrl
    quality
    episodeId
  }
}
''';

const String STREAMING_SEARCH = r'''
query StreamingSearch($query: String!, $kind: TitleKind!, $season: Int, $episode: Int, $language: String, $titleId: UUID, $live: Boolean) {
  streamingSearch(query: $query, kind: $kind, season: $season, episode: $episode, language: $language, titleId: $titleId, live: $live) {
    id
    title
    magnet
    seeders
    peers
    rating
    health
    size
    tracker
    indexer
    language
  }
}
''';

const String STREAM_STATUS = r'''
query StreamStatus($sessionId: String!) {
  streamStatus(sessionId: $sessionId) {
    id
    title
    progress
    bufferProgress
    downloadMbps
    seeders
    peers
    resumePosition
    status
    streamUrl
  }
}
''';

const String START_STREAM = r'''
mutation StartStream($magnet: String!, $title: String!, $titleId: UUID, $resume: Boolean, $seeders: Int, $peers: Int, $season: Int, $episode: Int) {
  startStream(magnet: $magnet, title: $title, titleId: $titleId, resume: $resume, seeders: $seeders, peers: $peers, season: $season, episode: $episode) {
    id
    title
    progress
    bufferProgress
    downloadMbps
    seeders
    peers
    resumePosition
    status
    streamUrl
  }
}
''';

const String STREAM_RESUME = r'''
mutation StreamResume($sessionId: String!, $position: Int!, $titleId: UUID, $title: String, $magnet: String) {
  streamResume(sessionId: $sessionId, position: $position, titleId: $titleId, title: $title, magnet: $magnet)
}
''';

const String STOP_STREAM = r'''
mutation StopStream($sessionId: String!) {
  stopStream(sessionId: $sessionId)
}
''';

const String TEST_JACKETT = r'''
mutation TestJackett {
  testJackett {
    success
    message
  }
}
''';

const String START_JACKETT_CATALOG = r'''
mutation StartJackettCatalog {
  startJackettCatalog {
    success
    message
  }
}
''';

const String FETCH_SUBTITLES = r'''
mutation FetchSubtitles($titleId: UUID!, $language: String, $season: Int, $episode: Int, $fileId: UUID) {
  fetchSubtitles(titleId: $titleId, language: $language, season: $season, episode: $episode, fileId: $fileId) {
    id
    language
    label
    format
    content
  }
}
''';
