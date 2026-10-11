import 'dart:async';

import 'package:flutter/material.dart';
import 'package:graphql_flutter/graphql_flutter.dart';

import '../content_languages.dart';
import '../graphql/client.dart';
import '../graphql/queries.dart';
import '../friendly_error.dart';
import '../local_torrent.dart';
import '../models.dart';
import '../stream_resume_policy.dart';
import '../theme.dart';
import '../tv.dart';
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
  });

  final StreamSession session;
  final String magnet;
  final bool localTorrent;
  final int? fileIndex;
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

/// Search each preferred language separately (preferred order), dedupe magnets,
/// and drop empty language headings.
Future<List<StreamSourceGroup>> searchStreamingSourcesGrouped({
  required GraphQLClient client,
  required String title,
  required String kind,
  String? titleId,
  int? season,
  int? episode,
  List<String>? preferredLanguages,
  bool live = false,
}) async {
  final langs = preferredLanguageCodes(preferredLanguages ?? const []);
  if (langs.isEmpty) {
    final all = sourcesMatchingEpisode(
      await searchStreamingSources(
        client: client,
        title: title,
        kind: kind,
        titleId: titleId,
        season: season,
        episode: episode,
        live: live,
      ),
      season: season,
      episode: episode,
    );
    final capped = all.length > 24 ? all.sublist(0, 24) : all;
    if (capped.isEmpty) return const [];
    return [StreamSourceGroup(code: 'all', label: 'Streams', sources: capped)];
  }

  final seen = <String>{};
  final groups = <StreamSourceGroup>[];
  // Parallel per-language Jackett searches — same ranking as a single query.
  final results = await Future.wait([
    for (final lang in langs)
      searchStreamingSources(
        client: client,
        title: title,
        kind: kind,
        titleId: titleId,
        season: season,
        episode: episode,
        language: lang,
        live: live,
      ),
  ]);

  for (var i = 0; i < langs.length; i++) {
    final lang = langs[i];
    final matched = sourcesMatchingEpisode(
      results[i],
      season: season,
      episode: episode,
    );
    final unique = <StreamSource>[];
    for (final src in matched) {
      final key = src.magnet.trim().isNotEmpty ? src.magnet.trim() : src.id;
      if (key.isEmpty || !seen.add(key)) continue;
      unique.add(src);
    }
    if (unique.isEmpty) continue;
    final capped = unique.length > 24 ? unique.sublist(0, 24) : unique;
    groups.add(
      StreamSourceGroup(
        code: lang,
        label: languageDisplayName(lang),
        sources: capped,
      ),
    );
  }
  return groups;
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
  // Ignore legacy server session ids — downloads are on-device only now.
  final previous = stopPreviousSessionId?.trim();
  if (previous != null &&
      previous.isNotEmpty &&
      !previous.startsWith('local-')) {
    try {
      await client.mutate(
        MutationOptions(
          document: gql(STOP_STREAM),
          fetchPolicy: FetchPolicy.networkOnly,
          variables: {'sessionId': previous},
        ),
      );
    } catch (_) {}
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
    // Brief opaque cover while the previous torrent restarts (no source list).
    final loading = _showPickerOverlay<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const PopScope(
        canPop: false,
        child: Padding(
          padding: EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('Resuming previous stream…'),
            ],
          ),
        ),
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

  return showStreamingPicker(
    context: context,
    client: client,
    title: title,
    kind: kind,
    titleId: titleId,
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
        !groups.any((g) => g.sources.any((s) => s.seeders >= 2));
    if ((groups.isEmpty || cacheLooksDead) && !searchCancel.isCompleted) {
      try {
        final liveGroups = await searchStreamingSourcesGrouped(
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
      onRefresh: () => searchStreamingSourcesGrouped(
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
        if (files.isEmpty) {
          fileIndex = null;
        } else if (files.length == 1) {
          fileIndex = files.first.index;
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
    final previous = stopPreviousSessionId?.trim();
    if (previous != null &&
        previous.isNotEmpty &&
        !previous.startsWith('local-')) {
      try {
        await client.mutate(
          MutationOptions(
            document: gql(STOP_STREAM),
            fetchPolicy: FetchPolicy.networkOnly,
            variables: {'sessionId': previous},
          ),
        );
      } catch (_) {}
    }
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
          !groups.any((g) => g.sources.any((s) => s.seeders >= 2));
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
          if (files.length > 1) {
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
      final previous = widget.stopPreviousSessionId?.trim();
      if (previous != null &&
          previous.isNotEmpty &&
          !previous.startsWith('local-')) {
        try {
          await widget.client
              .mutate(
                MutationOptions(
                  document: gql(STOP_STREAM),
                  fetchPolicy: FetchPolicy.networkOnly,
                  variables: {'sessionId': previous},
                ),
              )
              .timeout(const Duration(seconds: 8));
        } catch (_) {}
      }
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
                  onRefresh: () => searchStreamingSourcesGrouped(
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
  });

  final List<StreamSourceGroup> groups;
  final Future<List<StreamSourceGroup>> Function() onRefresh;
  final Future<void> Function(StreamSource source)? onSelected;

  @override
  State<_ResultsDialog> createState() => _ResultsDialogState();
}

class _ResultsDialogState extends State<_ResultsDialog> {
  late List<StreamSourceGroup> _groups = List<StreamSourceGroup>.from(widget.groups);
  var _refreshing = false;
  String? _refreshError;

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

  List<_ResultRow> _buildRows() {
    final rows = <_ResultRow>[];
    var firstSource = true;
    for (final group in _groups) {
      if (group.sources.isEmpty) continue;
      if (group.code != 'all') {
        rows.add(_ResultRow.heading(group.label));
      }
      for (final src in group.sources) {
        rows.add(
          _ResultRow.source(
            src,
            best: firstSource,
            autofocus: firstSource,
          ),
        );
        firstSource = false;
      }
    }
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final maxH = MediaQuery.sizeOf(context).height * 0.72;
    final rows = _buildRows();
    return FocusScope(
      autofocus: true,
      child: AlertDialog(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        title: Row(
          children: [
            const Expanded(child: Text('Choose a stream')),
            TvFocus(
              child: IconButton(
                tooltip: 'Refresh from Jackett',
                onPressed: _refreshing ? null : _refresh,
                icon: _refreshing
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh_rounded),
              ),
            ),
          ],
        ),
        contentPadding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
        content: SizedBox(
          width: 560,
          height: maxH,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_refreshError != null) ...[
                Text(
                  _refreshError!,
                  style: TextStyle(color: scheme.error, fontSize: 13, height: 1.3),
                ),
                const SizedBox(height: 8),
              ],
              Expanded(
                child: ListView.separated(
                  itemCount: rows.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (context, i) {
                    final row = rows[i];
                    if (row.heading != null) {
                      return Padding(
                        padding: EdgeInsets.only(top: i == 0 ? 4 : 10, bottom: 2, left: 4),
                        child: Text(
                          row.heading!,
                          style: TextStyle(
                            color: scheme.onSurfaceVariant,
                            fontWeight: FontWeight.w700,
                            fontSize: 13,
                          ),
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

class _TorrentTile extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(14);
    return TvFocus(
      child: Material(
        color: best
            ? AppTheme.seed.withValues(alpha: 0.12)
            : scheme.surfaceContainerHighest.withValues(alpha: 0.45),
        borderRadius: radius,
        child: InkWell(
          autofocus: autofocus,
          borderRadius: radius,
          onTap: () {
            final cb = onSelected;
            if (cb != null) {
              // Finish the KeyEvent first — starting GraphQL/setState in the
              // same turn as ActivateIntent ANRs Android TV.
              WidgetsBinding.instance.addPostFrameCallback((_) {
                unawaited(cb(source));
              });
            } else {
              Navigator.pop(context, source);
            }
          },
          child: Container(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            decoration: BoxDecoration(
              borderRadius: radius,
              border: Border.all(
                color: best ? AppTheme.seed.withValues(alpha: 0.65) : scheme.outline.withValues(alpha: 0.22),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    if (best)
                      const Padding(
                        padding: EdgeInsets.only(right: 8),
                        child: _Tag(label: 'Best match', emphasized: true),
                      ),
                    _Tag(label: _healthLabel(source.health), emphasized: source.seeders >= 20),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: _Tag(label: _torrentSourceLabel(source)),
                      ),
                    ),
                    Icon(Icons.play_arrow_rounded, size: 22, color: best ? AppTheme.seed : scheme.onSurfaceVariant),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  source.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w700, height: 1.25, fontSize: 15),
                ),
                const SizedBox(height: 8),
                Text(
                  '${source.size}  ·  ${source.seeders} seeders'
                  '${source.peers > 0 ? "  ·  ${source.peers} peers" : ""}'
                  '  ·  ${languageDisplayName(source.language)}',
                  style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13, height: 1.3),
                ),
              ],
            ),
          ),
        ),
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

class _Tag extends StatelessWidget {
  const _Tag({required this.label, this.emphasized = false});
  final String label;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: emphasized
            ? AppTheme.seed.withValues(alpha: 0.28)
            : scheme.surfaceContainerHighest.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: emphasized ? AppTheme.seed : scheme.outline.withValues(alpha: 0.22),
        ),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: emphasized ? scheme.primary : scheme.onSurface,
        ),
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
                            ? AppTheme.seed.withValues(alpha: 0.12)
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
                                    ? AppTheme.seed.withValues(alpha: 0.65)
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
