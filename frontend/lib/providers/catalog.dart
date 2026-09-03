import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:graphql_flutter/graphql_flutter.dart';

import '../graphql/client.dart';
import '../graphql/queries.dart';
import '../models.dart';
import '../tv.dart';
import '../widgets/cached_art.dart';
import 'settings.dart';

final selectedKindProvider = StateProvider<String>((ref) => 'MOVIE');

final catalogEpochProvider = StateProvider<int>((ref) => 0);

final refreshBusyProvider = StateProvider<bool>((ref) => false);

final catalogFilterProvider = StateProvider<CatalogFilter>((ref) {
  return const CatalogFilter(sort: 'TRENDING');
});

final homeFacetProvider = StateProvider<CatalogFilter>((ref) {
  return const CatalogFilter();
});

final browseFilterProvider = StateProvider.family<CatalogFilter, String>((ref, kind) {
  return CatalogFilter(kind: kind, sort: 'TRENDING');
});

class CatalogState {
  const CatalogState({
    this.items = const [],
    this.page = 1,
    this.hasNextPage = false,
    this.totalCount = 0,
    this.loading = false,
    this.loadingMore = false,
    this.error,
  });

  final List<TitleItem> items;
  final int page;
  final bool hasNextPage;
  final int totalCount;
  final bool loading;
  final bool loadingMore;
  final String? error;

  CatalogState copyWith({
    List<TitleItem>? items,
    int? page,
    bool? hasNextPage,
    int? totalCount,
    bool? loading,
    bool? loadingMore,
    String? error,
    bool clearError = false,
  }) {
    return CatalogState(
      items: items ?? this.items,
      page: page ?? this.page,
      hasNextPage: hasNextPage ?? this.hasNextPage,
      totalCount: totalCount ?? this.totalCount,
      loading: loading ?? this.loading,
      loadingMore: loadingMore ?? this.loadingMore,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class CatalogNotifier extends StateNotifier<CatalogState> {
  CatalogNotifier(this._ref, this.kind) : super(const CatalogState()) {
    refresh();
  }

  final Ref _ref;
  final String kind;
  Timer? _filterDebounce;

  Future<void> refresh() async {
    state = state.copyWith(loading: true, clearError: true);
    await _load(page: 1, replace: true);
  }

  void scheduleRefresh() {
    _filterDebounce?.cancel();
    _filterDebounce = Timer(const Duration(milliseconds: 280), refresh);
  }

  Future<void> loadMore() async {
    if (!state.hasNextPage || state.loadingMore || state.loading) return;
    state = state.copyWith(loadingMore: true);
    await _load(page: state.page + 1, replace: false);
  }

  @override
  void dispose() {
    _filterDebounce?.cancel();
    super.dispose();
  }

  Future<void> _load({required int page, required bool replace}) async {
    final client = _ref.read(graphQLClientProvider);
    final filter = _ref.read(browseFilterProvider(kind));
    try {
      final result = await client.query(
        QueryOptions(
          document: gql(GET_CATALOG),
          variables: filter.toVariables(page: page, perPage: 32),
          fetchPolicy: replace ? FetchPolicy.networkOnly : catalogFetchPolicy,
        ),
      );
      if (result.hasException) {
        state = state.copyWith(
          loading: false,
          loadingMore: false,
          error: result.exception.toString(),
        );
        return;
      }
      final conn = result.data?['catalog'] as Map<String, dynamic>?;
      if (conn == null) {
        state = state.copyWith(loading: false, loadingMore: false, error: 'Empty catalog response');
        return;
      }
      final items = ((conn['items'] as List?) ?? const [])
          .map((e) => TitleItem.fromJson(e as Map<String, dynamic>))
          .toList();
      if (!isAndroidTv) unawaited(ArtCache.prefetch(items.take(12)));
      state = state.copyWith(
        items: replace ? items : [...state.items, ...items],
        page: conn['page'] as int? ?? page,
        hasNextPage: conn['hasNextPage'] as bool? ?? false,
        totalCount: conn['totalCount'] as int? ?? items.length,
        loading: false,
        loadingMore: false,
        clearError: true,
      );
    } catch (e) {
      state = state.copyWith(loading: false, loadingMore: false, error: e.toString());
    }
  }
}

final browseProvider = StateNotifierProvider.family<CatalogNotifier, CatalogState, String>((ref, kind) {
  ref.watch(graphQLClientProvider);
  final notifier = CatalogNotifier(ref, kind);
  ref.listen<CatalogFilter>(browseFilterProvider(kind), (_, __) {
    notifier.scheduleRefresh();
  });
  return notifier;
});

class LibraryNotifier extends StateNotifier<CatalogState> {
  LibraryNotifier(this._ref) : super(const CatalogState()) {
    refresh();
  }

  final Ref _ref;
  Timer? _filterDebounce;

  Future<void> refresh() async {
    state = state.copyWith(loading: true, clearError: true);
    await _load(page: 1, replace: true);
  }

  void scheduleRefresh() {
    _filterDebounce?.cancel();
    _filterDebounce = Timer(const Duration(milliseconds: 280), refresh);
  }

  Future<void> loadMore() async {
    if (!state.hasNextPage || state.loadingMore || state.loading) return;
    state = state.copyWith(loadingMore: true);
    await _load(page: state.page + 1, replace: false);
  }

  @override
  void dispose() {
    _filterDebounce?.cancel();
    super.dispose();
  }

  Future<void> _load({required int page, required bool replace}) async {
    final client = _ref.read(graphQLClientProvider);
    final filter = _ref.read(catalogFilterProvider);
    try {
      final result = await client.query(
        QueryOptions(
          document: gql(GET_CATALOG),
          variables: filter.toVariables(page: page, perPage: 32),
          fetchPolicy: replace ? FetchPolicy.networkOnly : catalogFetchPolicy,
        ),
      );
      if (result.hasException) {
        state = state.copyWith(
          loading: false,
          loadingMore: false,
          error: result.exception.toString(),
        );
        return;
      }
      final conn = result.data?['catalog'] as Map<String, dynamic>?;
      if (conn == null) {
        state = state.copyWith(loading: false, loadingMore: false, error: 'Empty catalog response');
        return;
      }
      final items = ((conn['items'] as List?) ?? const [])
          .map((e) => TitleItem.fromJson(e as Map<String, dynamic>))
          .toList();
      if (!isAndroidTv) unawaited(ArtCache.prefetch(items.take(12)));
      state = state.copyWith(
        items: replace ? items : [...state.items, ...items],
        page: conn['page'] as int? ?? page,
        hasNextPage: conn['hasNextPage'] as bool? ?? false,
        totalCount: conn['totalCount'] as int? ?? items.length,
        loading: false,
        loadingMore: false,
        clearError: true,
      );
    } catch (e) {
      state = state.copyWith(loading: false, loadingMore: false, error: e.toString());
    }
  }
}

final catalogProvider = StateNotifierProvider<LibraryNotifier, CatalogState>((ref) {
  ref.watch(graphQLClientProvider);
  final notifier = LibraryNotifier(ref);
  ref.listen<CatalogFilter>(catalogFilterProvider, (_, __) {
    notifier.scheduleRefresh();
  });
  return notifier;
});

void invalidatePlaybackProgress(WidgetRef ref, {String? titleId}) {
  ref.invalidate(homeFeedProvider('MOVIE'));
  ref.invalidate(homeFeedProvider('SERIES'));
  ref.invalidate(homeFeedProvider('ANIME'));
  ref.invalidate(catalogProvider);
  if (titleId != null && titleId.isNotEmpty) {
    ref.invalidate(detailProvider(titleId));
  }
}

class HomeFeed {
  const HomeFeed({
    required this.trending,
    required this.popular,
    required this.recent,
    this.continueWatching = const [],
  });

  final List<TitleItem> trending;
  final List<TitleItem> popular;
  final List<TitleItem> recent;
  final List<TitleItem> continueWatching;
}

final homeFeedProvider = FutureProvider.family<HomeFeed, String>((ref, kind) async {
  ref.watch(graphQLClientProvider);
  ref.watch(catalogEpochProvider);
  final client = ref.read(graphQLClientProvider);
  final result = await client
      .query(
        QueryOptions(
          document: gql(GET_HOME_FEED),
          variables: {'kind': kind},
          fetchPolicy: FetchPolicy.networkOnly,
        ),
      )
      .timeout(const Duration(seconds: 30));
  if (result.hasException) {
    throw result.exception!;
  }
  final json = result.data?['homeFeed'] as Map<String, dynamic>? ?? const {};
  List<TitleItem> row(String key) {
    final items = (json[key] as List?) ?? const [];
    return items.map((e) => TitleItem.fromJson(e as Map<String, dynamic>)).toList();
  }
  final feed = HomeFeed(
    trending: row('trending'),
    popular: row('popular'),
    recent: row('recent'),
    continueWatching: row('continueWatching'),
  );
  if (!isAndroidTv) {
    unawaited(ArtCache.prefetch(feed.trending.take(8)));
    unawaited(ArtCache.prefetch([...feed.popular.take(12), ...feed.recent.take(12), ...feed.continueWatching]));
  }
  return feed;
});

/// Prefetches the other catalogs in the background after home is shown.
final catalogWarmupProvider = FutureProvider<void>((ref) async {
  if (isAndroidTv) return;
  ref.watch(graphQLClientProvider);
  final connected = ref.watch(settingsProvider.select((s) => s.connected));
  if (!connected) return;
  final kind = ref.read(selectedKindProvider);
  await Future<void>.delayed(const Duration(milliseconds: 500));
  for (final other in const ['MOVIE', 'SERIES', 'ANIME']) {
    if (other == kind) continue;
    try {
      await ref.read(homeFeedProvider(other).future);
    } catch (_) {}
  }
});

final genresProvider = FutureProvider<List<String>>((ref) async {
  final client = ref.watch(graphQLClientProvider);
  final result = await client.query(
    QueryOptions(document: gql(GET_GENRES), fetchPolicy: FetchPolicy.cacheFirst),
  );
  if (result.hasException) return const [];
  return ((result.data?['genres'] as List?) ?? const []).map((e) => e.toString()).toList();
});

final detailProvider = FutureProvider.family<TitleItem?, String>((ref, id) async {
  final client = ref.watch(graphQLClientProvider);
  final result = await client.query(
    QueryOptions(
      document: gql(GET_TITLE),
      variables: {'id': id},
      fetchPolicy: FetchPolicy.networkOnly,
    ),
  );
  if (result.hasException) {
    throw result.exception!;
  }
  final json = result.data?['title'] as Map<String, dynamic>?;
  if (json == null) return null;
  final item = TitleItem.fromJson(json);
  if (!isAndroidTv) await ArtCache.prefetch([item]);
  return item;
});

class SearchState {
  const SearchState({
    this.query = '',
    this.kind,
    this.genre,
    this.yearMin = 1900,
    this.yearMax,
    this.ratingMin = 0,
    this.sort = 'TRENDING',
    this.results = const [],
    this.recent = const [],
    this.loading = false,
    this.loadingMore = false,
    this.hasNextPage = false,
    this.page = 1,
    this.error,
  });

  final String query;
  final String? kind;
  final String? genre;
  final int yearMin;
  final int? yearMax;
  final double ratingMin;
  final String sort;
  final List<TitleItem> results;
  final List<String> recent;
  final bool loading;
  final bool loadingMore;
  final bool hasNextPage;
  final int page;
  final String? error;

  CatalogFilter get facets => CatalogFilter(
        kind: kind,
        genre: genre,
        yearMin: yearMin,
        yearMax: yearMax,
        ratingMin: ratingMin,
        sort: sort,
      );
}

class SearchNotifier extends StateNotifier<SearchState> {
  SearchNotifier(this._ref) : super(SearchState(kind: _ref.read(selectedKindProvider)));

  final Ref _ref;
  Timer? _debounce;

  void onQueryChanged(String value) {
    _debounce?.cancel();
    state = state.copyWith(query: value);
    if (value.trim().isEmpty) {
      state = SearchState(
        query: value,
        kind: state.kind,
        genre: state.genre,
        yearMin: state.yearMin,
        yearMax: state.yearMax,
        ratingMin: state.ratingMin,
        sort: state.sort,
        recent: state.recent,
      );
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 320), () {
      _run(value.trim(), page: 1, replace: true);
    });
  }

  void setKind(String? kind) {
    state = state.copyWith(kind: kind, clearKind: kind == null);
    if (state.query.trim().isNotEmpty) {
      _run(state.query.trim(), page: 1, replace: true);
    }
  }

  void setFacets(CatalogFilter facets) {
    state = state.copyWith(
      genre: facets.genre,
      yearMin: facets.yearMin,
      yearMax: facets.yearMax,
      ratingMin: facets.ratingMin,
      clearGenre: facets.genre == null,
      clearYearMax: facets.yearMax == null,
    );
    if (state.query.trim().isNotEmpty) {
      _run(state.query.trim(), page: 1, replace: true);
    }
  }

  void setGenre(String? genre) {
    setFacets(state.facets.copyWith(genre: genre, clearGenre: genre == null));
  }

  void setSort(String sort) {
    state = state.copyWith(sort: sort, results: _sortItems(state.results, sort));
  }

  Future<void> loadMore() async {
    if (!state.hasNextPage || state.loadingMore || state.loading || state.query.trim().isEmpty) {
      return;
    }
    await _run(state.query.trim(), page: state.page + 1, replace: false);
  }

  Future<void> _run(String query, {required int page, required bool replace}) async {
    state = state.copyWith(loading: replace, loadingMore: !replace, error: null, clearError: true);
    final client = _ref.read(graphQLClientProvider);
    try {
      final result = await client.query(
        QueryOptions(
          document: gql(SEARCH_TITLES),
          variables: {
            'query': query,
            'kind': state.kind,
            'page': page,
            'perPage': 32,
          },
          fetchPolicy: searchFetchPolicy,
        ),
      );
      if (result.hasException) {
        state = state.copyWith(
          loading: false,
          loadingMore: false,
          error: result.exception.toString(),
          recent: _pushRecent(query),
        );
        return;
      }
      final search = result.data?['search'] as Map<String, dynamic>? ?? const {};
      var items = ((search['items'] as List?) ?? const [])
          .map((e) => TitleItem.fromJson(e as Map<String, dynamic>))
          .where(state.facets.matches)
          .toList();
      items = _sortItems(items, state.sort);
      if (!isAndroidTv) unawaited(ArtCache.prefetch(items.take(12)));
      state = state.copyWith(
        query: query,
        results: replace ? items : _sortItems([...state.results, ...items], state.sort),
        recent: _pushRecent(query),
        loading: false,
        loadingMore: false,
        hasNextPage: search['hasNextPage'] as bool? ?? false,
        page: search['page'] as int? ?? page,
        clearError: true,
      );
    } catch (e) {
      state = state.copyWith(query: query, recent: _pushRecent(query), loading: false, error: e.toString());
    }
  }

  List<TitleItem> _sortItems(List<TitleItem> items, String sort) {
    final next = [...items];
    int cmp<T extends Comparable>(T? a, T? b) {
      if (a == null && b == null) return 0;
      if (a == null) return 1;
      if (b == null) return -1;
      return b.compareTo(a);
    }

    switch (sort) {
      case 'ROTTEN_TOMATOES':
        next.sort((a, b) => cmp(a.rtScore, b.rtScore));
      case 'RATING':
        next.sort((a, b) => cmp(a.displayRating, b.displayRating));
      case 'YEAR':
        next.sort((a, b) => cmp(a.year, b.year));
      case 'TITLE':
        next.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
      default:
        break;
    }
    return next;
  }

  List<String> _pushRecent(String query) {
    final next = [query, ...state.recent.where((e) => e != query)];
    return next.take(8).toList();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }
}

extension on SearchState {
  SearchState copyWith({
    String? query,
    String? kind,
    String? genre,
    int? yearMin,
    int? yearMax,
    double? ratingMin,
    String? sort,
    List<TitleItem>? results,
    List<String>? recent,
    bool? loading,
    bool? loadingMore,
    bool? hasNextPage,
    int? page,
    String? error,
    bool clearKind = false,
    bool clearGenre = false,
    bool clearYearMax = false,
    bool clearError = false,
  }) {
    return SearchState(
      query: query ?? this.query,
      kind: clearKind ? null : (kind ?? this.kind),
      genre: clearGenre ? null : (genre ?? this.genre),
      yearMin: yearMin ?? this.yearMin,
      yearMax: clearYearMax ? null : (yearMax ?? this.yearMax),
      ratingMin: ratingMin ?? this.ratingMin,
      sort: sort ?? this.sort,
      results: results ?? this.results,
      recent: recent ?? this.recent,
      loading: loading ?? this.loading,
      loadingMore: loadingMore ?? this.loadingMore,
      hasNextPage: hasNextPage ?? this.hasNextPage,
      page: page ?? this.page,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

final searchProvider = StateNotifierProvider<SearchNotifier, SearchState>((ref) {
  return SearchNotifier(ref);
});

final syncProvider = StateNotifierProvider<SyncNotifier, AsyncValue<String?>>((ref) {
  return SyncNotifier(ref);
});

class SyncNotifier extends StateNotifier<AsyncValue<String?>> {
  SyncNotifier(this._ref) : super(const AsyncData(null));

  final Ref _ref;

  Future<void> trigger() async {
    state = const AsyncLoading();
    final client = _ref.read(graphQLClientProvider);
    try {
      final result = await client.mutate(
        MutationOptions(document: gql(TRIGGER_SYNC)),
      );
      if (result.hasException) {
        state = AsyncError(result.exception!, StackTrace.current);
        return;
      }
      final message = result.data?['triggerSync']?['message'] as String? ?? 'Sync started';
      state = AsyncData(message);
      _ref.invalidate(serverInfoProvider);
    } catch (e, st) {
      state = AsyncError(e, st);
    }
  }
}

/// Reloads catalog data from the server and starts a metadata sync.
Future<void> refreshCatalogData(WidgetRef ref) async {
  if (ref.read(refreshBusyProvider)) return;
  ref.read(refreshBusyProvider.notifier).state = true;
  try {
    await ref.read(syncProvider.notifier).trigger();
    final client = ref.read(graphQLClientProvider);
    client.cache.store.reset();
    ref.read(catalogEpochProvider.notifier).state = ref.read(catalogEpochProvider) + 1;
    ref.invalidate(serverInfoProvider);
    ref.invalidate(homeFeedProvider('MOVIE'));
    ref.invalidate(homeFeedProvider('SERIES'));
    ref.invalidate(homeFeedProvider('ANIME'));
    ref.invalidate(catalogWarmupProvider);
    ref.invalidate(genresProvider);
    await ref.read(catalogProvider.notifier).refresh();
    final kind = ref.read(selectedKindProvider);
    await ref.read(homeFeedProvider(kind).future);
  } finally {
    ref.read(refreshBusyProvider.notifier).state = false;
  }
}
