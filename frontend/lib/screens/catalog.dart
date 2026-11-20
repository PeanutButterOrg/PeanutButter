import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../friendly_error.dart';
import '../models.dart';
import '../providers/catalog.dart';
import '../providers/settings.dart';
import '../theme.dart';
import '../tv.dart';
import '../tv_nav.dart';
import '../design/tokens.g.dart';
import '../widgets/app_menu.dart';
import '../widgets/empty_state.dart';
import '../widgets/feature_card.dart';
import '../widgets/poster_card.dart';
import '../widgets/filter_bar.dart';
import '../widgets/local_overlay.dart';
import '../widgets/poster_grid.dart';
import '../widgets/tv_chrome.dart';

class CatalogScreen extends ConsumerStatefulWidget {
  const CatalogScreen({super.key, this.explore = false});

  /// The Explore tab: movies and series together, trending first.
  final bool explore;

  @override
  ConsumerState<CatalogScreen> createState() => _CatalogScreenState();
}

class _CatalogScreenState extends ConsumerState<CatalogScreen> {
  final ScrollController _scroll = ScrollController();
  final _year = FocusNode(debugLabel: 'header-year');
  final _rating = FocusNode(debugLabel: 'header-rating');
  final _genre = FocusNode(debugLabel: 'header-genre');
  final _favourites = FocusNode(debugLabel: 'header-favourites');
  final _watched = FocusNode(debugLabel: 'header-watched');
  final _search = FocusNode(debugLabel: 'header-search-btn');
  final _settings = FocusNode(debugLabel: 'header-settings');

  @override
  void dispose() {
    _scroll.dispose();
    _year.dispose();
    _rating.dispose();
    _genre.dispose();
    _favourites.dispose();
    _watched.dispose();
    _search.dispose();
    _settings.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    if (widget.explore) {
      // Start clean (See all may have left a kind or a rail behind).
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        const start = CatalogFilter(sort: 'TRENDING');
        final now = ref.read(catalogFilterProvider);
        if (now.kind != null || now.sort != 'TRENDING' || now.railLocked) {
          ref.read(catalogProvider.notifier).clearForNewView();
          ref.read(catalogFilterProvider.notifier).state = start;
        }
      });
    }
  }

  void _setFilter(CatalogFilter next) {
    ref.read(catalogFilterProvider.notifier).state = next;
  }

  @override
  Widget build(BuildContext context) {
    final catalog = ref.watch(catalogProvider);
    final filter = ref.watch(catalogFilterProvider);
    final selectedKind = ref.watch(selectedKindProvider);
    final kind = filter.kind ?? selectedKind;
    final info = ref.watch(serverInfoProvider).maybeWhen(data: (v) => v, orElse: () => null);
    final omdb = info?.omdbConfigured ?? false;
    final tmdb = info?.tmdbConfigured ?? false;
    final blocked = kindBlockedByMissingKeys(kind, omdbConfigured: omdb, tmdbConfigured: tmdb);

    final heading = widget.explore ? 'Explore' : catalogHeading(filter);
    ref.listen(catalogFilterProvider, (prev, next) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(0);
      }
    });
    final grid = blocked
        ? EmptyState(
            message: emptyKindMessage(kind: kind, omdbConfigured: omdb, tmdbConfigured: tmdb),
            onRefresh: () => refreshCatalogData(ref),
            showSettings: true,
          )
        : ClippedOverlay(child: _body(ref, catalog, omdb, tmdb, kind, filter));

    Widget filters({required bool tv}) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.explore && !tv) ...[
            AppMenuButton<String>(
              hint: 'Type',
              icon: Icons.layers_outlined,
              compact: true,
              value: filter.kind ?? 'ALL',
              entries: const [
                AppMenuEntry(value: 'ALL', label: 'Movies & series'),
                AppMenuEntry(value: 'MOVIE', label: 'Movies'),
                AppMenuEntry(value: 'SERIES', label: 'Series'),
              ],
              onSelected: (v) => _setFilter(
                v == 'ALL' ? filter.copyWith(clearKind: true) : filter.copyWith(kind: v),
              ),
            ),
            const SizedBox(width: 8),
          ],
          CatalogYearMenu(
            filter: filter,
            compact: true,
            focusNode: tv ? _year : null,
            onChanged: _setFilter,
          ),
          const SizedBox(width: 8),
          CatalogRatingMenu(
            filter: filter,
            compact: true,
            focusNode: tv ? _rating : null,
            onChanged: _setFilter,
          ),
          const SizedBox(width: 8),
          CatalogGenreMenu(
            filter: filter,
            compact: true,
            focusNode: tv ? _genre : null,
            onChanged: _setFilter,
          ),
          CatalogServiceMenu(
            filter: filter,
            kind: kind,
            compact: true,
            onChanged: _setFilter,
          ),
        ],
      );
    }

    Widget actions({required bool tv}) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          filters(tv: tv),
          const SizedBox(width: 8),
          if (tv) ...[
            TvHeaderButton(
              tooltip: 'Favourites',
              focusNode: _favourites,
              onPressed: () => context.push('/favourites'),
              onMoveLeft: () => _genre.requestFocus(),
              onMoveRight: () => _watched.requestFocus(),
              icon: const Icon(Icons.favorite_rounded),
            ),
            TvHeaderButton(
              tooltip: 'Watched',
              focusNode: _watched,
              onPressed: () => context.push('/watched'),
              onMoveLeft: () => _favourites.requestFocus(),
              onMoveRight: () => _search.requestFocus(),
              icon: const Icon(Icons.video_library_rounded),
            ),
            TvHeaderButton(
              tooltip: 'Search',
              focusNode: _search,
              onPressed: () => context.push('/search'),
              onMoveLeft: () => _watched.requestFocus(),
              onMoveRight: () => _settings.requestFocus(),
              icon: const Icon(Icons.search_rounded),
            ),
            TvHeaderButton(
              tooltip: 'Settings',
              focusNode: _settings,
              onPressed: () => context.push('/settings'),
              onMoveLeft: () => _search.requestFocus(),
              icon: const Icon(Icons.settings_outlined),
            ),
          ] else ...[
            IconButton(
              tooltip: 'Favourites',
              onPressed: () => context.push('/favourites'),
              icon: const Icon(Icons.favorite_rounded),
            ),
            IconButton(
              tooltip: 'Watched',
              onPressed: () => context.push('/watched'),
              icon: const Icon(Icons.video_library_rounded),
            ),
          ],
        ],
      );
    }

    if (!isAndroidTv) {
      return Scaffold(
        backgroundColor: PbColors.ground,
        body: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(PbSpace.gutterDesktop - 8, 14, PbSpace.gutterDesktop, 8),
                child: Row(
                  children: [
                    IconButton(
                      tooltip: 'Back',
                      // Opened straight from the address bar (web) there's nothing to go back to.
            onPressed: () => context.canPop() ? context.pop() : context.go('/'),
                      icon: const Icon(Icons.arrow_back_rounded, color: PbColors.text),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        heading,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: PbType.hero.copyWith(fontSize: 40, color: PbColors.text),
                      ),
                    ),
                    filters(tv: false),
                  ],
                ),
              ),
              Expanded(
                child: blocked
                    ? grid
                    : ClippedOverlay(child: _desktopBody(ref, catalog, omdb, tmdb, kind, filter, heading)),
              ),
            ],
          ),
        ),
      );
    }

    final homeHeader = Material(
      color: AppTheme.canvas,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 8, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  heading,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              actions(tv: true),
            ],
          ),
        ),
      ),
    );

    return Scaffold(
      body: TvNavHost(
        strategies: [
          TvNavBarStrategy(
            nodes: [_year, _rating, _genre, _favourites, _watched, _search, _settings],
            onMoveDown: () {
              // Drop into the first poster when leaving the filter bar.
            },
          ),
        ],
        child: TvBackScope(
          headerLive: true,
          headerFocus: _year,
          header: homeHeader,
          body: grid,
        ),
      ),
    );
  }

  /// Desktop / web: the #1 featured with the next three beside it, then the grid.
  Widget _desktopBody(
    WidgetRef ref,
    CatalogState catalog,
    bool omdb,
    bool tmdb,
    String kind,
    CatalogFilter filter,
    String heading,
  ) {
    if (catalog.items.isEmpty || catalog.error != null && catalog.items.isEmpty) {
      return _body(ref, catalog, omdb, tmdb, kind, filter);
    }
    final items = catalog.items;
    // Your own lists stay a plain grid; browse lists get the featured top.
    final personal = const {'CONTINUE_WATCHING', 'FAVORITES', 'WATCHED'}.contains(filter.sort);
    final featured = !personal && items.length >= 4;
    final done = !catalog.hasNextPage && !catalog.loadingMore && !catalog.loading;
    return PosterGrid(
      controller: _scroll,
      items: featured ? items.skip(4).toList() : items,
      sidePadding: PbSpace.gutterDesktop,
      loadingMore: catalog.loadingMore,
      onEndReached: () => ref.read(catalogProvider.notifier).loadMore(),
      headerSlivers: [
        if (featured)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(PbSpace.gutterDesktop, 8, PbSpace.gutterDesktop, 16),
            sliver: SliverToBoxAdapter(
              child: LayoutBuilder(
                builder: (context, box) {
                  final eyebrow = widget.explore ? '#1 trending' : '#1 in $heading';
                  if (box.maxWidth < 1000) {
                    return FeatureCard(item: items.first, eyebrow: eyebrow, height: 440);
                  }
                  // Posters at their own 2:3 shape; the featured card takes the
                  // rest (about 16:9 at this height), so no art is cut or stretched.
                  const gap = 14.0;
                  final poster = ((box.maxWidth - 3 * gap) / 5.6).clamp(150.0, 320.0);
                  final height = poster * 1.5;
                  return SizedBox(
                    height: height,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(child: FeatureCard(item: items.first, eyebrow: eyebrow, height: height)),
                        for (final item in items.skip(1).take(3)) ...[
                          const SizedBox(width: gap),
                          SizedBox(width: poster, child: PosterCard(item: item)),
                        ],
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
      ],
      footerSlivers: [
        if (done)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 24),
              child: Center(
                child: Text(
                  "That's everything in this category.",
                  style: PbType.meta.copyWith(color: PbColors.textMuted),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _body(
    WidgetRef ref,
    CatalogState catalog,
    bool omdb,
    bool tmdb,
    String kind,
    CatalogFilter filter,
  ) {
    if (catalog.loading && catalog.items.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (catalog.error != null && catalog.items.isEmpty) {
      return EmptyState(
        message: friendlyError(catalog.error!),
        onRefresh: () => refreshCatalogData(ref),
        showSettings: true,
      );
    }
    if (catalog.items.isEmpty) {
      return EmptyState(
        message: filter.sort == 'CONTINUE_WATCHING'
            ? 'Nothing in progress. Play a title, then it shows up here.'
            : emptyKindMessage(kind: kind, omdbConfigured: omdb, tmdbConfigured: tmdb),
        onRefresh: () => refreshCatalogData(ref),
        showSettings: true,
      );
    }
    return PosterGrid(
      controller: _scroll,
      items: catalog.items,
      loadingMore: catalog.loadingMore,
      onEndReached: () => ref.read(catalogProvider.notifier).loadMore(),
    );
  }
}
