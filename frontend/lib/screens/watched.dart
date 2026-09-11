import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../friendly_error.dart';
import '../models.dart';
import '../providers/catalog.dart';
import '../theme.dart';
import '../tv.dart';
import '../widgets/empty_state.dart';
import '../widgets/local_overlay.dart';
import '../widgets/poster_card.dart';
import '../widgets/tv_chrome.dart';
import 'home.dart' show FeaturedBanner;

/// Completed / watched titles — moved out of Continue watching when finished.
class WatchedScreen extends ConsumerWidget {
  const WatchedScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final feed = ref.watch(watchedFeedProvider);

    return Scaffold(
      backgroundColor: AppTheme.canvas,
      body: TvBackScope(
        overlapHeader: true,
        headerFocus: null,
        header: DecoratedBox(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Color(0xB30E0E12),
                Color(0x660E0E12),
                Color(0x000E0E12),
              ],
              stops: [0.0, 0.7, 1.0],
            ),
          ),
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
              child: Row(
                children: [
                  IconButton(
                    tooltip: 'Back',
                    onPressed: () {
                      if (context.canPop()) {
                        context.pop();
                      } else {
                        context.go('/');
                      }
                    },
                    icon: const Icon(Icons.arrow_back_rounded),
                  ),
                  Expanded(
                    child: Text(
                      'Watched',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                  ),
                  TvHeaderButton(
                    tooltip: 'Search',
                    onPressed: () => context.push('/search'),
                    icon: const Icon(Icons.search_rounded),
                  ),
                  TvHeaderButton(
                    tooltip: 'Settings',
                    onPressed: () => context.push('/settings'),
                    icon: const Icon(Icons.settings_outlined),
                  ),
                ],
              ),
            ),
          ),
        ),
        body: feed.when(
          skipLoadingOnReload: true,
          skipLoadingOnRefresh: true,
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => EmptyState(
            message: friendlyError(e),
            onRefresh: () async => ref.invalidate(watchedFeedProvider),
          ),
          data: (data) {
            if (data.isEmpty) {
              return const EmptyState(
                message:
                    'Nothing watched yet. Finish a movie or the last episode of a series and it shows up here.',
                showSettings: false,
              );
            }
            final bannerItems = <TitleItem>[
              ...data.movies,
              ...data.series,
              ...data.anime,
            ];
            return ClippedOverlay(
              child: ListView(
                cacheExtent: isAndroidTv ? 280 : 800,
                addAutomaticKeepAlives: false,
                physics: const ClampingScrollPhysics(),
                padding: EdgeInsets.only(
                  bottom: isAndroidTv ? tvCenterBottomPad(context) : 48,
                ),
                children: [
                  FeaturedBanner(
                    key: const ValueKey('watched-banner'),
                    items: bannerItems,
                  ),
                  _WatchedRow(title: 'Movies', items: data.movies),
                  _WatchedRow(title: 'Series', items: data.series),
                  _WatchedRow(title: 'Anime', items: data.anime),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _WatchedRow extends StatelessWidget {
  const _WatchedRow({required this.title, required this.items});

  final String title;
  final List<TitleItem> items;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    final tv = isAndroidTv;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Text(
              title,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
          ),
          SizedBox(
            height: tv ? TvPosterDim.rowHeight : 248,
            child: ListView.builder(
              clipBehavior: Clip.none,
              cacheExtent: tv ? 800 : 600,
              addAutomaticKeepAlives: true,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
              scrollDirection: Axis.horizontal,
              physics: const ClampingScrollPhysics(),
              itemExtent: tv ? TvPosterDim.extent : 168,
              itemCount: items.length,
              itemBuilder: (context, i) {
                final item = items[i];
                return Padding(
                  padding: EdgeInsets.only(right: tv ? TvPosterDim.gap : 12),
                  child: SizedBox(
                    width: tv ? TvPosterDim.width : 156,
                    child: PosterCard(item: item),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
