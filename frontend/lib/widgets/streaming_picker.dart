import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:graphql_flutter/graphql_flutter.dart';

import '../content_languages.dart';
import '../design/tokens.g.dart';
import '../graphql/client.dart';
import '../graphql/queries.dart';
import '../friendly_error.dart';
import '../local_torrent.dart';
import '../models.dart';
import '../providers/settings.dart';
import '../release_tags.dart';
import '../stream_resume_policy.dart';
import '../tv.dart';
import 'cached_art.dart';
import 'tv_chrome.dart';

List<StreamSource> sourcesMatchingEpisode(
  List<StreamSource> sources, {
  int? season,
  int? episode,
}) {
  if (season == null || episode == null || sources.isEmpty) return sources;
  final tag = 's${season.toString().padLeft(2, '0')}e${episode.toString().padLeft(2, '0')}';
  final alt = '${season}x${episode.toString().padLeft(2, '0')}';
  final seasonTok = 's${season.toString().padLeft(2, '0')}';
  final seasonLoose = 's$season';
  final seasonWord = 'season$season';

  bool hasOtherEpisode(String n) {
    final ep = RegExp(r'(?:^|[^a-z0-9])(?:s(\d{1,2})e(\d{1,3})|(\d{1,2})x(\d{1,3}))(?:[^0-9]|$)');
    for (final m in ep.allMatches(n)) {
      final s = int.tryParse(m.group(1) ?? m.group(3) ?? '') ?? 0;
      final e = int.tryParse(m.group(2) ?? m.group(4) ?? '') ?? 0;
      if (s == season && e != episode) return true;
      if (s != 0 && s != season) return true;
    }
    return false;
  }

  bool isSeasonPack(String n) {
    final packish = n.contains('complete') ||
        n.contains('pack') ||
        n.contains('season') ||
        n.contains(seasonTok) ||
        RegExp('(?:^|[^a-z0-9])$seasonLoose(?!e\\d)').hasMatch(n) ||
        n.contains(seasonWord);
    if (!packish) return false;
    return !RegExp(r'(?:^|[^a-z0-9])s\d{1,2}e\d{1,3}(?:[^0-9]|$)').hasMatch(n) ||
        RegExp('(?:^|[^a-z0-9])(?:$seasonTok|$seasonLoose)(?!e\\d)').hasMatch(n);
  }

  final hits = sources.where((s) {
    // Direct links come from add-ons that looked the episode up by its id;
    // their names often don't carry an SxxExx tag.
    if (s.isHttp) return true;
    final n = s.title.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');
    if (n.contains(tag) || n.contains(alt)) return true;
    if (hasOtherEpisode(n)) return false;
    return isSeasonPack(n);
  }).toList();
  // Never fall back to unrelated torrents for a specific episode.
  return hits;
}

class StreamStart {
  const StreamStart({
    required this.session,
    required this.magnet,
    this.localTorrent = false,
    this.fileIndex,
    this.directStream = false,
    this.httpHeaders = const {},
  });

  final StreamSession session;
  /// The magnet, or for [directStream] the link (saved as the Resume bookmark).
  final String magnet;
  final bool localTorrent;
  final int? fileIndex;
  /// A direct link from a Stremio add-on: played as is from
  /// `session.streamUrl` with [httpHeaders], no torrent and no server session.
  final bool directStream;
  final Map<String, String> httpHeaders;

  /// Player route extras that say how to play this (torrent or direct link).
  /// Spread after the caller's own keys.
  Map<String, dynamic> get routeExtras => {
        'isStream': !directStream,
        'directStream': directStream,
        'httpHeaders': httpHeaders,
      };
}

/// This device's quality setting; the server ranks results against it.
String? _deviceQuality(BuildContext context) {
  try {
    return ProviderScope.containerOf(context, listen: false).read(settingsProvider).defaultQuality;
  } catch (_) {
    return null;
  }
}

bool _isHttpLink(String s) {
  final l = s.trim().toLowerCase();
  return l.startsWith('http://') || l.startsWith('https://');
}

/// Start a direct link (an add-on's HTTP stream, or a saved one on Resume).
StreamStart directStreamStart({
  required String url,
  required String title,
  Map<String, String> headers = const {},
}) {
  return StreamStart(
    session: StreamSession(
      id: 'direct-${DateTime.now().millisecondsSinceEpoch}',
      title: title,
      progress: 0,
      bufferProgress: 0,
      downloadMbps: 0,
      seeders: 0,
      peers: 0,
      resumePosition: 0,
      status: 'ready',
      streamUrl: url,
    ),
    magnet: url,
    directStream: true,
    httpHeaders: headers,
  );
}

Future<List<StreamSource>> searchStreamingSources({
  required GraphQLClient client,
  required String title,
  required String kind,
  String? titleId,
  int? season,
  int? episode,
  String? language,
  bool live = false,
  String? resolution,
}) async {
  final result = await client.query(
    QueryOptions(
      document: gql(STREAMING_SEARCH),
      fetchPolicy: FetchPolicy.networkOnly,
      variables: {
        'query': title,
        'kind': kind,
        'season': season,
        'episode': episode,
        'titleId': titleId,
        'language': language,
        'live': live,
        if (resolution != null && resolution.isNotEmpty) 'resolution': resolution,
      },
    ),
  );
  if (result.hasException) {
    throw graphqlMessage(result);
  }
  final raw = (result.data?['streamingSearch'] as List?) ?? const [];
  return raw.whereType<Map<String, dynamic>>().map(StreamSource.fromJson).toList();
}

/// One preferred-language bucket for the Choose a stream dialog.
class StreamSourceGroup {
  const StreamSourceGroup({
    required this.code,
    required this.label,
    required this.sources,
  });

  final String code;
  final String label;
  final List<StreamSource> sources;
}

/// Search each preferred language (in parallel), merge, dedupe and order the
/// lot by the server's score: one ranked list, the same order the TV app
/// shows. The server merges and ranks every source (Jackett and the add-ons);
/// this only joins its per-language answers.
Future<List<StreamSourceGroup>> searchStreamingSourcesGrouped({
  required GraphQLClient client,
  required String title,
  required String kind,
  String? titleId,
  int? season,
  int? episode,
  List<String>? preferredLanguages,
  bool live = false,
  String? resolution,
}) async {
  final langs = preferredLanguageCodes(preferredLanguages ?? const []);
  final results = await Future.wait([
    for (final lang in (langs.isEmpty ? <String?>[null] : langs))
      searchStreamingSources(
        client: client,
        title: title,
        kind: kind,
        titleId: titleId,
        season: season,
        episode: episode,
        language: lang,
        live: live,
        resolution: resolution,
      ).then<List<StreamSource>?>((v) => v, onError: (Object e) => langs.length > 1 ? null : throw e),
  ]);
  if (results.every((r) => r == null)) {
    // Every language failed: surface the error of a plain search.
    throw 'Couldn’t reach the stream sources. Try again in a moment.';
  }

  final seen = <String>{};
  final merged = <StreamSource>[];
  for (final batch in results) {
    for (final src in sourcesMatchingEpisode(batch ?? const [], season: season, episode: episode)) {
      final key = src.key;
      if (key.isEmpty || !seen.add(key)) continue;
      merged.add(src);
    }
  }
  final ranked = rankByServerScore(merged);
  if (ranked.isEmpty) return const [];
  return [
    StreamSourceGroup(
      code: 'all',
      label: 'Streams',
      sources: ranked.length > 24 ? ranked.sublist(0, 24) : ranked,
    ),
  ];
}

List<StreamSource> flattenSourceGroups(List<StreamSourceGroup> groups) {
  return [for (final g in groups) ...g.sources];
}


/// On Android TV, [showDialog] uses a transparent route so the heavy catalog
/// underneath keeps painting every frame and ANRs. Opaque fullscreen routes
/// skip painting routes below.
Future<T?> _showPickerOverlay<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
}) {
  if (!isAndroidTv) {
    return showDialog<T>(
      context: context,
      barrierDismissible: barrierDismissible,
      builder: builder,
    );
  }
  return Navigator.of(context, rootNavigator: true).push<T>(
    PageRouteBuilder<T>(
      opaque: true,
      barrierDismissible: barrierDismissible,
      barrierColor: Colors.black,
      transitionDuration: Duration.zero,
      reverseTransitionDuration: Duration.zero,
      pageBuilder: (ctx, animation, secondaryAnimation) {
        return Material(
          color: Theme.of(ctx).scaffoldBackgroundColor,
          child: SafeArea(
            child: Center(child: builder(ctx)),
          ),
        );
      },
    ),
  );
}

Future<StreamBookmark?> fetchStreamBookmark({
  required GraphQLClient client,
  required String titleId,
  int? season,
  int? episode,
}) async {
  try {
    final result = await client.query(
      QueryOptions(
        document: gql(STREAM_BOOKMARK),
        fetchPolicy: FetchPolicy.networkOnly,
        variables: {
          'titleId': titleId,
          'season': season,
          'episode': episode,
        },
      ),
    );
    if (result.hasException) return null;
    final json = result.data?['streamBookmark'] as Map<String, dynamic>?;
    if (json == null) return null;
    final bookmark = StreamBookmark.fromJson(json);
    return bookmark.hasMagnet ? bookmark : null;
  } catch (_) {
    return null;
  }
}

/// Start playback on this device (libtorrent). Server never downloads pieces.
Future<StreamStart?> startStreamDirect({
  required GraphQLClient client,
  required String magnet,
  required String title,
  String? titleId,
  bool resumePlayback = true,
  int seeders = 0,
  int peers = 0,
  int? season,
  int? episode,
  int? fileIndex,
  String? stopPreviousSessionId,
}) async {
  if (_isHttpLink(magnet)) {
    return directStreamStart(url: magnet.trim(), title: title);
  }
  return prepareLocalStreamStart(
    magnet: magnet,
    title: title,
    fileIndex: fileIndex,
  );
}

/// Synthetic session the player uses with [LocalTorrentEngine].
Future<StreamStart> prepareLocalStreamStart({
  required String magnet,
  required String title,
  int? fileIndex,
}) async {
  await LocalTorrentEngine.instance.ensureInit();
  if (!LocalTorrentEngine.instance.supported) {
    throw 'On-device torrent streaming isn’t available on this device.';
  }
  final id = 'local-${DateTime.now().millisecondsSinceEpoch}';
  return StreamStart(
    session: StreamSession(
      id: id,
      title: title,
      progress: 0,
      bufferProgress: 0,
      downloadMbps: 0,
      seeders: 0,
      peers: 0,
      resumePosition: 0,
      status: 'starting',
      streamUrl: '',
    ),
    magnet: magnet,
    localTorrent: true,
    fileIndex: fileIndex,
  );
}

/// Core entry: Resume reuses the saved magnet (no picker); new / from-beginning
/// opens the torrent list so the user picks a clean source.
Future<StreamStart?> beginStreaming({
  required BuildContext context,
  required GraphQLClient client,
  required String title,
  required String kind,
  String? titleId,
  String? posterUrl,
  int? season,
  int? episode,
  List<String>? preferredLanguages,
  /// True when the user tapped Resume (or episode mid-watch).
  bool preferResume = false,
  /// True when the user chose Play from beginning — always show the picker.
  bool fromBeginning = false,
  bool resumePlayback = true,
  String? stopPreviousSessionId,
  void Function(StreamStart started)? onReadyToPlay,
}) async {
  final tryResume = preferResume && !fromBeginning && titleId != null && titleId.isNotEmpty;
  StreamBookmark? bookmark;
  if (tryResume) {
    bookmark = await fetchStreamBookmark(
      client: client,
      titleId: titleId,
      season: season,
      episode: episode,
    );
  }

  final showPicker = shouldShowStreamPicker(
    fromBeginning: fromBeginning,
    preferResume: preferResume,
    hasSavedMagnet: bookmark?.hasMagnet == true,
  );

  if (!showPicker && bookmark != null && bookmark.hasMagnet) {
    if (!context.mounted) return null;
    final nav = Navigator.of(context, rootNavigator: true);
    // Brief dialog while the previous torrent restarts (no source list).
    // Must use AlertDialog/Material — a bare Column under showDialog flashes
    // the red "No Material widget" error + yellow overflow stripes on desktop.
    final loading = _showPickerOverlay<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const PopScope(
        canPop: false,
        child: _BusyDialog(message: 'Resuming previous stream…'),
      ),
    );
    try {
      await Future<void>.delayed(const Duration(milliseconds: 40));
      final started = await startStreamDirect(
        client: client,
        magnet: bookmark.magnet,
        title: title,
        titleId: titleId,
        resumePlayback: true,
        season: season,
        episode: episode,
        fileIndex: bookmark.fileIndex,
        stopPreviousSessionId: stopPreviousSessionId,
      );
      if (nav.canPop()) nav.pop();
      await loading;
      if (started != null) {
        onReadyToPlay?.call(started);
      }
      return started;
    } catch (e) {
      if (nav.canPop()) nav.pop();
      try {
        await loading;
      } catch (_) {}
      if (context.mounted) {
        await _alert(context, friendlyRequestError(e));
      }
      // Fall through to picker if the saved magnet failed.
    }
  }

  if (!context.mounted) return null;
  return showStreamingPicker(
    context: context,
    client: client,
    title: title,
    kind: kind,
    titleId: titleId,
    posterUrl: posterUrl,
    season: season,
    episode: episode,
    preferredLanguages: preferredLanguages,
    resumePlayback: fromBeginning ? false : resumePlayback,
    stopPreviousSessionId: stopPreviousSessionId,
    onReadyToPlay: onReadyToPlay,
  );
}

Future<StreamStart?> showStreamingPicker({
  required BuildContext context,
  required GraphQLClient client,
  required String title,
  required String kind,
  String? titleId,
  String? posterUrl,
  int? season,
  int? episode,
  List<String>? preferredLanguages,
  bool resumePlayback = true,
  /// Stop this session before starting the new torrent (Play Next).
  String? stopPreviousSessionId,
  /// Called on Android TV *before* the opaque picker pops so the caller can
  /// push the player route while the covering page is still up (avoids ANR).
  void Function(StreamStart started)? onReadyToPlay,
}) async {
  if (!context.mounted) return null;
  // Android TV: one opaque route for lookup → pick → start. Swapping transparent
  // dialogs was painting the detail/catalog underneath and ANRing on select.
  if (isAndroidTv) {
    return Navigator.of(context, rootNavigator: true).push<StreamStart>(
      PageRouteBuilder<StreamStart>(
        opaque: true,
        barrierDismissible: false,
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
        pageBuilder: (ctx, animation, secondaryAnimation) {
          return _TvStreamingPickerPage(
            client: client,
            title: title,
            kind: kind,
            titleId: titleId,
            posterUrl: posterUrl,
            season: season,
            episode: episode,
            preferredLanguages: preferredLanguages,
            resumePlayback: resumePlayback,
            stopPreviousSessionId: stopPreviousSessionId,
            onReadyToPlay: onReadyToPlay,
          );
        },
      ),
    );
  }
  return _showStreamingPickerDialogs(
    context: context,
    client: client,
    title: title,
    kind: kind,
    titleId: titleId,
    posterUrl: posterUrl,
    season: season,
    episode: episode,
    preferredLanguages: preferredLanguages,
    resumePlayback: resumePlayback,
    stopPreviousSessionId: stopPreviousSessionId,
  );
}

Future<StreamStart?> _showStreamingPickerDialogs({
  required BuildContext context,
  required GraphQLClient client,
  required String title,
  required String kind,
  String? titleId,
  String? posterUrl,
  int? season,
  int? episode,
  List<String>? preferredLanguages,
  bool resumePlayback = true,
  String? stopPreviousSessionId,
}) async {
  if (!context.mounted) return null;

  // Cancel must return immediately so episode/movie busy spinners clear;
  // in-flight GraphQL work is ignored when it eventually finishes.
  final searchCancel = Completer<void>();
  var searchDone = false;
  unawaited(
    _showPickerOverlay<void>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => _BusyDialog(
        message: 'Finding streams…',
        onCancel: () => Navigator.of(ctx).pop(),
      ),
    ).whenComplete(() {
      if (!searchDone && !searchCancel.isCompleted) {
        searchCancel.complete();
      }
    }),
  );

  late List<StreamSourceGroup> groups;
  try {
    final searchFuture = searchStreamingSourcesGrouped(
      resolution: _deviceQuality(context),
      client: client,
      title: title,
      kind: kind,
      titleId: titleId,
      season: season,
      episode: episode,
      preferredLanguages: preferredLanguages,
      live: false,
    );
    unawaited(searchFuture.then((_) {}, onError: (_) {}));
    final found = await Future.any<List<StreamSourceGroup>?>([
      searchFuture.then((v) => v),
      searchCancel.future.then((_) => null),
    ]);
    if (found == null || searchCancel.isCompleted) {
      return null;
    }
    groups = found;
    // Cache miss, or cache full of 0-seeder / dead rows while Jackett was
    // unreachable: force one live Jackett pass before giving up.
    final cacheLooksDead = groups.isNotEmpty &&
        !groups.any((g) => g.sources.any((s) => s.isHttp || s.seeders >= 2));
    if ((groups.isEmpty || cacheLooksDead) && !searchCancel.isCompleted) {
      if (!context.mounted) return null;
      try {
        final liveGroups = await searchStreamingSourcesGrouped(
          resolution: _deviceQuality(context),
          client: client,
          title: title,
          kind: kind,
          titleId: titleId,
          season: season,
          episode: episode,
          preferredLanguages: preferredLanguages,
          live: true,
        );
        if (!searchCancel.isCompleted &&
            (liveGroups.isNotEmpty || groups.isEmpty)) {
          groups = liveGroups;
        }
      } catch (_) {
        // Keep weak cache only if live Jackett threw; empty stays empty.
      }
    }
  } catch (e) {
    if (searchCancel.isCompleted) return null;
    searchDone = true;
    if (context.mounted) {
      final nav = Navigator.of(context, rootNavigator: true);
      if (nav.canPop()) nav.pop();
      await _alert(context, friendlyRequestError(e));
    }
    return null;
  }
  if (searchCancel.isCompleted) return null;
  searchDone = true;
  if (context.mounted) {
    final nav = Navigator.of(context, rootNavigator: true);
    if (nav.canPop()) nav.pop();
  }
  await Future<void>.delayed(Duration.zero);
  if (!context.mounted) return null;
  if (groups.isEmpty) {
    await _alert(
      context,
      'No healthy sources found. Jackett may be down or only returning dead/cached torrents — check Jackett on the server console, then tap Refresh.',
    );
    return null;
  }

  final picked = await _showPickerOverlay<StreamSource>(
    context: context,
    builder: (ctx) => _ResultsDialog(
      groups: groups,
      title: title,
      subtitle: _pickerSubtitle(kind, season, episode),
      posterUrl: posterUrl,
      onRefresh: () => searchStreamingSourcesGrouped(
        resolution: _deviceQuality(context),
        client: client,
        title: title,
        kind: kind,
        titleId: titleId,
        season: season,
        episode: episode,
        preferredLanguages: preferredLanguages,
        live: true,
      ),
    ),
  );
  if (picked == null || !context.mounted) return null;
  if (picked.isHttp) {
    return directStreamStart(url: picked.url, title: title, headers: picked.headers);
  }
  if (picked.magnet.trim().isEmpty) {
    await _alert(context, 'That result has no torrent link. Try another result.');
    return null;
  }

  // Only list files for season packs / multi-episode dumps. Single-episode
  // magnets go straight to startStream — listing was fetching metadata twice
  // and made "Reading torrent files…" feel stuck.
  int? fileIndex;
  final needsFilePick = _looksLikeSeasonPack(picked.title);
  if (needsFilePick) {
    final filesCancel = Completer<void>();
    var filesDone = false;
    unawaited(
      _showPickerOverlay<void>(
        context: context,
        barrierDismissible: true,
        builder: (ctx) => _BusyDialog(
          onCancel: () => Navigator.of(ctx).pop(),
        ),
      ).whenComplete(() {
        if (!filesDone && !filesCancel.isCompleted) {
          filesCancel.complete();
        }
      }),
    );
    try {
      final listedFuture = client.query(
        QueryOptions(
          document: gql(TORRENT_FILES),
          fetchPolicy: FetchPolicy.networkOnly,
          queryRequestTimeout: const Duration(seconds: 25),
          variables: {
            'magnet': picked.magnet,
            'season': season,
            'episode': episode,
          },
        ),
      );
      unawaited(listedFuture.then((_) {}, onError: (_) {}));
      final listed = await Future.any<QueryResult?>([
        listedFuture.then((v) => v),
        filesCancel.future.then((_) => null),
        Future<QueryResult?>.delayed(const Duration(seconds: 20), () => null),
      ]);
      if (filesCancel.isCompleted) return null;
      filesDone = true;
      if (context.mounted) {
        final nav = Navigator.of(context, rootNavigator: true);
        if (nav.canPop()) nav.pop();
      }
      if (listed == null || listed.hasException) {
        fileIndex = null;
      } else {
        final files = ((listed.data?['torrentFiles'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(TorrentFileOption.fromJson)
            .toList();
        final matches = files.where((f) => f.recommended).toList();
        if (files.isEmpty) {
          fileIndex = null;
        } else if (files.length == 1) {
          fileIndex = files.first.index;
        } else if (matches.length == 1) {
          // The pack names this episode exactly: play it, no file list.
          fileIndex = matches.first.index;
        } else {
          if (!context.mounted) return null;
          files.sort((a, b) {
            if (a.recommended != b.recommended) return a.recommended ? -1 : 1;
            return b.sizeBytes.compareTo(a.sizeBytes);
          });
          final chosen = await _showPickerOverlay<TorrentFileOption>(
            context: context,
            builder: (ctx) => _FilePickerDialog(files: files),
          );
          if (chosen == null || !context.mounted) return null;
          fileIndex = chosen.index;
        }
      }
    } catch (_) {
      if (filesCancel.isCompleted) return null;
      filesDone = true;
      if (context.mounted) {
        final nav = Navigator.of(context, rootNavigator: true);
        if (nav.canPop()) nav.pop();
      }
      fileIndex = null;
    }
  }

  if (!context.mounted) return null;
  await Future<void>.delayed(Duration.zero);
  if (!context.mounted) return null;
  unawaited(
    _showPickerOverlay<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const _BusyDialog(),
    ),
  );
  try {
    final started = await prepareLocalStreamStart(
      magnet: picked.magnet,
      title: title,
      fileIndex: fileIndex,
    );
    if (context.mounted) {
      final nav = Navigator.of(context, rootNavigator: true);
      if (nav.canPop()) nav.pop();
    }
    return started;
  } catch (e) {
    if (context.mounted) {
      final nav = Navigator.of(context, rootNavigator: true);
      if (nav.canPop()) nav.pop();
      await _alert(context, friendlyRequestError(e));
    }
    return null;
  }
}

bool _looksLikeSeasonPack(String title) {
  final n = title.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');
  if (n.contains('complete') || n.contains('pack') || n.contains('season')) {
    // Single SxxExx episode releases are not packs.
    if (RegExp(r's\d{1,2}e\d{1,3}').hasMatch(n)) return false;
    return true;
  }
  // Batch dumps like S01E01-E10 / E01-E08
  if (RegExp(r's\d{1,2}e\d{1,3}-e?\d{1,3}').hasMatch(n)) return true;
  if (RegExp(r'e\d{1,3}-e\d{1,3}').hasMatch(n)) return true;
  return false;
}

Future<void> _alert(BuildContext context, String message) {
  return _showPickerOverlay<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Couldn’t stream'),
      content: Text(message),
      actions: [
        TvFocus(
          child: TextButton(
            autofocus: isAndroidTv,
            onPressed: () => Navigator.pop(ctx),
            child: const Text('OK'),
          ),
        ),
      ],
    ),
  );
}


/// Single opaque page for Android TV: search → choose → start, without
/// uncovering the detail/catalog between steps (that handoff ANRs).
class _TvStreamingPickerPage extends StatefulWidget {
  const _TvStreamingPickerPage({
    required this.client,
    required this.title,
    required this.kind,
    this.titleId,
    this.posterUrl,
    this.season,
    this.episode,
    this.preferredLanguages,
    this.resumePlayback = true,
    this.stopPreviousSessionId,
    this.onReadyToPlay,
  });

  final GraphQLClient client;
  final String title;
  final String kind;
  final String? titleId;
  final String? posterUrl;
  final int? season;
  final int? episode;
  final List<String>? preferredLanguages;
  final bool resumePlayback;
  final String? stopPreviousSessionId;
  final void Function(StreamStart started)? onReadyToPlay;

  @override
  State<_TvStreamingPickerPage> createState() => _TvStreamingPickerPageState();
}

class _TvStreamingPickerPageState extends State<_TvStreamingPickerPage> {
  static const _phaseLookup = 0;
  static const _phaseResults = 1;
  static const _phaseFiles = 2;
  static const _phaseStarting = 3;
  static const _phaseError = 4;

  var _phase = _phaseLookup;
  String? _error;
  List<StreamSourceGroup> _groups = const [];
  List<TorrentFileOption> _files = const [];
  StreamSource? _picked;

  @override
  void initState() {
    super.initState();
    unawaited(_runSearch(live: false));
  }

  Future<void> _runSearch({required bool live}) async {
    setState(() {
      _phase = _phaseLookup;
      _error = null;
    });
    try {
      final groups = await searchStreamingSourcesGrouped(
        resolution: _deviceQuality(context),
        client: widget.client,
        title: widget.title,
        kind: widget.kind,
        titleId: widget.titleId,
        season: widget.season,
        episode: widget.episode,
        preferredLanguages: widget.preferredLanguages,
        live: live,
      );
      if (!mounted) return;
      if (groups.isEmpty) {
        setState(() {
          _phase = _phaseError;
          _error =
              'No healthy sources found. Jackett may be down or only returning dead/cached torrents — check Jackett on the server console, then tap Refresh.';
        });
        return;
      }
      // Cached 0-seeder rows while Jackett is flaky — one live pass.
      final cacheLooksDead =
          !groups.any((g) => g.sources.any((s) => s.isHttp || s.seeders >= 2));
      if (cacheLooksDead && !live) {
        await _runSearch(live: true);
      }
      setState(() {
        _groups = groups;
        _phase = _phaseResults;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _phaseError;
        _error = friendlyRequestError(e);
      });
    }
  }

  Future<void> _onPick(StreamSource source) async {
    if (source.isHttp) {
      final result = directStreamStart(url: source.url, title: widget.title, headers: source.headers);
      widget.onReadyToPlay?.call(result);
      if (mounted) Navigator.of(context).pop(result);
      return;
    }
    if (source.magnet.trim().isEmpty) {
      setState(() {
        _phase = _phaseError;
        _error = 'That result has no torrent link. Try another result.';
      });
      return;
    }
    _picked = source;
    int? fileIndex;
    if (_looksLikeSeasonPack(source.title)) {
      setState(() {
        _phase = _phaseLookup;
        });
      try {
        final listed = await widget.client.query(
          QueryOptions(
            document: gql(TORRENT_FILES),
            fetchPolicy: FetchPolicy.networkOnly,
            queryRequestTimeout: const Duration(seconds: 25),
            variables: {
              'magnet': source.magnet,
              'season': widget.season,
              'episode': widget.episode,
            },
          ),
        );
        if (!mounted) return;
        if (!listed.hasException) {
          final files = ((listed.data?['torrentFiles'] as List?) ?? const [])
              .whereType<Map<String, dynamic>>()
              .map(TorrentFileOption.fromJson)
              .toList();
          final matches = files.where((f) => f.recommended).toList();
          if (files.length > 1 && matches.length == 1) {
            // The pack names this episode exactly: play it, no file list.
            fileIndex = matches.first.index;
          } else if (files.length > 1) {
            files.sort((a, b) {
              if (a.recommended != b.recommended) return a.recommended ? -1 : 1;
              return b.sizeBytes.compareTo(a.sizeBytes);
            });
            setState(() {
              _files = files;
              _phase = _phaseFiles;
            });
            return;
          }
          if (files.length == 1) fileIndex = files.first.index;
        }
      } catch (_) {}
    }
    await _startStream(source, fileIndex);
  }

  Future<void> _onPickFile(TorrentFileOption file) async {
    final source = _picked;
    if (source == null) return;
    await _startStream(source, file.index);
  }

  Future<void> _startStream(StreamSource source, int? fileIndex) async {
    if (!mounted) return;
    setState(() {
      _phase = _phaseStarting;
      });
    // Let "Starting stream…" paint and the input dispatcher settle.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    if (!mounted) return;
    try {
      if (!mounted) return;
      final result = await prepareLocalStreamStart(
        magnet: source.magnet,
        title: widget.title,
        fileIndex: fileIndex,
      ).timeout(
        const Duration(seconds: 30),
        onTimeout: () => throw TimeoutException(
          'Stream start timed out — try another source.',
        ),
      );
      if (!mounted) return;
      // Push player under this opaque cover, then pop immediately so Player()
      // init (next frames) does not run while we still owe a Navigator.pop —
      // that ordering left the UI stuck on "Starting stream…" and ANR'd.
      widget.onReadyToPlay?.call(result);
      if (mounted) Navigator.of(context).pop(result);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _phaseError;
        _error = friendlyRequestError(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _phase != _phaseStarting,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_phase == _phaseStarting) return;
        Navigator.of(context).pop();
      },
      child: Material(
        color: Theme.of(context).scaffoldBackgroundColor,
        child: SafeArea(
          child: Center(
            child: switch (_phase) {
              _phaseResults => _ResultsDialog(
                  groups: _groups,
                  title: widget.title,
                  subtitle: _pickerSubtitle(widget.kind, widget.season, widget.episode),
                  posterUrl: widget.posterUrl,
                  onRefresh: () => searchStreamingSourcesGrouped(
                    resolution: _deviceQuality(context),
                    client: widget.client,
                    title: widget.title,
                    kind: widget.kind,
                    titleId: widget.titleId,
                    season: widget.season,
                    episode: widget.episode,
                    preferredLanguages: widget.preferredLanguages,
                    live: true,
                  ),
                  onSelected: _onPick,
                ),
              _phaseFiles => _FilePickerDialog(
                  files: _files,
                  onSelected: _onPickFile,
                ),
              _phaseError => AlertDialog(
                  title: const Text('Couldn’t stream'),
                  content: Text(_error ?? 'Something went wrong.'),
                  actions: [
                    TvFocus(
                      child: TextButton(
                        autofocus: true,
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text('OK'),
                      ),
                    ),
                  ],
                ),
              _ => _BusyDialog(
                  message: _phase == _phaseStarting
                      ? 'Starting stream…'
                      : 'Finding streams…',
                  onCancel: _phase == _phaseStarting
                      ? null
                      : () => Navigator.of(context).pop(),
                ),
            },
          ),
        ),
      ),
    );
  }
}

class _BusyDialog extends StatelessWidget {
  const _BusyDialog({
    this.message = 'Please wait…',
    this.onCancel,
  });
  final String message;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      contentPadding: const EdgeInsets.fromLTRB(28, 24, 28, 28),
      content: SizedBox(
        width: 280,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (onCancel != null)
              Align(
                alignment: Alignment.topRight,
                child: TvFocus(
                  child: IconButton(
                    tooltip: 'Close',
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                    onPressed: onCancel,
                    icon: const Icon(Icons.close),
                  ),
                ),
              ),
            const SizedBox(
              width: 36,
              height: 36,
              child: CircularProgressIndicator(strokeWidth: 3),
            ),
            const SizedBox(height: 18),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: scheme.onSurface,
                fontSize: 15,
                height: 1.35,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ResultsDialog extends StatefulWidget {
  const _ResultsDialog({
    required this.groups,
    required this.onRefresh,
    this.onSelected,
    this.title = '',
    this.subtitle = '',
    this.posterUrl,
  });

  final List<StreamSourceGroup> groups;
  final Future<List<StreamSourceGroup>> Function() onRefresh;
  final Future<void> Function(StreamSource source)? onSelected;
  /// Header: the title's name, a short line under it and its poster.
  final String title;
  final String subtitle;
  final String? posterUrl;

  @override
  State<_ResultsDialog> createState() => _ResultsDialogState();
}

class _ResultsDialogState extends State<_ResultsDialog> {
  late List<StreamSourceGroup> _groups = List<StreamSourceGroup>.from(widget.groups);
  var _refreshing = false;
  String? _refreshError;
  /// Torrents (false) or Direct links (true), when there are both.
  var _direct = false;

  Future<void> _refresh() async {
    if (_refreshing) return;
    setState(() {
      _refreshing = true;
      _refreshError = null;
    });
    try {
      final next = await widget.onRefresh();
      if (!mounted) return;
      if (next.isEmpty) {
        setState(() {
          _refreshing = false;
          _refreshError = 'No healthy sources found. Try again later.';
        });
        return;
      }
      setState(() {
        _groups = next;
        _refreshing = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _refreshing = false;
        _refreshError = friendlyRequestError(e);
      });
    }
  }

  int _count(bool direct) =>
      _groups.fold(0, (n, g) => n + g.sources.where((s) => s.isHttp == direct).length);

  List<_ResultRow> _buildRows(bool? direct) {
    final rows = <_ResultRow>[];
    var firstSource = true;
    for (final group in _groups) {
      final sources = direct == null ? group.sources : group.sources.where((s) => s.isHttp == direct).toList();
      if (sources.isEmpty) continue;
      if (group.code != 'all') {
        rows.add(_ResultRow.heading(group.label));
      }
      for (final src in sources) {
        rows.add(_ResultRow.source(src, best: firstSource, autofocus: firstSource));
        firstSource = false;
      }
    }
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    final maxH = MediaQuery.sizeOf(context).height * 0.82;
    final torrents = _count(false);
    final direct = _count(true);
    final tabs = torrents > 0 && direct > 0;
    final showDirect = tabs ? _direct : torrents == 0;
    final rows = _buildRows(tabs ? showDirect : null);
    return FocusScope(
      autofocus: true,
      child: Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(24),
        child: Container(
          width: 640,
          constraints: BoxConstraints(maxHeight: maxH),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(PbRadius.panel + 4),
            border: Border.all(color: PbColors.line),
            gradient: const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xFF1C1D25), PbColors.surface],
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _PickerHeader(
                title: widget.title,
                subtitle: widget.subtitle,
                posterUrl: widget.posterUrl,
                refreshing: _refreshing,
                onRefresh: _refresh,
              ),
              if (tabs) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: _PickerTab(
                        label: 'Torrents',
                        count: torrents,
                        selected: !showDirect,
                        onTap: () => setState(() => _direct = false),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _PickerTab(
                        label: 'Direct links',
                        count: direct,
                        selected: showDirect,
                        onTap: () => setState(() => _direct = true),
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 10),
              Text(
                showDirect
                    ? 'Direct links play straight from the add-on, with no torrent.'
                    : 'Ranked for you: your quality first, then the healthiest swarm, your languages and a sensible size.',
                style: PbType.meta.copyWith(fontSize: 12.5, color: PbColors.textFaint),
              ),
              if (_refreshError != null) ...[
                const SizedBox(height: 8),
                Text(_refreshError!, style: PbType.meta.copyWith(color: PbColors.bad)),
              ],
              const SizedBox(height: 10),
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: rows.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (context, i) {
                    final row = rows[i];
                    if (row.heading != null) {
                      return Padding(
                        padding: EdgeInsets.only(top: i == 0 ? 0 : 8, left: 4),
                        child: Text(
                          row.heading!.toUpperCase(),
                          style: PbType.label.copyWith(color: PbColors.textMuted, letterSpacing: 1),
                        ),
                      );
                    }
                    return _TorrentTile(
                      source: row.source!,
                      best: row.best,
                      autofocus: row.autofocus,
                      onSelected: widget.onSelected,
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PickerHeader extends StatelessWidget {
  const _PickerHeader({
    required this.title,
    required this.subtitle,
    required this.posterUrl,
    required this.refreshing,
    required this.onRefresh,
  });

  final String title;
  final String subtitle;
  final String? posterUrl;
  final bool refreshing;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (posterUrl != null && posterUrl!.isNotEmpty) ...[
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(width: 54, height: 81, child: CachedArt(url: posterUrl, memCacheWidth: 160)),
          ),
          const SizedBox(width: 14),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'CHOOSE A STREAM',
                style: PbType.label.copyWith(color: PbColors.primary, letterSpacing: 1.1),
              ),
              const SizedBox(height: 2),
              Text(
                title.isEmpty ? 'Choose a stream' : title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: PbType.h1.copyWith(fontSize: 24, color: PbColors.text),
              ),
              if (subtitle.isNotEmpty)
                Text(subtitle, style: PbType.meta.copyWith(color: PbColors.textMuted)),
            ],
          ),
        ),
        TvFocus(
          child: IconButton(
            tooltip: 'Search again',
            onPressed: refreshing ? null : onRefresh,
            icon: refreshing
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.refresh_rounded, color: PbColors.textMuted),
          ),
        ),
        TvFocus(
          child: IconButton(
            tooltip: 'Close',
            onPressed: () => Navigator.maybePop(context),
            icon: const Icon(Icons.close_rounded, color: PbColors.textMuted),
          ),
        ),
      ],
    );
  }
}

class _PickerTab extends StatelessWidget {
  const _PickerTab({required this.label, required this.count, required this.selected, required this.onTap});

  final String label;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final fg = selected ? PbColors.onPrimary : PbColors.textMuted;
    return TvFocus(
      child: Material(
        color: selected ? PbColors.primary : Colors.transparent,
        shape: StadiumBorder(side: BorderSide(color: selected ? Colors.transparent : PbColors.line)),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: SizedBox(
            height: 36,
            child: Center(
              child: Text.rich(
                TextSpan(
                  text: label,
                  children: [
                    TextSpan(text: '  $count', style: TextStyle(color: fg.withValues(alpha: 0.75))),
                  ],
                ),
                style: PbType.button.copyWith(color: fg),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ResultRow {
  const _ResultRow._({this.heading, this.source, this.best = false, this.autofocus = false});
  factory _ResultRow.heading(String label) => _ResultRow._(heading: label);
  factory _ResultRow.source(StreamSource source, {required bool best, required bool autofocus}) =>
      _ResultRow._(source: source, best: best, autofocus: autofocus);

  final String? heading;
  final StreamSource? source;
  final bool best;
  final bool autofocus;
}

/// Signal bars for a swarm's health: 1–4 lit, green when healthy, amber when weak.
int _healthBars(StreamSource s) => switch (s.health) {
      'excellent' => 4,
      'good' => 3,
      'decent' => 2,
      _ => 1,
    };

class _SignalBars extends StatelessWidget {
  const _SignalBars({required this.lit});

  final int lit;

  @override
  Widget build(BuildContext context) {
    final on = lit >= 3 ? PbColors.good : PbColors.warn;
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (var i = 0; i < 4; i++) ...[
          if (i > 0) const SizedBox(width: 2),
          Container(
            width: 3,
            height: 4.0 + i * 2.7,
            decoration: BoxDecoration(
              color: i < lit ? on : Colors.white.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(1),
            ),
          ),
        ],
      ],
    );
  }
}

class _TorrentTile extends StatefulWidget {
  const _TorrentTile({
    required this.source,
    required this.best,
    required this.autofocus,
    this.onSelected,
  });

  final StreamSource source;
  final bool best;
  final bool autofocus;
  final Future<void> Function(StreamSource source)? onSelected;

  @override
  State<_TorrentTile> createState() => _TorrentTileState();
}

class _TorrentTileState extends State<_TorrentTile> {
  var _focused = false;

  void _pick() {
    final cb = widget.onSelected;
    if (cb != null) {
      // Finish the KeyEvent first — starting GraphQL/setState in the
      // same turn as ActivateIntent ANRs Android TV.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(cb(widget.source));
      });
    } else {
      Navigator.pop(context, widget.source);
    }
  }

  @override
  Widget build(BuildContext context) {
    final source = widget.source;
    final best = widget.best;
    final tags = ReleaseTags.parse(source.title);
    final radius = BorderRadius.circular(12);
    final status = source.isHttp
        ? 'Direct link'
        : '${_healthLabel(source.health)} · ${source.seeders} seeder${source.seeders == 1 ? '' : 's'}';
    final spec = [
      if (source.size.isNotEmpty && source.size != '?') source.size,
      if (tags.codec.isNotEmpty) tags.codec,
      if (tags.audio.isNotEmpty) tags.audio,
    ].join(' · ');
    final code = source.language.trim().toLowerCase();
    // Nothing when the release doesn't say ("unknown", "und", empty).
    final known = code.isNotEmpty && !const {'unknown', 'und', 'all'}.contains(code);
    final origin = [
      if (known) languageDisplayName(source.language),
      source.providers.length > 1 ? source.providers.join(' + ') : _torrentSourceLabel(source),
    ].join(' · ');
    return TvFocus(
      child: Material(
        color: Colors.transparent,
        borderRadius: radius,
        child: InkWell(
          autofocus: widget.autofocus,
          borderRadius: radius,
          // Ring only for keyboard / remote focus, not after a mouse click.
          onFocusChange: (v) => setState(
            // The white focus ring is for the TV remote only; desktop shows the Best outline.
            () => _focused = v && isAndroidTv,
          ),
          onTap: _pick,
          child: AnimatedContainer(
            duration: PbMotion.fast,
            padding: const EdgeInsets.fromLTRB(10, 9, 10, 9),
            decoration: BoxDecoration(
              borderRadius: radius,
              color: PbColors.surfaceRaised,
              gradient: best
                  ? const LinearGradient(
                      colors: [Color(0x1FE2A456), PbColors.surfaceRaised],
                      stops: [0, 0.6],
                    )
                  : null,
              border: Border.all(
                color: _focused
                    ? PbColors.focus
                    : best
                        ? PbColors.primary
                        : Colors.transparent,
                width: _focused ? PbSize.focusRing : 1,
              ),
            ),
            child: Row(
              children: [
                _QualityBox(tags: tags),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          if (source.isHttp)
                            const Icon(Icons.link_rounded, size: 15, color: PbColors.textMuted)
                          else
                            _SignalBars(lit: _healthBars(source)),
                          const SizedBox(width: 7),
                          Flexible(
                            child: Text(
                              status,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: PbType.meta.copyWith(fontSize: 12.5, color: PbColors.textMuted),
                            ),
                          ),
                          if (best) ...[
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                              decoration: BoxDecoration(
                                color: PbColors.primary,
                                borderRadius: BorderRadius.circular(5),
                              ),
                              child: Text(
                                'Best',
                                style: PbType.label.copyWith(fontSize: 10.5, color: PbColors.onPrimary),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 3),
                      if (spec.isNotEmpty)
                        Text(spec, style: PbType.title.copyWith(fontSize: 14, color: PbColors.text)),
                      Text(
                        origin,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: PbType.meta.copyWith(fontSize: 12, color: PbColors.textFaint),
                      ),
                      Tooltip(
                        message: source.title,
                        child: Text(
                          source.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: PbType.meta.copyWith(fontSize: 11.5, color: PbColors.textFaint),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: best ? PbColors.primary : Colors.white.withValues(alpha: 0.10),
                  ),
                  child: Icon(
                    Icons.play_arrow_rounded,
                    size: 20,
                    color: best ? PbColors.onPrimary : PbColors.text,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// "4K / HDR", "1080 / BluRay": the copy's quality at a glance.
class _QualityBox extends StatelessWidget {
  const _QualityBox({required this.tags});

  final ReleaseTags tags;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 52,
      height: 48,
      decoration: BoxDecoration(
        color: PbColors.ground,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: PbColors.line),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            tags.resolution.isEmpty ? 'HD' : tags.resolution,
            style: PbType.h2.copyWith(fontSize: 15, height: 1, color: PbColors.text),
          ),
          if (tags.source.isNotEmpty) ...[
            const SizedBox(height: 3),
            Text(
              tags.source.toUpperCase(),
              style: PbType.label.copyWith(fontSize: 8.5, color: PbColors.primary, letterSpacing: 0.6),
            ),
          ],
        ],
      ),
    );
  }
}

String _torrentSourceLabel(StreamSource source) {
  final indexer = source.indexer.trim();
  final tracker = source.tracker.trim();
  final indexerOk = indexer.isNotEmpty && indexer.toLowerCase() != 'jackett';
  final trackerOk = tracker.isNotEmpty && tracker.toLowerCase() != 'unknown';
  if (indexerOk && trackerOk) {
    final same = indexer.toLowerCase() == tracker.toLowerCase();
    return same ? indexer : '$indexer · $tracker';
  }
  if (indexerOk) return indexer;
  if (trackerOk) return tracker;
  return 'Unknown source';
}

/// "Season 2 · Episode 3" or "Movie" under the picker's title.
String _pickerSubtitle(String kind, int? season, int? episode) {
  if (season != null && episode != null) return 'Season $season · Episode $episode';
  return kind.toUpperCase() == 'MOVIE' ? 'Movie' : 'Series';
}

class _Tag extends StatelessWidget {
  const _Tag({required this.label, this.emphasized = false});
  final String label;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: emphasized ? PbColors.primary : PbColors.surfaceRaised,
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        label,
        style: PbType.label.copyWith(fontSize: 10.5, color: emphasized ? PbColors.onPrimary : PbColors.text),
      ),
    );
  }
}

String _healthLabel(String health) {
  switch (health) {
    case 'excellent':
      return 'Healthy';
    case 'good':
      return 'Good';
    case 'decent':
      return 'OK';
    case 'poor':
      return 'Weak';
    case 'unknown':
      return 'Unlisted seeds';
    default:
      return 'Low seeds';
  }
}

class _FilePickerDialog extends StatelessWidget {
  const _FilePickerDialog({required this.files, this.onSelected});
  final List<TorrentFileOption> files;
  final Future<void> Function(TorrentFileOption file)? onSelected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final maxH = MediaQuery.sizeOf(context).height * 0.72;
    return FocusScope(
      autofocus: true,
      child: AlertDialog(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        title: const Text('Choose a file'),
        contentPadding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
        content: SizedBox(
          width: 560,
          height: maxH,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'This torrent has multiple videos. Only the file you pick will download.',
                style: TextStyle(color: scheme.onSurfaceVariant, height: 1.35, fontSize: 13),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: ListView.separated(
                  itemCount: files.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (context, i) {
                    final file = files[i];
                    final radius = BorderRadius.circular(14);
                    return TvFocus(
                      child: Material(
                        color: file.recommended
                            ? PbColors.primary.withValues(alpha: 0.12)
                            : scheme.surfaceContainerHighest.withValues(alpha: 0.45),
                        borderRadius: radius,
                        child: InkWell(
                          autofocus: i == 0,
                          borderRadius: radius,
                          onTap: () {
                            final cb = onSelected;
                            if (cb != null) {
                              WidgetsBinding.instance.addPostFrameCallback((_) {
                                unawaited(cb(file));
                              });
                            } else {
                              Navigator.pop(context, file);
                            }
                          },
                          child: Container(
                            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                            decoration: BoxDecoration(
                              borderRadius: radius,
                              border: Border.all(
                                color: file.recommended
                                    ? PbColors.primary.withValues(alpha: 0.65)
                                    : scheme.outline.withValues(alpha: 0.22),
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    if (file.recommended)
                                      const Padding(
                                        padding: EdgeInsets.only(right: 8),
                                        child: _Tag(label: 'Matches episode', emphasized: true),
                                      ),
                                    const Spacer(),
                                    Text(
                                      file.size,
                                      style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  file.shortName,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                    height: 1.25,
                                    fontSize: 15,
                                  ),
                                ),
                                if (file.name != file.shortName) ...[
                                  const SizedBox(height: 4),
                                  Text(
                                    file.name,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: scheme.onSurfaceVariant.withValues(alpha: 0.85),
                                      fontSize: 11,
                                      height: 1.3,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The Choose a stream dialog on its own, for screenshot tests.
@visibleForTesting
Widget streamPickerForTest({
  required List<StreamSourceGroup> groups,
  String title = '',
  String subtitle = '',
}) =>
    _ResultsDialog(groups: groups, onRefresh: () async => groups, title: title, subtitle: subtitle);
