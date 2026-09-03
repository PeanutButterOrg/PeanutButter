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
  });

  final StreamSession session;
  final String magnet;
  final bool localTorrent;
}

Future<List<StreamSource>> searchStreamingSources({
  required GraphQLClient client,
  required String title,
  required String kind,
  String? titleId,
  int? year,
  int? season,
  int? episode,
  String? language,
  bool? live,
}) async {
  final query = year == null ? title : '$title $year';
  final result = await client.query(
    QueryOptions(
      document: gql(STREAMING_SEARCH),
      fetchPolicy: FetchPolicy.networkOnly,
      variables: {
        'query': query,
        'kind': kind,
        'season': season,
        'episode': episode,
        'language': language,
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
  int? year,
  int? season,
  int? episode,
  String? language,
  bool resumePlayback = true,
}) async {
  final langName = languageDisplayName(language);
  if (!context.mounted) return null;
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const _BusyDialog(label: 'Looking up sources…'),
  );
  late final List<StreamSource> found;
  try {
    found = sourcesMatchingEpisode(
      await searchStreamingSources(
        client: client,
        title: title,
        kind: kind,
        titleId: titleId,
        year: year,
        season: season,
        episode: episode,
        language: language,
        live: true,
      ),
      season: season,
      episode: episode,
    );
  } catch (e) {
    if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
    if (context.mounted) await _alert(context, friendlyRequestError(e));
    return null;
  }
  if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
  if (!context.mounted) return null;
  if (found.isEmpty) {
    final scoped = language == null
        ? 'No healthy sources with enough seeders were found. Try again later, or check Jackett on the server console.'
        : 'No healthy sources were found for $langName. Add more languages in Settings, or choose All languages.';
    await _alert(context, scoped);
    return null;
  }

  final picked = await showDialog<StreamSource>(
    context: context,
    builder: (ctx) => _ResultsDialog(
      sources: found,
      languageLabel: language == null ? 'All languages' : langName,
    ),
  );
  if (picked == null || !context.mounted) return null;

  try {
    final started = await client.mutate(
      MutationOptions(
        document: gql(START_STREAM),
        variables: {
          'magnet': picked.magnet,
          'title': title,
          'titleId': titleId,
          'resume': resumePlayback,
          'seeders': picked.seeders,
          'peers': picked.peers,
          'season': season,
          'episode': episode,
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
    return StreamStart(session: session, magnet: picked.magnet);
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

class _BusyDialog extends StatelessWidget {
  const _BusyDialog({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      content: Row(
        children: [
          const SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 2)),
          const SizedBox(width: 16),
          Expanded(child: Text(label, style: const TextStyle(fontSize: 16))),
        ],
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
                'Sources for $languageLabel — healthiest magnets first.',
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
      // No Cancel button — back-press or tapping outside dismisses the dialog.
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
