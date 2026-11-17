import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:graphql_flutter/graphql_flutter.dart';

import '../design/tokens.g.dart';
import '../graphql/queries.dart';
import '../models.dart';
import '../providers/catalog.dart';
import '../providers/settings.dart';
import '../window_layout.dart';
import 'cached_art.dart';
import 'title_meta.dart';

/// A featured title, big: art, eyebrow, name, Play / My List / More info.
/// Search's top result and the #1 on See all pages.
class FeatureCard extends ConsumerStatefulWidget {
  const FeatureCard({super.key, required this.item, required this.eyebrow, this.height});

  final TitleItem item;
  final String eyebrow;
  /// Fixed height; null scales with the width so the artwork shows well.
  final double? height;

  @override
  ConsumerState<FeatureCard> createState() => _FeatureCardState();
}

class _FeatureCardState extends ConsumerState<FeatureCard> {
  bool? _listed;

  Future<void> _toggleList() async {
    final next = !(_listed ?? widget.item.userState?.favorite == true);
    setState(() => _listed = next);
    try {
      await ref.read(graphQLClientProvider).mutate(
            MutationOptions(document: gql(SET_FAVORITE), variables: {'titleId': widget.item.id, 'favorite': next}),
          );
      ref.invalidate(favoritesFeedProvider);
    } catch (_) {
      if (mounted) setState(() => _listed = !next);
    }
  }

  @override
  void didUpdateWidget(covariant FeatureCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.id != widget.item.id) _listed = null;
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final listed = _listed ?? item.userState?.favorite == true;
    return LayoutBuilder(
      builder: (context, box) {
        final height = widget.height ?? (box.maxWidth * 0.42).clamp(400.0, 620.0);
        return _card(item, listed, height);
      },
    );
  }

  Widget _card(TitleItem item, bool listed, double height) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(PbRadius.panel + 4),
      child: SizedBox(
        height: height,
        child: Stack(
          fit: StackFit.expand,
          children: [
            const ColoredBox(color: PbColors.surface),
            CachedArt(
              url: bestBannerUrl(backdropUrl: item.backdropUrl, thumbUrl: item.thumbUrl, posterUrl: item.posterUrl),
              memCacheWidth: 1920,
              // Faces and titles sit high in backdrops.
              alignment: const Alignment(0, -0.3),
            ),
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [Color(0xF50E0E12), Color(0xB30E0E12), Color(0x000E0E12)],
                  stops: [0, 0.4, 0.75],
                ),
              ),
            ),
            Positioned(
              left: 28,
              bottom: 28,
              right: 28,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(widget.eyebrow.toUpperCase(), style: PbType.label.copyWith(color: PbColors.primary, letterSpacing: 1.1)),
                  const SizedBox(height: 6),
                  Text(item.title, maxLines: 2, overflow: TextOverflow.ellipsis,
                      style: PbType.h1.copyWith(color: PbColors.text, fontSize: 36, height: 1.05)),
                  const SizedBox(height: 10),
                  TitleMetaRow(item: item, maxGenres: 2),
                  if ((item.synopsis ?? '').isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Text(item.synopsis!, maxLines: 2, overflow: TextOverflow.ellipsis,
                        style: PbType.body.copyWith(color: const Color(0xFFD6DAE3), height: 1.45)),
                  ],
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 10,
                    children: [
                      FilledButton.icon(
                        onPressed: () => context.push('/title/${item.id}?play=1'),
                        style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
                        icon: const Icon(Icons.play_arrow_rounded),
                        label: const Text('Play'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _toggleList,
                        style: OutlinedButton.styleFrom(minimumSize: const Size(0, 40)),
                        icon: Icon(listed ? Icons.check_rounded : Icons.add_rounded),
                        label: const Text('My List'),
                      ),
                      OutlinedButton.icon(
                        onPressed: () => context.push('/title/${item.id}'),
                        style: OutlinedButton.styleFrom(minimumSize: const Size(0, 40)),
                        icon: const Icon(Icons.info_outline_rounded),
                        label: const Text('More info'),
                      ),
                    ],
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
