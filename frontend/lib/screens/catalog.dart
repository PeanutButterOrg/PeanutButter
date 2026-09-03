import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../friendly_error.dart';
import '../models.dart';
import '../providers/catalog.dart';
import '../providers/settings.dart';
import '../theme.dart';
import '../tv.dart';
import '../widgets/empty_state.dart';
import '../widgets/filter_bar.dart';
import '../widgets/local_overlay.dart';
import '../widgets/poster_grid.dart';
import '../widgets/tv_chrome.dart';

class CatalogScreen extends ConsumerStatefulWidget {
  const CatalogScreen({super.key});

  @override
  ConsumerState<CatalogScreen> createState() => _CatalogScreenState();
}

class _CatalogScreenState extends ConsumerState<CatalogScreen> {
  final ScrollController _scroll = ScrollController();
  final _year = FocusNode(debugLabel: 'header-year');
  final _rating = FocusNode(debugLabel: 'header-rating');
  final _genre = FocusNode(debugLabel: 'header-genre');
  final _refresh = FocusNode(debugLabel: 'header-refresh');
  final _search = FocusNode(debugLabel: 'header-search-btn');
  final _settings = FocusNode(debugLabel: 'header-settings');

  @override
  void dispose() {
    _scroll.dispose();
    _year.dispose();
    _rating.dispose();
    _genre.dispose();
    _refresh.dispose();
    _search.dispose();
    _settings.dispose();
    super.dispose();
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
    final blocked = kindBlockedByMissingKeys(kind, omdbConfigured: omdb);

    final refreshing = ref.watch(refreshBusyProvider);
    final heading = catalogHeading(filter);
    ref.listen(catalogFilterProvider, (prev, next) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(0);
      }
    });
    final grid = blocked
        ? EmptyState(
            message: emptyKindMessage(kind: kind, omdbConfigured: omdb),
            onRefresh: () => refreshCatalogData(ref),
            showSettings: true,
          )
        : ClippedOverlay(child: _body(ref, catalog, omdb, kind, filter));

    Widget filters({required bool tv}) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
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
              tooltip: 'Refresh',
              focusNode: _refresh,
              busy: refreshing,
              onPressed: () => refreshCatalogData(ref),
              onMoveLeft: () => _genre.requestFocus(),
              onMoveRight: () => _search.requestFocus(),
              icon: const Icon(Icons.refresh_rounded),
            ),
            TvHeaderButton(
              tooltip: 'Search',
              focusNode: _search,
              onPressed: () => context.push('/search'),
              onMoveLeft: () => _refresh.requestFocus(),
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
          ] else
            IconButton(
              tooltip: 'Refresh',
              onPressed: refreshing ? null : () => refreshCatalogData(ref),
              icon: refreshing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh_rounded),
            ),
        ],
      );
    }

    if (!isAndroidTv) {
      return Scaffold(
        appBar: AppBar(
          title: Text(heading),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: actions(tv: false),
            ),
          ],
        ),
        body: grid,
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
      body: TvBackScope(
        headerLive: true,
        headerFocus: _year,
        header: homeHeader,
        body: grid,
      ),
    );
  }

  Widget _body(WidgetRef ref, CatalogState catalog, bool omdb, String kind, CatalogFilter filter) {
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
            : emptyKindMessage(kind: kind, omdbConfigured: omdb),
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
