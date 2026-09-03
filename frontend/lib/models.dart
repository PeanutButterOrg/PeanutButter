class TitleItem {
  const TitleItem({
    required this.id,
    required this.kind,
    required this.title,
    this.originalTitle,
    this.synopsis,
    this.description,
    this.year,
    this.runtimeMinutes,
    this.posterUrl,
    this.backdropUrl,
    this.logoUrl,
    this.thumbUrl,
    this.ratings,
    this.genres = const [],
    this.trailers = const [],
    this.fileReferences = const [],
    this.seasons = const [],
    this.trailerYoutubeKey,
    this.availablePeers = 0,
    this.bestQuality,
    this.people = const [],
    this.userState,
    this.contentRating,
    this.videoCodec,
    this.audioCodec,
    this.container,
  });

  final String id;
  final String kind;
  final String title;
  final String? originalTitle;
  final String? synopsis;
  final String? description;
  final int? year;
  final int? runtimeMinutes;
  final String? posterUrl;
  final String? backdropUrl;
  final String? logoUrl;
  final String? thumbUrl;
  final Ratings? ratings;
  final List<String> genres;
  final List<Trailer> trailers;
  final List<FileReference> fileReferences;
  final List<Season> seasons;
  final String? trailerYoutubeKey;
  final int availablePeers;
  final String? bestQuality;
  final List<Person> people;
  final UserState? userState;
  final String? contentRating;
  final String? videoCodec;
  final String? audioCodec;
  final String? container;

  int? get rtScore => ratings?.rtScore;

  List<Trailer> get playableTrailers {
    final list = trailers.where((t) => !t.isMobileSize).toList();
    list.sort((a, b) => (b.size ?? 0).compareTo(a.size ?? 0));
    return list;
  }

  /// Best 0–10 score from whatever platform we actually have.
  double? get displayRating {
    final picked = displayScore;
    if (picked == null) return null;
    return picked.outOfTen;
  }

  DisplayScore? get displayScore {
    final r = ratings;
    if (r == null) return null;
    final rt = r.rtScore;
    if (rt != null && rt > 0) {
      return DisplayScore(source: 'RT', label: '$rt%', outOfTen: rt / 10.0, rtScore: rt);
    }
    final imdb = r.imdbRating;
    if (imdb != null && imdb > 0) {
      return DisplayScore(source: 'IMDb', label: imdb.toStringAsFixed(1), outOfTen: imdb);
    }
    final anilist = r.anilistScore;
    if (anilist != null && anilist > 0) {
      final percent = anilist <= 10 ? (anilist * 10).round() : anilist.round();
      return DisplayScore(
        source: 'AniList',
        label: '$percent%',
        outOfTen: anilist > 10 ? anilist / 10.0 : anilist,
      );
    }
    final tmdb = r.tmdbVoteAverage;
    if (tmdb != null && tmdb > 0) {
      return DisplayScore(
        source: kind == 'SERIES' ? 'TVMaze' : 'TMDB',
        label: tmdb.toStringAsFixed(1),
        outOfTen: tmdb,
      );
    }
    return null;
  }

  List<DisplayScore> get allScores {
    final r = ratings;
    if (r == null) return const [];
    final out = <DisplayScore>[];
    final seen = <String>{};
    void add(DisplayScore? score) {
      if (score == null || !seen.add(score.source)) return;
      out.add(score);
    }
    add(displayScore);
    if (r.rtScore != null && r.rtScore! > 0) {
      add(DisplayScore(source: 'RT', label: '${r.rtScore}%', outOfTen: r.rtScore! / 10.0, rtScore: r.rtScore));
    }
    if (r.imdbRating != null && r.imdbRating! > 0) {
      add(DisplayScore(source: 'IMDb', label: r.imdbRating!.toStringAsFixed(1), outOfTen: r.imdbRating!));
    }
    if (r.tmdbVoteAverage != null && r.tmdbVoteAverage! > 0) {
      add(DisplayScore(
        source: kind == 'SERIES' ? 'TVMaze' : 'TMDB',
        label: r.tmdbVoteAverage!.toStringAsFixed(1),
        outOfTen: r.tmdbVoteAverage!,
      ));
    }
    if (r.anilistScore != null && r.anilistScore! > 0) {
      final percent = r.anilistScore! <= 10 ? (r.anilistScore! * 10).round() : r.anilistScore!.round();
      add(DisplayScore(
        source: 'AniList',
        label: '$percent%',
        outOfTen: r.anilistScore! > 10 ? r.anilistScore! / 10.0 : r.anilistScore!,
      ));
    }
    return out;
  }

  List<String> get mediaLabels {
    final labels = <String>[];
    final rating = contentRating?.trim();
    if (rating != null && rating.isNotEmpty) labels.add(rating);
    final quality = bestQuality?.trim();
    if (quality != null && quality.isNotEmpty) labels.add(quality);
    final video = prettyVideoCodec(videoCodec);
    if (video != null) labels.add(video);
    final audio = prettyAudioCodec(audioCodec);
    if (audio != null) labels.add(audio);
    final box = prettyContainer(container);
    if (box != null) labels.add(box);
    return labels;
  }

  factory TitleItem.fromJson(Map<String, dynamic> json) {
    return TitleItem(
      id: json['id'] as String,
      kind: json['kind'] as String? ?? 'MOVIE',
      title: json['title'] as String? ?? '',
      originalTitle: json['originalTitle'] as String?,
      synopsis: json['synopsis'] as String?,
      description: json['description'] as String?,
      year: json['year'] as int?,
      runtimeMinutes: json['runtimeMinutes'] as int?,
      posterUrl: json['posterUrl'] as String?,
      backdropUrl: json['backdropUrl'] as String?,
      logoUrl: json['logoUrl'] as String?,
      thumbUrl: json['thumbUrl'] as String?,
      ratings: json['ratings'] == null
          ? null
          : Ratings.fromJson(json['ratings'] as Map<String, dynamic>),
      genres: ((json['genres'] as List?) ?? const [])
          .map((e) => e.toString())
          .toList(),
      trailers: ((json['trailers'] as List?) ?? const [])
          .map((e) => Trailer.fromJson(e as Map<String, dynamic>))
          .toList(),
      fileReferences: ((json['fileReferences'] as List?) ?? const [])
          .map((e) => FileReference.fromJson(e as Map<String, dynamic>))
          .toList(),
      seasons: ((json['seasons'] as List?) ?? const [])
          .map((e) => Season.fromJson(e as Map<String, dynamic>))
          .toList(),
      trailerYoutubeKey: json['trailerYoutubeKey'] as String?,
      availablePeers: json['availablePeers'] as int? ?? 0,
      bestQuality: json['bestQuality'] as String?,
      people: ((json['people'] as List?) ?? const [])
          .map((e) => Person.fromJson(e as Map<String, dynamic>))
          .toList(),
      userState: json['userState'] == null
          ? null
          : UserState.fromJson(json['userState'] as Map<String, dynamic>),
      contentRating: json['contentRating'] as String?,
      videoCodec: json['videoCodec'] as String?,
      audioCodec: json['audioCodec'] as String?,
      container: json['container'] as String?,
    );
  }
}

class Ratings {
  const Ratings({
    this.tmdbVoteAverage,
    this.tmdbVoteCount,
    this.imdbRating,
    this.imdbVotes,
    this.anilistScore,
    this.anilistPopularity,
    this.rtScore,
  });

  final double? tmdbVoteAverage;
  final int? tmdbVoteCount;
  final double? imdbRating;
  final int? imdbVotes;
  final double? anilistScore;
  final int? anilistPopularity;
  final int? rtScore;

  double? get anilistScore10 =>
      anilistScore == null ? null : (anilistScore! > 10 ? anilistScore! / 10.0 : anilistScore);

  factory Ratings.fromJson(Map<String, dynamic> json) {
    return Ratings(
      tmdbVoteAverage: (json['tmdbVoteAverage'] as num?)?.toDouble(),
      tmdbVoteCount: json['tmdbVoteCount'] as int?,
      imdbRating: (json['imdbRating'] as num?)?.toDouble(),
      imdbVotes: json['imdbVotes'] as int?,
      anilistScore: (json['anilistScore'] as num?)?.toDouble(),
      anilistPopularity: json['anilistPopularity'] as int?,
      rtScore: json['rtScore'] as int?,
    );
  }
}

class DisplayScore {
  const DisplayScore({
    required this.source,
    required this.label,
    required this.outOfTen,
    this.rtScore,
  });

  final String source;
  final String label;
  final double outOfTen;
  final int? rtScore;
}

class Trailer {
  const Trailer({
    required this.id,
    required this.name,
    required this.youtubeKey,
    required this.site,
    this.size,
  });

  final String id;
  final String name;
  final String youtubeKey;
  final String site;
  final int? size;

  bool get isMobileSize {
    if (name.toLowerCase().contains('mobile')) return true;
    final s = size;
    return s != null && s > 0 && s < 720;
  }

  String get thumbnailUrl =>
      'https://img.youtube.com/vi/$youtubeKey/hqdefault.jpg';

  String get watchUrl => 'https://www.youtube.com/watch?v=$youtubeKey';

  factory Trailer.fromJson(Map<String, dynamic> json) {
    return Trailer(
      id: json['id'] as String,
      name: json['name'] as String? ?? 'Trailer',
      youtubeKey: json['youtubeKey'] as String? ?? '',
      site: json['site'] as String? ?? 'YouTube',
      size: json['size'] as int?,
    );
  }
}

class FileReference {
  const FileReference({
    required this.id,
    required this.kind,
    required this.playbackUrl,
    this.quality,
    this.container,
    this.codec,
    this.audioCodec,
    this.sizeBytes,
    this.availablePeers = 0,
    this.episodeId,
  });

  final String id;
  final String kind;
  final String playbackUrl;
  final String? quality;
  final String? container;
  final String? codec;
  final String? audioCodec;
  final int? sizeBytes;
  final int availablePeers;
  final String? episodeId;

  factory FileReference.fromJson(Map<String, dynamic> json) {
    return FileReference(
      id: json['id'] as String,
      kind: json['kind'] as String? ?? 'local',
      playbackUrl: json['playbackUrl'] as String? ?? '',
      quality: json['quality'] as String?,
      container: json['container'] as String?,
      codec: json['codec'] as String?,
      audioCodec: json['audioCodec'] as String?,
      sizeBytes: json['sizeBytes'] as int?,
      availablePeers: json['availablePeers'] as int? ?? 0,
      episodeId: json['episodeId'] as String?,
    );
  }
}

class StreamSource {
  const StreamSource({
    required this.id,
    required this.title,
    required this.magnet,
    required this.seeders,
    required this.peers,
    required this.rating,
    required this.health,
    required this.size,
    required this.tracker,
    required this.indexer,
    this.language = '',
  });

  final String id;
  final String title;
  final String magnet;
  final int seeders;
  final int peers;
  final int rating;
  final String health;
  final String size;
  final String tracker;
  final String indexer;
  final String language;

  factory StreamSource.fromJson(Map<String, dynamic> json) {
    return StreamSource(
      id: json['id'] as String? ?? '',
      title: json['title'] as String? ?? '',
      magnet: json['magnet'] as String? ?? '',
      seeders: json['seeders'] as int? ?? 0,
      peers: json['peers'] as int? ?? 0,
      rating: json['rating'] as int? ?? 1,
      health: json['health'] as String? ?? 'dead',
      size: json['size'] as String? ?? '',
      tracker: json['tracker'] as String? ?? '',
      indexer: json['indexer'] as String? ?? '',
      language: json['language'] as String? ?? '',
    );
  }
}

class StreamSession {
  const StreamSession({
    required this.id,
    required this.title,
    required this.progress,
    this.bufferProgress = 0,
    this.downloadMbps = 0,
    required this.seeders,
    required this.peers,
    required this.resumePosition,
    required this.status,
    required this.streamUrl,
  });

  final String id;
  final String title;
  final double progress;
  final double bufferProgress;
  final double downloadMbps;
  final int seeders;
  final int peers;
  final int resumePosition;
  final String status;
  final String streamUrl;

  bool get isReady => status == 'ready' && streamUrl.isNotEmpty;
  bool get isError => status.startsWith('error');

  factory StreamSession.fromJson(Map<String, dynamic> json) {
    return StreamSession(
      id: json['id'] as String? ?? '',
      title: json['title'] as String? ?? '',
      progress: (json['progress'] as num?)?.toDouble() ?? 0,
      bufferProgress: (json['bufferProgress'] as num?)?.toDouble() ?? 0,
      downloadMbps: (json['downloadMbps'] as num?)?.toDouble() ?? 0,
      seeders: json['seeders'] as int? ?? 0,
      peers: json['peers'] as int? ?? 0,
      resumePosition: json['resumePosition'] as int? ?? 0,
      status: json['status'] as String? ?? '',
      streamUrl: json['streamUrl'] as String? ?? '',
    );
  }
}

class Person {
  const Person({
    required this.id,
    required this.name,
    required this.department,
    this.character,
    this.job,
    this.profileUrl,
  });

  final String id;
  final String name;
  final String department;
  final String? character;
  final String? job;
  final String? profileUrl;

  factory Person.fromJson(Map<String, dynamic> json) {
    return Person(
      id: json['id'] as String? ?? json['name'] as String? ?? '',
      name: json['name'] as String? ?? '',
      department: json['department'] as String? ?? 'cast',
      character: json['character'] as String?,
      job: json['job'] as String?,
      profileUrl: json['profileUrl'] as String?,
    );
  }
}

class UserState {
  const UserState({
    this.favorite = false,
    this.watched = false,
    this.positionMs = 0,
    this.durationMs,
    this.episodeId,
    this.fileId,
  });

  final bool favorite;
  final bool watched;
  final int positionMs;
  final int? durationMs;
  final String? episodeId;
  final String? fileId;

  factory UserState.fromJson(Map<String, dynamic> json) {
    return UserState(
      favorite: json['favorite'] as bool? ?? false,
      watched: json['watched'] as bool? ?? false,
      positionMs: json['positionMs'] as int? ?? 0,
      durationMs: json['durationMs'] as int?,
      episodeId: json['episodeId'] as String?,
      fileId: json['fileId'] as String?,
    );
  }
}

class Season {
  const Season({
    required this.id,
    required this.seasonNumber,
    this.name,
    this.overview,
    this.posterPath,
    this.airDate,
    this.episodeCount,
    this.episodes = const [],
  });

  final String id;
  final int seasonNumber;
  final String? name;
  final String? overview;
  final String? posterPath;
  final String? airDate;
  final int? episodeCount;
  final List<Episode> episodes;

  factory Season.fromJson(Map<String, dynamic> json) {
    return Season(
      id: json['id'] as String,
      seasonNumber: json['seasonNumber'] as int? ?? 0,
      name: json['name'] as String?,
      overview: json['overview'] as String?,
      posterPath: json['posterPath'] as String?,
      airDate: json['airDate'] as String?,
      episodeCount: json['episodeCount'] as int?,
      episodes: ((json['episodes'] as List?) ?? const [])
          .map((e) => Episode.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}

class Episode {
  const Episode({
    required this.id,
    required this.episodeNumber,
    this.name,
    this.overview,
    this.stillPath,
    this.airDate,
    this.runtime,
  });

  final String id;
  final int episodeNumber;
  final String? name;
  final String? overview;
  final String? stillPath;
  final String? airDate;
  final int? runtime;

  factory Episode.fromJson(Map<String, dynamic> json) {
    return Episode(
      id: json['id'] as String,
      episodeNumber: json['episodeNumber'] as int? ?? 0,
      name: json['name'] as String?,
      overview: json['overview'] as String?,
      stillPath: json['stillPath'] as String?,
      airDate: json['airDate'] as String?,
      runtime: json['runtime'] as int?,
    );
  }
}

class CatalogPage {
  const CatalogPage({
    required this.items,
    required this.totalCount,
    required this.hasNextPage,
    required this.page,
  });

  final List<TitleItem> items;
  final int totalCount;
  final bool hasNextPage;
  final int page;
}

class ServerInfo {
  const ServerInfo({
    required this.version,
    required this.libraryPath,
    required this.syncing,
    required this.totalTitles,
    this.lastSyncAt,
    this.tmdbConfigured = false,
    this.omdbConfigured = false,
    this.anilistConfigured = false,
    this.jackettEnabled = false,
    this.jackettConfigured = false,
    this.jackettUrl,
    this.streamingResolution = '1080p',
    this.jackettCatalog = const JackettCatalogStatus(),
    this.opensubtitlesEnabled = false,
    this.opensubtitlesConfigured = false,
  });

  final String version;
  final String libraryPath;
  final bool syncing;
  final int totalTitles;
  final String? lastSyncAt;
  final bool tmdbConfigured;
  final bool omdbConfigured;
  final bool anilistConfigured;
  final bool jackettEnabled;
  final bool jackettConfigured;
  final String? jackettUrl;
  final String streamingResolution;
  final JackettCatalogStatus jackettCatalog;
  final bool opensubtitlesEnabled;
  final bool opensubtitlesConfigured;

  factory ServerInfo.fromJson(Map<String, dynamic> json) {
    final sync = json['syncStatus'] as Map<String, dynamic>? ?? const {};
    return ServerInfo(
      version: json['version'] as String? ?? '',
      libraryPath: json['libraryPath'] as String? ?? '',
      syncing: sync['syncing'] as bool? ?? false,
      totalTitles: sync['totalTitles'] as int? ?? 0,
      lastSyncAt: sync['lastSyncAt'] as String?,
      tmdbConfigured: json['tmdbConfigured'] as bool? ?? false,
      omdbConfigured: json['omdbConfigured'] as bool? ?? false,
      anilistConfigured: json['anilistConfigured'] as bool? ?? false,
      jackettEnabled: json['jackettEnabled'] as bool? ?? false,
      jackettConfigured: json['jackettConfigured'] as bool? ?? false,
      jackettUrl: json['jackettUrl'] as String?,
      streamingResolution: json['streamingResolution'] as String? ?? '1080p',
      jackettCatalog: JackettCatalogStatus.fromJson(
        json['jackettCatalog'] as Map<String, dynamic>? ?? const {},
      ),
      opensubtitlesEnabled: json['opensubtitlesEnabled'] as bool? ?? false,
      opensubtitlesConfigured: json['opensubtitlesConfigured'] as bool? ?? false,
    );
  }
}

class JackettCatalogStatus {
  const JackettCatalogStatus({
    this.ready = true,
    this.syncing = false,
    this.done = 0,
    this.total = 0,
    this.lastError,
  });

  final bool ready;
  final bool syncing;
  final int done;
  final int total;
  final String? lastError;

  factory JackettCatalogStatus.fromJson(Map<String, dynamic> json) {
    return JackettCatalogStatus(
      ready: json['ready'] as bool? ?? true,
      syncing: json['syncing'] as bool? ?? false,
      done: json['done'] as int? ?? 0,
      total: json['total'] as int? ?? 0,
      lastError: json['lastError'] as String?,
    );
  }
}

class CatalogFilter {
  const CatalogFilter({
    this.kind,
    this.genre,
    this.yearMin = 1900,
    this.yearMax,
    this.ratingMin = 0,
    this.sort = 'POPULARITY',
    this.dir = 'DESC',
    this.railLocked = false,
  });

  final String? kind;
  final String? genre;
  final int yearMin;
  final int? yearMax;
  final double ratingMin;
  final String sort;
  final String dir;
  final bool railLocked;

  /// Exact calendar year when min and max are the same; otherwise null (any year).
  int? get selectedYear {
    if (yearMax != null && yearMin == yearMax && yearMin >= 1900) return yearMin;
    return null;
  }

  bool matches(TitleItem item) {
    final year = selectedYear;
    if (year != null && item.year != year) return false;
    if (year == null) {
      if (yearMin > 1900 && (item.year ?? 0) < yearMin) return false;
      if (yearMax != null && (item.year ?? 9999) > yearMax!) return false;
    }
    if (ratingMin > 0 && (item.displayRating ?? 0) < ratingMin) return false;
    if (genre != null && genre!.isNotEmpty && !item.genres.contains(genre)) return false;
    return true;
  }

  CatalogFilter copyWith({
    String? kind,
    String? genre,
    int? yearMin,
    int? yearMax,
    double? ratingMin,
    String? sort,
    String? dir,
    bool? railLocked,
    bool clearKind = false,
    bool clearGenre = false,
    bool clearYearMax = false,
  }) {
    return CatalogFilter(
      kind: clearKind ? null : (kind ?? this.kind),
      genre: clearGenre ? null : (genre ?? this.genre),
      yearMin: yearMin ?? this.yearMin,
      yearMax: clearYearMax ? null : (yearMax ?? this.yearMax),
      ratingMin: ratingMin ?? this.ratingMin,
      sort: sort ?? this.sort,
      dir: dir ?? this.dir,
      railLocked: railLocked ?? this.railLocked,
    );
  }

  Map<String, dynamic> toVariables({required int page, int perPage = 24}) {
    return {
      'kind': kind,
      'genre': genre,
      'yearMin': yearMin == 1900 ? null : yearMin,
      'yearMax': yearMax,
      'ratingMin': ratingMin <= 0 ? null : ratingMin,
      'sort': sort,
      'dir': dir,
      'page': page,
      'perPage': perPage,
    };
  }
}

String? prettyVideoCodec(String? raw) {
  final key = _codecKey(raw);
  if (key == null) return null;
  const names = {
    'h264': 'H.264',
    'avc': 'H.264',
    'avc1': 'H.264',
    'x264': 'H.264',
    'h265': 'H.265',
    'hevc': 'H.265',
    'hev1': 'H.265',
    'x265': 'H.265',
    'av1': 'AV1',
    'av01': 'AV1',
    'vp9': 'VP9',
    'vp8': 'VP8',
    'mpeg2video': 'MPEG-2',
    'mpeg4': 'MPEG-4',
  };
  return names[key] ?? raw!.toUpperCase();
}

String? prettyAudioCodec(String? raw) {
  final key = _codecKey(raw);
  if (key == null) return null;
  const names = {
    'aac': 'AAC',
    'mp4a': 'AAC',
    'ac3': 'Dolby Digital',
    'eac3': 'Dolby Digital Plus',
    'truehd': 'TrueHD',
    'atmos': 'Atmos',
    'dts': 'DTS',
    'dtshd': 'DTS-HD',
    'dca': 'DTS',
    'flac': 'FLAC',
    'opus': 'Opus',
    'mp3': 'MP3',
    'pcms16le': 'PCM',
  };
  return names[key] ?? raw!.toUpperCase();
}

String? prettyContainer(String? raw) {
  final value = raw?.trim();
  if (value == null || value.isEmpty) return null;
  return value.toUpperCase();
}

String? _codecKey(String? raw) {
  if (raw == null) return null;
  final key = raw.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  return key.isEmpty ? null : key;
}
