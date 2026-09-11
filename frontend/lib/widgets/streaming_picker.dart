import 'dart:async';

import 'package:flutter/material.dart';
import 'package:graphql_flutter/graphql_flutter.dart';

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
  bool? live,
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
        if (live != null) 'live': live,
      },
    ),
  );
  if (result.hasException) {
    throw graphqlMessage(result);
  }
  final raw = (result.data?['streamingSearch'] as List?) ?? const [];
  return raw.whereType<Map<String, dynamic>>().map(StreamSource.fromJson).toList();
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
}) async {
  if (!context.mounted) return null;
  final languageLabel = _preferredLanguageLabel(preferredLanguages);

  // Cancel must return immediately so episode/movie busy spinners clear;
  // in-flight GraphQL work is ignored when it eventually finishes.
  final searchCancel = Completer<void>();
  var searchDone = false;
  unawaited(
    showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => _BusyDialog(
        label: 'Looking up sources…',
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
    final searchFuture = searchStreamingSources(
      client: client,
      title: title,
      kind: kind,
      titleId: titleId,
      season: season,
      episode: episode,
      live: true,
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
  if (!context.mounted) return null;
  if (found.isEmpty) {
    await _alert(
      context,
      'No healthy sources with enough seeders were found. Try again later, or check Jackett on the server console.',
    );
    return null;
  }

  final picked = await showDialog<StreamSource>(
    context: context,
    builder: (ctx) => _ResultsDialog(
      sources: found,
      languageLabel: languageLabel,
    ),
  );
  if (picked == null || !context.mounted) return null;
  if (picked.magnet.trim().isEmpty) {
    await _alert(context, 'That result has no torrent link. Try another result.');
    return null;
  }

  // Multi-file torrents / season packs: let the user pick which video to play.
  // Only that file is downloaded (server sets only_files).
  // If metadata listing fails, fall back to server-side file pick so Play still works.
  int? fileIndex;
  final filesCancel = Completer<void>();
  var filesDone = false;
  unawaited(
    showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => _BusyDialog(
        label: 'Reading torrent files…',
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
        queryRequestTimeout: const Duration(seconds: 120),
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
    ]);
    if (listed == null || filesCancel.isCompleted) return null;
    filesDone = true;
    if (context.mounted) {
      final nav = Navigator.of(context, rootNavigator: true);
      if (nav.canPop()) nav.pop();
    }
    if (listed.hasException) {
      // Metadata fetch failed — continue without a fileIndex; server will pick.
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
        // Prefer recommended (SxxExx match), then largest.
        files.sort((a, b) {
          if (a.recommended != b.recommended) return a.recommended ? -1 : 1;
          return b.sizeBytes.compareTo(a.sizeBytes);
        });
        final chosen = await showDialog<TorrentFileOption>(
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
    if (context.mounted) await _alert(context, friendlyRequestError(e));
    return null;
  }
}

Future<void> _alert(BuildContext context, String message) {
  return showDialog<void>(
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

class _BusyDialog extends StatelessWidget {
  const _BusyDialog({required this.label, this.onCancel});
  final String label;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      contentPadding: const EdgeInsets.fromLTRB(20, 8, 8, 20),
      content: SizedBox(
        width: 340,
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
            Padding(
              padding: EdgeInsets.fromLTRB(4, onCancel != null ? 0 : 12, 12, 4),
              child: Row(
                children: [
                  const SizedBox(
                    width: 28,
                    height: 28,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 16),
                  Expanded(child: Text(label, style: const TextStyle(fontSize: 16))),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ResultsDialog extends StatelessWidget {
  const _ResultsDialog({required this.sources, required this.languageLabel});
  final List<StreamSource> sources;
  final String languageLabel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final maxH = MediaQuery.sizeOf(context).height * 0.72;
    return AlertDialog(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      title: const Text('Choose a stream'),
      contentPadding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
      content: SizedBox(
        width: 560,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxH),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Showing $languageLabel — most seeded magnets first.',
                style: TextStyle(color: scheme.onSurfaceVariant, height: 1.35, fontSize: 13),
              ),
              const SizedBox(height: 12),
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: sources.length,
                  separatorBuilder: (_, i) => i == 0 && sources.length > 1
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
                      source: sources[i],
                      best: i == 0,
                      autofocus: i == 0,
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
  });

  final StreamSource source;
  final bool best;
  final bool autofocus;

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
          onTap: () => Navigator.pop(context, source),
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
                    const Spacer(),
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
                  '${source.size}  ·  ${source.seeders} seeders  ·  ${languageDisplayName(source.language)}',
                  style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13, height: 1.3),
                ),
                const SizedBox(height: 2),
                Text(
                  source.indexer,
                  style: TextStyle(color: scheme.onSurfaceVariant.withValues(alpha: 0.8), fontSize: 12),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
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
    default:
      return 'Low seeds';
  }
}

class _FilePickerDialog extends StatelessWidget {
  const _FilePickerDialog({required this.files});
  final List<TorrentFileOption> files;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final maxH = MediaQuery.sizeOf(context).height * 0.72;
    return AlertDialog(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      title: const Text('Choose a file'),
      contentPadding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
      content: SizedBox(
        width: 560,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxH),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'This torrent has multiple videos. Only the file you pick will download.',
                style: TextStyle(color: scheme.onSurfaceVariant, height: 1.35, fontSize: 13),
              ),
              const SizedBox(height: 12),
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
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
                          onTap: () => Navigator.pop(context, file),
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
