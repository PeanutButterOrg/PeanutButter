import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../design/tokens.g.dart';

import '../friendly_error.dart';
import '../models.dart';
import '../providers/catalog.dart';
import '../theme.dart';
import '../tv.dart';
import '../tv_nav.dart';
import '../widgets/empty_state.dart';
import '../widgets/feature_card.dart';
import '../widgets/filter_bar.dart';
import '../widgets/poster_grid.dart';
import '../widgets/tv_chrome.dart';
import '../widgets/tv_text_field.dart';

class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _controller = TextEditingController();
  final _movies = FocusNode(debugLabel: 'header-movies');
  final _series = FocusNode(debugLabel: 'header-series');
  final _favourites = FocusNode(debugLabel: 'header-favourites');
  final _searchBtn = FocusNode(debugLabel: 'header-search-btn');
  final _settings = FocusNode(debugLabel: 'header-settings');
  final _fieldChrome = FocusNode(debugLabel: 'header-search');
  final _firstResult = FocusNode(debugLabel: 'poster');
  final _fieldKey = GlobalKey<TvTextFieldState>();

  List<FocusNode> get _barNodes => [
        _movies,
        _series,
        _fieldChrome,
        _favourites,
        _searchBtn,
        _settings,
      ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // Movies or Series: only the chosen kind is searched.
      final kind = ref.read(selectedKindProvider);
      ref.read(searchProvider.notifier).setKind(kind == 'SERIES' ? 'SERIES' : 'MOVIE');
      if (isAndroidTv) {
        // Focus the search field chrome (Select opens the keyboard).
        _fieldKey.currentState?.focusChrome();
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _movies.dispose();
    _series.dispose();
    _favourites.dispose();
    _searchBtn.dispose();
    _settings.dispose();
    _fieldChrome.dispose();
    _firstResult.dispose();
    super.dispose();
  }

  void _setKind(String value) {
    ref.read(selectedKindProvider.notifier).state = value;
    ref.read(searchProvider.notifier).setKind(value);
  }

  void _openField() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _fieldKey.currentState?.focusAndEdit();
    });
  }

  void _focusSearchBar() {
    _fieldKey.currentState?.focusChrome();
    if (_fieldChrome.canRequestFocus) _fieldChrome.requestFocus();
  }

  void _focusResults({int attempt = 0}) {
    _fieldKey.currentState?.endEdit();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_firstResult.canRequestFocus) {
        _firstResult.requestFocus();
        final ctx = _firstResult.context;
        if (ctx != null) tvEnsureVisible(ctx, alignment: 0.2, belowHeader: true);
        return;
      }
      final scope = FocusScope.of(context);
      for (final node in scope.traversalDescendants) {
        if (node.debugLabel == 'poster' && node.canRequestFocus) {
          node.requestFocus();
          final ctx = node.context;
          if (ctx != null) tvEnsureVisible(ctx, alignment: 0.2, belowHeader: true);
          return;
        }
      }
      if (attempt < 12) {
        Future<void>.delayed(const Duration(milliseconds: 60), () {
          if (mounted) _focusResults(attempt: attempt + 1);
        });
      } else {
        // No results yet — stay on / return to the search field.
        _focusSearchBar();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final search = ref.watch(searchProvider);
    final selectedKind = ref.watch(selectedKindProvider);
    final String kind = search.kind ?? selectedKind;
    final tv = isAndroidTv;

    final field = TvTextField(
      key: _fieldKey,
      controller: _controller,
      chromeFocus: _fieldChrome,
      autofocus: false,
      enterEditing: false,
      pill: tv,
      debugLabel: 'header-search',
      textInputAction: TextInputAction.search,
      onMoveDown: tv ? () => _focusResults() : null,
      onMoveLeft: tv ? () => _series.requestFocus() : null,
      onMoveRight: tv ? () => _favourites.requestFocus() : null,
      onChanged: (v) => ref.read(searchProvider.notifier).onQueryChanged(v),
      onSubmitted: (v) {
        ref.read(searchProvider.notifier).onQueryChanged(v);
        if (tv) _focusResults();
      },
      decoration: InputDecoration(
        hintText: searchHint(kind),
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        prefixIcon: const Icon(Icons.search_rounded),
        suffixIcon: search.query.isEmpty
            ? null
            : IconButton(
                tooltip: 'Clear',
                onPressed: () {
                  _controller.clear();
                  ref.read(searchProvider.notifier).onQueryChanged('');
                  if (tv) _focusSearchBar();
                },
                icon: const Icon(Icons.close_rounded),
              ),
      ),
    );

    Widget actions() {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          TvHeaderButton(
            tooltip: 'Favourites',
            focusNode: tv ? _favourites : null,
            onPressed: () => context.push('/favourites'),
            onMoveLeft: tv ? _focusSearchBar : null,
            onMoveRight: tv ? () => _searchBtn.requestFocus() : null,
            onMoveDown: tv ? () => _focusResults() : null,
            icon: const Icon(Icons.favorite_rounded),
          ),
          TvHeaderButton(
            tooltip: 'Search',
            focusNode: tv ? _searchBtn : null,
            onPressed: _openField,
            onMoveLeft: tv ? () => _favourites.requestFocus() : null,
            onMoveRight: tv ? () => _settings.requestFocus() : null,
            onMoveDown: tv ? () => _focusResults() : null,
            icon: const Icon(Icons.search_rounded),
          ),
          TvHeaderButton(
            tooltip: 'Settings',
            focusNode: tv ? _settings : null,
            onPressed: () => context.push('/settings'),
            onMoveLeft: tv ? () => _searchBtn.requestFocus() : null,
            onMoveDown: tv ? () => _focusResults() : null,
            icon: const Icon(Icons.settings_outlined),
          ),
        ],
      );
    }

    final homeHeader = Material(
      color: AppTheme.canvas,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      child: SafeArea(
        bottom: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 8, 0),
              child: Row(
                  children: [
                    if (!tv)
                      IconButton(
                        tooltip: 'Back',
                        // Opened straight from the address bar (web) there's nothing to go back to.
            onPressed: () => context.canPop() ? context.pop() : context.go('/'),
                        icon: const Icon(Icons.arrow_back_rounded),
                      ),
                    KindSwitch(
                      kind: kind == 'ANIME' ? 'MOVIE' : kind,
                      moviesFocus: _movies,
                      seriesFocus: _series,
                      onMoveTrailing: tv ? _focusSearchBar : null,
                      onMoveDown: tv ? () => _focusResults() : null,
                      onChanged: _setKind,
                    ),
                    const SizedBox(width: 12),
                    Expanded(child: field),
                    actions(),
                  ],
                ),
            ),
          ],
        ),
      ),
    );

    final body = Stack(
      children: [
        Positioned.fill(child: _body(search, kind)),
        if (search.loading && search.results.isEmpty)
          const Positioned.fill(
            child: Center(
              child: CircularProgressIndicator(),
            ),
          ),
      ],
    );

    if (!tv) {
      return Scaffold(
        backgroundColor: PbColors.ground,
        body: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _SearchBar(
                controller: _controller,
                query: search.query,
                kind: search.kind ?? 'MOVIE',
                onKind: _setKind,
                onChanged: (v) => ref.read(searchProvider.notifier).onQueryChanged(v),
                onClear: () {
                  _controller.clear();
                  ref.read(searchProvider.notifier).onQueryChanged('');
                },
              ),
              Expanded(
                child: Stack(
                  children: [
                    Positioned.fill(child: _desktopBody(search)),
                    if (search.loading && search.results.isEmpty)
                      const Positioned.fill(child: Center(child: CircularProgressIndicator())),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      body: TvNavHost(
        strategies: [
          TvNavBarStrategy(
            nodes: _barNodes,
            onMoveDown: () => _focusResults(),
          ),
          TvNavGridStrategy(onMoveUp: _focusSearchBar),
        ],
        child: TvBackScope(
          popOnFirstBack: true,
          headerLive: true,
          headerFocus: _fieldChrome,
          header: homeHeader,
          body: body,
        ),
      ),
    );
  }

  void _pick(String picked) {
    _controller.text = picked;
    _controller.selection = TextSelection.collapsed(offset: picked.length);
    ref.read(searchProvider.notifier).onQueryChanged(picked);
  }

  /// Desktop / web: recent and trending before typing; then the results page.
  Widget _desktopBody(SearchState search) {
    final q = search.query.trim();
    if (!SearchNotifier.searchable(q)) {
      return _SearchStart(recent: search.recent, onPick: _pick);
    }
    if (search.error != null && search.results.isEmpty) {
      return EmptyState(
        message: friendlyError(search.error!),
        onRefresh: () async => ref.read(searchProvider.notifier).onQueryChanged(_controller.text),
        showSettings: true,
      );
    }
    if (search.results.isEmpty && !search.loading) {
      return const EmptyState(
        icon: Icons.search_off_rounded,
        title: 'No matches',
        message: 'Nothing matches that name. Try another title.',
      );
    }
    // Highest TMDB rating first (few-vote and unrated last); ties keep the server's order.
    final order = {for (var i = 0; i < search.results.length; i++) search.results[i].id: i};
    final results = [...search.results]
      ..sort((a, b) {
        final byRating = _ratingKey(b).compareTo(_ratingKey(a));
        return byRating != 0 ? byRating : order[a.id]!.compareTo(order[b.id]!);
      });
    // Still searching: nothing to show yet (the spinner sits on top).
    if (results.isEmpty) return const SizedBox.shrink();
    final movies = results.where((t) => t.kind == 'MOVIE').length;
    final series = results.length - movies;
    final more = search.hasNextPage ? '+' : '';
    final counts = [
      '${results.length}$more result${results.length == 1 ? '' : 's'}',
      [if (movies > 0) '$movies movie${movies == 1 ? '' : 's'}', if (series > 0) '$series series'].join(', '),
    ].where((e) => e.isNotEmpty).join('  ·  ');
    final rest = results.skip(1).toList();
    return PosterGrid(
      items: rest,
      sidePadding: PbSpace.gutterDesktop,
      loadingMore: search.loadingMore,
      onEndReached: () => ref.read(searchProvider.notifier).loadMore(),
      headerSlivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(PbSpace.gutterDesktop, 20, PbSpace.gutterDesktop, 0),
          sliver: SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text.rich(
                  TextSpan(
                    text: 'Results for ',
                    children: [
                      TextSpan(text: '\u201c$q\u201d', style: const TextStyle(color: PbColors.primary)),
                    ],
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: PbType.hero.copyWith(fontSize: 44, color: PbColors.text, height: 1.05),
                ),
                const SizedBox(height: 6),
                Text(counts, style: PbType.meta.copyWith(fontSize: 14, color: PbColors.textMuted)),
                const SizedBox(height: 20),
                FeatureCard(item: results.first, eyebrow: 'Top result'),
                if (rest.isNotEmpty) ...[
                  const SizedBox(height: 28),
                  Text.rich(
                    TextSpan(
                      text: 'Titles',
                      children: [
                        TextSpan(
                          text: '  ${rest.length}$more',
                          style: PbType.meta.copyWith(color: PbColors.textMuted),
                        ),
                      ],
                    ),
                    style: PbType.h2.copyWith(color: PbColors.text),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// TMDB rating for ordering results. A score from a handful of votes
  /// (a 10.0 from 3 people) ranks after well-known titles.
  static double _ratingKey(TitleItem t) {
    final r = t.ratings?.tmdbVoteAverage ?? 0;
    final votes = t.ratings?.tmdbVoteCount ?? 0;
    return votes >= 50 ? r : r - 10;
  }

  Widget _body(SearchState search, String kind) {
    if (!SearchNotifier.searchable(search.query)) {
      return _IdleSearch(
        kind: kind,
        recent: search.recent,
        onPick: (picked) {
          _controller.text = picked;
          _controller.selection = TextSelection.collapsed(offset: picked.length);
          ref.read(searchProvider.notifier).onQueryChanged(picked);
          if (isAndroidTv) _openField();
        },
      );
    }
    if (search.error != null && search.results.isEmpty) {
      return EmptyState(
        message: friendlyError(search.error!),
        onRefresh: () async => ref.read(searchProvider.notifier).onQueryChanged(_controller.text),
        showSettings: true,
      );
    }
    if (search.results.isEmpty && !search.loading) {
      return EmptyState(
        icon: Icons.search_off_rounded,
        title: searchEmptyTitle(kind),
        message: 'Nothing matches that name. Try another title.',
      );
    }
    return PosterGrid(
      items: search.results,
      loadingMore: search.loadingMore,
      onEndReached: () => ref.read(searchProvider.notifier).loadMore(),
      onMoveUp: isAndroidTv ? _focusSearchBar : null,
      firstFocus: isAndroidTv ? _firstResult : null,
    );
  }
}

class _IdleSearch extends StatelessWidget {
  const _IdleSearch({required this.kind, required this.recent, required this.onPick});

  final String kind;
  final List<String> recent;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 32, 20, 40),
          shrinkWrap: true,
          children: [
            Icon(Icons.search_rounded, size: 44, color: scheme.onSurfaceVariant),
            const SizedBox(height: 14),
            Text(
              searchIdleTitle(kind),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              isAndroidTv
                  ? 'Select the search field to type. Down moves to results.'
                  : 'Type a name in the bar above. Results stay in ${kindPlural(kind)}.',
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4, fontSize: 16),
            ),
            if (recent.isNotEmpty) ...[
              const SizedBox(height: 28),
              Text(
                'Recent',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: scheme.onSurfaceVariant,
                      letterSpacing: 0.4,
                    ),
              ),
              const SizedBox(height: 10),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final q in recent)
                    ActionChip(
                      avatar: const Icon(Icons.history, size: 16),
                      label: Text(q),
                      onPressed: () => onPick(q),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}


/// The search field: a rounded bar under the back arrow (desktop / web).
class _SearchBar extends StatelessWidget {
  const _SearchBar({
    required this.controller,
    required this.query,
    required this.kind,
    required this.onKind,
    required this.onChanged,
    required this.onClear,
  });

  final TextEditingController controller;
  final String query;
  /// MOVIE or SERIES: only this kind is searched.
  final String kind;
  final ValueChanged<String> onKind;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(PbSpace.gutterDesktop - 8, 14, PbSpace.gutterDesktop, 4),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Back',
            // Opened straight from the address bar (web) there's nothing to go back to.
            onPressed: () => context.canPop() ? context.pop() : context.go('/'),
            icon: const Icon(Icons.arrow_back_rounded, color: PbColors.text),
          ),
          const SizedBox(width: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: SizedBox(
              width: MediaQuery.sizeOf(context).width * 0.6,
              child: TextField(
                controller: controller,
                autofocus: true,
                onChanged: onChanged,
                onSubmitted: onChanged,
                textInputAction: TextInputAction.search,
                style: PbType.body.copyWith(fontSize: 16, color: PbColors.text),
                decoration: InputDecoration(
                  hintText: 'Search',
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                  prefixIcon: const Icon(Icons.search_rounded, color: PbColors.textMuted),
                  suffixIcon: query.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'Clear',
                          onPressed: onClear,
                          icon: const Icon(Icons.close_rounded, color: PbColors.textMuted),
                        ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(PbRadius.pill),
                    borderSide: const BorderSide(color: PbColors.line),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(PbRadius.pill),
                    borderSide: const BorderSide(color: PbColors.line),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(PbRadius.pill),
                    borderSide: const BorderSide(color: PbColors.primary, width: 1.5),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 14),
          for (final (label, value) in const [('Movies', 'MOVIE'), ('Series', 'SERIES')]) ...[
            ChoiceChip(
              label: Text(label),
              selected: kind == value,
              onSelected: (_) => onKind(value),
            ),
            const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }
}

/// Before typing: your recent searches (nothing else, to keep it calm).
class _SearchStart extends StatelessWidget {
  const _SearchStart({required this.recent, required this.onPick});

  final List<String> recent;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    if (recent.isEmpty) return const SizedBox.shrink();
    return ListView(
      padding: const EdgeInsets.fromLTRB(PbSpace.gutterDesktop, 20, PbSpace.gutterDesktop, 48),
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text(
            'RECENT SEARCHES',
            style: PbType.label.copyWith(color: PbColors.textMuted, letterSpacing: 1.2),
          ),
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final q in recent)
              ActionChip(
                avatar: const Icon(Icons.history_rounded, size: 16, color: PbColors.textMuted),
                label: Text(q),
                onPressed: () => onPick(q),
              ),
          ],
        ),
      ],
    );
  }
}
