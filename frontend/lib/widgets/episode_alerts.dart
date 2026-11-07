import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:graphql_flutter/graphql_flutter.dart';

import '../graphql/client.dart';
import '../graphql/queries.dart';

/// A new episode of a series this device follows ("Notify me").
class EpisodeAlert {
  const EpisodeAlert({
    required this.episodeId,
    required this.titleId,
    required this.title,
    required this.season,
    required this.episode,
    this.episodeName,
  });

  final String episodeId;
  final String titleId;
  final String title;
  final int season;
  final int episode;
  final String? episodeName;

  String get label {
    final code = 'S${season.toString().padLeft(2, '0')}E${episode.toString().padLeft(2, '0')}';
    final name = episodeName?.trim() ?? '';
    return name.isEmpty ? code : '$code · $name';
  }

  static EpisodeAlert? fromJson(Map<String, dynamic> j) {
    final id = j['episodeId'] as String?;
    final titleId = j['titleId'] as String?;
    if (id == null || titleId == null) return null;
    return EpisodeAlert(
      episodeId: id,
      titleId: titleId,
      title: j['title'] as String? ?? '',
      season: (j['seasonNumber'] as num?)?.toInt() ?? 0,
      episode: (j['episodeNumber'] as num?)?.toInt() ?? 0,
      episodeName: j['episodeName'] as String?,
    );
  }
}

/// Whether this device follows a series; null on servers without the feature.
final followingProvider = FutureProvider.autoDispose.family<bool?, String>((ref, titleId) async {
  final result = await ref.read(graphQLClientProvider).query(
        QueryOptions(
          document: gql(FOLLOWING),
          variables: {'id': titleId},
          fetchPolicy: FetchPolicy.noCache,
        ),
      );
  if (result.hasException) return null;
  return (result.data?['title'] as Map<String, dynamic>?)?['following'] as bool?;
});

/// "Notify me" on a series page: alerts for episodes that air from now on.
class FollowButton extends ConsumerStatefulWidget {
  const FollowButton({super.key, required this.titleId});

  final String titleId;

  @override
  ConsumerState<FollowButton> createState() => _FollowButtonState();
}

class _FollowButtonState extends ConsumerState<FollowButton> {
  bool? _optimistic;

  Future<void> _toggle(bool current) async {
    final next = !current;
    setState(() => _optimistic = next);
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      final result = await ref.read(graphQLClientProvider).mutate(
            MutationOptions(
              document: gql(SET_FOLLOW),
              variables: {'titleId': widget.titleId, 'follow': next},
            ),
          );
      if (result.hasException) throw result.exception!;
      messenger?.showSnackBar(SnackBar(
        content: Text(next
            ? "You'll be told here when a new episode is out."
            : 'New episode alerts off.'),
      ));
    } catch (_) {
      if (mounted) setState(() => _optimistic = current);
    }
  }

  @override
  Widget build(BuildContext context) {
    final server = ref.watch(followingProvider(widget.titleId)).valueOrNull;
    // Hidden until known, and on servers that don't support it.
    if (server == null && _optimistic == null) return const SizedBox.shrink();
    final following = _optimistic ?? server ?? false;
    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: IconButton.filledTonal(
        tooltip: following ? 'Stop new episode alerts' : 'Notify me of new episodes',
        onPressed: () => _toggle(following),
        icon: Icon(following ? Icons.notifications_active : Icons.notifications_none),
      ),
    );
  }
}

/// Shows new episodes of followed series once, as a message with a link to
/// the series, then marks them delivered. Wraps the home screen.
class EpisodeAlertsListener extends ConsumerStatefulWidget {
  const EpisodeAlertsListener({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<EpisodeAlertsListener> createState() => _EpisodeAlertsListenerState();
}

class _EpisodeAlertsListenerState extends ConsumerState<EpisodeAlertsListener> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_check()));
  }

  Future<void> _check() async {
    final client = ref.read(graphQLClientProvider);
    final result = await client.query(
      QueryOptions(document: gql(EPISODE_ALERTS), fetchPolicy: FetchPolicy.noCache),
    );
    if (!mounted || result.hasException) return;
    final alerts = [
      for (final j in (result.data?['episodeAlerts'] as List? ?? const []).whereType<Map<String, dynamic>>())
        EpisodeAlert.fromJson(j),
    ].whereType<EpisodeAlert>().toList();
    if (alerts.isEmpty) return;
    final first = alerts.first;
    final text = alerts.length == 1
        ? 'New episode of ${first.title}: ${first.label}'
        : '${alerts.length} new episodes, including ${first.title} ${first.label}';
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
      duration: const Duration(seconds: 8),
      content: Text(text),
      action: SnackBarAction(
        label: 'Open',
        onPressed: () => context.push('/title/${first.titleId}'),
      ),
    ));
    await client.mutate(MutationOptions(
      document: gql(MARK_ALERTS_DELIVERED),
      variables: {'ids': [for (final a in alerts) a.episodeId]},
    ));
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
