import 'dart:async';

import 'package:flutter/material.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:media_kit_libs_android_video/media_kit_libs_android_video.dart';

import '../content_languages.dart';
import '../graphql/client.dart';
import '../graphql/queries.dart';
import '../friendly_error.dart';
import '../models.dart';
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

String _lookupHeading({
  required String title,
  int? season,
  int? episode,
}) {
  final name = title.trim();
  if (season != null && episode != null) {
    final s = season.toString().padLeft(2, '0');
    final e = episode.toString().padLeft(2, '0');
    return name.isEmpty ? 'S${s}E${e}' : '$name · S${s}E${e}';
  }
  return name;
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
  final languageLabel = _preferredLanguageLabel(preferredLanguages);
  final heading = _lookupHeading(title: title, season: season, episode: episode);

  // Cancel must return immediately so episode/movie busy spinners clear;
  // in-flight GraphQL work is ignored when it eventually finishes.
  final searchCancel = Completer<void>();
  var searchDone = false;
  unawaited(
    _showPickerOverlay<void>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => _BusyDialog(
        label: 'Looking up sources…',
        title: heading,
        onCancel: () => Navigator.of(ctx).pop(),
      ),
    ).whenComplete(() {
      if (!searchDone && !searchCancel.isCompleted) {
        searchCancel.complete();
      }
    }),
  );

  late List<StreamSource> found;
  try {
    // Cache-first on the server (3-day TTL). Pass live:true only from Refresh.
    final searchFuture = searchStreamingSources(
      client: client,
      title: title,
      kind: kind,
      titleId: titleId,
      season: season,
      episode: episode,
      live: false,
    );
    // Ignore late success/failure after the user already cancelled.
    unawaited(searchFuture.then((_) {}, onError: (_) {}));
    final sources = await Future.any<List<StreamSource>?>([
      searchFuture.then((v) => v),
      searchCancel.future.then((_) => null),
    ]);
    if (sources == null || searchCancel.isCompleted) {
      return null;
    }
    found = sourcesMatchingEpisode(
      sources,
      season: season,
      episode: episode,
    );
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
  // Let the busy dialog unmount and paint before building the results list —
  // building dozens of TV focus tiles in the same frame as the pop ANRs on
  // Android TV emulators.
  await Future<void>.delayed(Duration.zero);
  if (!context.mounted) return null;
  if (found.isEmpty) {
    await _alert(
      context,
      'No healthy sources with enough seeders were found. Try again later, or check Jackett on the server console.',
    );
    return null;
  }
  // Server ranks to 24; cap anyway so a fat cache entry cannot freeze the UI.
  if (found.length > 24) {
    found = found.sublist(0, 24);
  }

  final picked = await _showPickerOverlay<StreamSource>(
    context: context,
    builder: (ctx) => _ResultsDialog(
      sources: found,
      languageLabel: languageLabel,
      title: heading,
      onRefresh: () => searchStreamingSources(
        client: client,
        title: title,
        kind: kind,
        titleId: titleId,
        season: season,
        episode: episode,
        live: true,
      ).then(
        (list) {
          final matched = sourcesMatchingEpisode(
            list,
            season: season,
            episode: episode,
          );
          return matched.length > 24 ? matched.sublist(0, 24) : matched;
        },
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
          label: 'Reading torrent files…',
          title: heading,
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
      builder: (ctx) => _BusyDialog(label: 'Starting stream…', title: heading),
    ),
  );
  try {
    final previous = stopPreviousSessionId?.trim();
    if (previous != null && previous.isNotEmpty && !previous.startsWith('local-')) {
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
    final started = await client.mutate(
      MutationOptions(
        document: gql(START_STREAM),
        fetchPolicy: FetchPolicy.networkOnly,
        queryRequestTimeout: const Duration(seconds: 45),
        variables: {
          'magnet': picked.magnet,
          'title': title,
          'titleId': titleId,
          'resume': resumePlayback,
          'seeders': picked.seeders,
          'peers': picked.peers,
          'season': season,
          'episode': episode,
          'fileIndex': fileIndex,
        },
      ),
    );
    if (context.mounted) {
      final nav = Navigator.of(context, rootNavigator: true);
      if (nav.canPop()) nav.pop();
    }
    if (started.hasException) {
      throw graphqlMessage(started);
    }
    final session = StreamSession.fromJson(
      started.data?['startStream'] as Map<String, dynamic>? ?? const {},
    );
    if (session.id.isEmpty) {
      throw 'Couldn’t start this stream. Try another result.';
    }
    return StreamStart(
      session: session,
      magnet: picked.magnet,
      fileIndex: fileIndex,
    );
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

String _preferredLanguageLabel(List<String>? codes) {
  final cleaned = (codes ?? const [])
      .map((e) => e.trim().toLowerCase())
      .where((e) => e.isNotEmpty && e != 'all')
      .toList();
  if (cleaned.isEmpty) return 'All languages';
  final names = cleaned.map(languageDisplayName).where((n) => n.isNotEmpty).join(', ');
  if (names.isEmpty) return 'All languages';
  return '$names + Multi';
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
  var _busyLabel = 'Looking up sources…';
  String? _error;
  List<StreamSource> _sources = const [];
  List<TorrentFileOption> _files = const [];
  StreamSource? _picked;

  String get _heading =>
      _lookupHeading(title: widget.title, season: widget.season, episode: widget.episode);
  String get _languageLabel => _preferredLanguageLabel(widget.preferredLanguages);

  @override
  void initState() {
    super.initState();
    // Load libmpv on a Java worker while Jackett search runs — must not block UI.
    unawaited(MediaKitAndroidVideo.preload());
    unawaited(_runSearch(live: false));
  }

  Future<void> _runSearch({required bool live}) async {
    setState(() {
      _phase = _phaseLookup;
      _busyLabel = live ? 'Refreshing sources from Jackett…' : 'Looking up sources…';
      _error = null;
    });
    try {
      final sources = await searchStreamingSources(
        client: widget.client,
        title: widget.title,
        kind: widget.kind,
        titleId: widget.titleId,
        season: widget.season,
        episode: widget.episode,
        live: live,
      );
      if (!mounted) return;
      var found = sourcesMatchingEpisode(
        sources,
        season: widget.season,
        episode: widget.episode,
      );
      if (found.length > 24) found = found.sublist(0, 24);
      if (found.isEmpty) {
        setState(() {
          _phase = _phaseError;
          _error =
              'No healthy sources with enough seeders were found. Try again later, or check Jackett on the server console.';
        });
        return;
      }
      setState(() {
        _sources = found;
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
        _busyLabel = 'Reading torrent files…';
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
      _busyLabel = 'Starting stream…';
    });
    // Let "Starting stream…" paint and the input dispatcher settle.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    if (!mounted) return;
    try {
      final nativeReady = MediaKitAndroidVideo.preload();
      final previous = widget.stopPreviousSessionId?.trim();
      if (previous != null && previous.isNotEmpty && !previous.startsWith('local-')) {
        try {
          await widget.client.mutate(
            MutationOptions(
              document: gql(STOP_STREAM),
              fetchPolicy: FetchPolicy.networkOnly,
              variables: {'sessionId': previous},
            ),
          );
        } catch (_) {}
      }
      if (!mounted) return;
      final started = await widget.client.mutate(
        MutationOptions(
          document: gql(START_STREAM),
          fetchPolicy: FetchPolicy.networkOnly,
          queryRequestTimeout: const Duration(seconds: 45),
          variables: {
            'magnet': source.magnet,
            'title': widget.title,
            'titleId': widget.titleId,
            'resume': widget.resumePlayback,
            'seeders': source.seeders,
            'peers': source.peers,
            'season': widget.season,
            'episode': widget.episode,
            'fileIndex': fileIndex,
          },
        ),
      );
      await nativeReady;
      if (!mounted) return;
      if (started.hasException) throw graphqlMessage(started);
      final session = StreamSession.fromJson(
        started.data?['startStream'] as Map<String, dynamic>? ?? const {},
      );
      if (session.id.isEmpty) {
        throw 'Couldn’t start this stream. Try another result.';
      }
      final result = StreamStart(
        session: session,
        magnet: source.magnet,
        fileIndex: fileIndex,
      );
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
                  sources: _sources,
                  languageLabel: _languageLabel,
                  title: _heading,
                  onRefresh: () => searchStreamingSources(
                    client: widget.client,
                    title: widget.title,
                    kind: widget.kind,
                    titleId: widget.titleId,
                    season: widget.season,
                    episode: widget.episode,
                    live: true,
                  ).then((list) {
                    final matched = sourcesMatchingEpisode(
                      list,
                      season: widget.season,
                      episode: widget.episode,
                    );
                    return matched.length > 24 ? matched.sublist(0, 24) : matched;
                  }),
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
                  label: _busyLabel,
                  title: _heading,
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
  const _BusyDialog({required this.label, this.title, this.onCancel});
  final String label;
  final String? title;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final heading = (title ?? '').trim();
    return AlertDialog(
      contentPadding: const EdgeInsets.fromLTRB(20, 8, 8, 20),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(4, 10, 8, 0),
                    child: Text(
                      heading.isEmpty ? label : heading,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: heading.isEmpty ? 16 : 15,
                        fontWeight: FontWeight.w700,
                        height: 1.25,
                        color: scheme.onSurface,
                      ),
                    ),
                  ),
                ),
                if (onCancel != null)
                  TvFocus(
                    child: IconButton(
                      tooltip: 'Close',
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                      onPressed: onCancel,
                      icon: const Icon(Icons.close),
                    ),
                  ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 10, 12, 4),
              child: Row(
                children: [
                  const SizedBox(
                    width: 28,
                    height: 28,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Text(
                      heading.isEmpty ? 'Please wait…' : label,
                      style: TextStyle(
                        fontSize: 14,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
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
    required this.sources,
    required this.languageLabel,
    required this.title,
    required this.onRefresh,
    this.onSelected,
  });

  final List<StreamSource> sources;
  final String languageLabel;
  final String title;
  final Future<List<StreamSource>> Function() onRefresh;
  /// When set (TV single-page flow), call instead of [Navigator.pop].
  final Future<void> Function(StreamSource source)? onSelected;

  @override
  State<_ResultsDialog> createState() => _ResultsDialogState();
}

class _ResultsDialogState extends State<_ResultsDialog> {
  late List<StreamSource> _sources = List<StreamSource>.from(widget.sources);
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
        _sources = next;
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

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final maxH = MediaQuery.sizeOf(context).height * 0.72;
    final heading = widget.title.trim();
    // Fixed height + Expanded ListView (no shrinkWrap). Flexible+shrinkWrap
    // inside a min-sized Column lays out every tile up-front and ANRs on TV.
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
              if (heading.isNotEmpty) ...[
                Text(
                  heading,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14, height: 1.3),
                ),
                const SizedBox(height: 6),
              ],
              Text(
                _refreshing
                    ? 'Refreshing sources from Jackett…'
                    : 'Showing ${widget.languageLabel} — most seeded magnets first. Cached up to 3 days; refresh for live results.',
                style: TextStyle(color: scheme.onSurfaceVariant, height: 1.35, fontSize: 13),
              ),
              if (_refreshError != null) ...[
                const SizedBox(height: 8),
                Text(
                  _refreshError!,
                  style: TextStyle(color: scheme.error, fontSize: 13, height: 1.3),
                ),
              ],
              const SizedBox(height: 12),
              Expanded(
                child: ListView.separated(
                  itemCount: _sources.length,
                  separatorBuilder: (_, i) => i == 0 && _sources.length > 1
                      ? Padding(
                          padding: const EdgeInsets.fromLTRB(4, 14, 4, 10),
                          child: Text(
                            'More options',
                            style: TextStyle(
                              color: scheme.onSurfaceVariant,
                              fontWeight: FontWeight.w700,
                              fontSize: 12,
                            ),
                          ),
                        )
                      : const SizedBox(height: 8),
                  itemBuilder: (context, i) {
                    return _TorrentTile(
                      source: _sources[i],
                      best: i == 0,
                      autofocus: i == 0,
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
