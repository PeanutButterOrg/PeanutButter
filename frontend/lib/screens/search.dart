import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../friendly_error.dart';
import '../providers/catalog.dart';
import '../theme.dart';
import '../tv.dart';
import '../widgets/empty_state.dart';
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
  final _anime = FocusNode(debugLabel: 'header-anime');
  final _refresh = FocusNode(debugLabel: 'header-refresh');
  final _searchBtn = FocusNode(debugLabel: 'header-search-btn');
  final _settings = FocusNode(debugLabel: 'header-settings');
  final _fieldChrome = FocusNode(debugLabel: 'header-search');
  final _firstResult = FocusNode(debugLabel: 'poster');
  final _fieldKey = GlobalKey<TvTextFieldState>();

  List<FocusNode> get _barNodes => [
        _movies,
        _series,
        _anime,
        _fieldChrome,
        _refresh,
        _searchBtn,
        _settings,
      ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(searchProvider.notifier).setKind(ref.read(selectedKindProvider));
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
    _anime.dispose();
    _refresh.dispose();
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

  Future<void> _refreshCatalog() => refreshCatalogData(ref);

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
    final refreshing = ref.watch(refreshBusyProvider);
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
      onMoveLeft: tv ? () => _anime.requestFocus() : null,
      onMoveRight: tv ? () => _refresh.requestFocus() : null,
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
            tooltip: 'Refresh',
            focusNode: tv ? _refresh : null,
            busy: refreshing,
            onPressed: _refreshCatalog,
            onMoveLeft: tv ? _focusSearchBar : null,
            onMoveRight: tv ? () => _searchBtn.requestFocus() : null,
            onMoveDown: tv ? () => _focusResults() : null,
            icon: const Icon(Icons.refresh_rounded),
          ),
          TvHeaderButton(
            tooltip: 'Search',
            focusNode: tv ? _searchBtn : null,
            onPressed: _openField,
            onMoveLeft: tv ? () => _refresh.requestFocus() : null,
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
              child: FocusTraversalGroup(
                policy: TvBarFocusPolicy(
                  nodes: _barNodes,
                  onMoveDown: tv ? () => _focusResults() : null,
                ),
                child: Row(
                  children: [
                    if (!tv)
                      IconButton(
                        tooltip: 'Back',
                        onPressed: () => context.pop(),
                        icon: const Icon(Icons.arrow_back_rounded),
                      ),
                    KindSwitch(
                      kind: kind,
                      moviesFocus: _movies,
                      seriesFocus: _series,
                      animeFocus: _anime,
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
            ),
          ],
        ),
      ),
    );

    final body = Stack(
      children: [
        Positioned.fill(child: _body(search, kind)),
        if (search.loading)
          const Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: LinearProgressIndicator(minHeight: 2),
          ),
      ],
    );

    if (!tv) {
      return Scaffold(
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            homeHeader,
            Expanded(child: body),
          ],
        ),
      );
    }

    return Scaffold(
      body: TvBackScope(
        popOnFirstBack: true,
        headerLive: true,
        headerFocus: _fieldChrome,
        header: homeHeader,
        body: body,
      ),
    );
  }

  Widget _body(SearchState search, String kind) {
    if (search.query.trim().isEmpty) {
      return _IdleSearch(
        kind: kind,
        recent: search.recent,
        onPick: (q) {
          _controller.text = q;
          _controller.selection = TextSelection.collapsed(offset: q.length);
          ref.read(searchProvider.notifier).onQueryChanged(q);
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
