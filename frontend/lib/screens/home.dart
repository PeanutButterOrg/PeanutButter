import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:graphql_flutter/graphql_flutter.dart';

import '../design/tokens.g.dart';
import '../friendly_error.dart';
import '../graphql/queries.dart';
import '../models.dart';
import '../providers/catalog.dart';
import '../providers/settings.dart';
import '../theme.dart';
import '../tv.dart';
import '../tv_nav.dart';
import '../window_layout.dart';
import '../widgets/cached_art.dart';
import '../widgets/empty_state.dart';
import '../widgets/hero_banner.dart';
import '../widgets/local_overlay.dart';
import '../widgets/poster_card.dart';
import '../widgets/title_meta.dart';
import '../widgets/episode_alerts.dart';
import '../widgets/top_bar.dart';
import '../widgets/tv_chrome.dart';
import '../widgets/wide_card.dart';

/// Whether the home rows have scrolled under the header (darker header bar).
final ValueNotifier<bool> _homeScrolled = ValueNotifier(false);

/// One home row: what it shows and how its cards look.
enum _RowStyle { poster, top10, wide }

class _RowSpec {
  const _RowSpec(this.title, this.sort, this.items,
      {this.kind, this.style = _RowStyle.poster});

  final String title;
  final String sort;
  final List<TitleItem> items;

  /// Null: See all opens every kind (movies and series).
  final String? kind;
  final _RowStyle style;
}

/// What the home shows for a section: hero slides and rows.
class _HomeContent {
  const _HomeContent(this.hero, this.heroEyebrows, this.rows);

  final List<TitleItem> hero;
  final List<String> heroEyebrows;
  final List<_RowSpec> rows;

  bool get isEmpty => hero.isEmpty && rows.every((r) => r.items.isEmpty);
}

List<TitleItem> _interleave(List<TitleItem> a, List<TitleItem> b, {int? take}) {
  final out = <TitleItem>[];
  final seen = <String>{};
  for (var i = 0; i < a.length || i < b.length; i++) {
    for (final list in [a, b]) {
      if (i < list.length && seen.add(list[i].id)) out.add(list[i]);
    }
  }
  return take == null || out.length <= take ? out : out.sublist(0, take);
}

String _kindLabel(String kind) => kind == 'SERIES' ? 'Series' : 'Movie';

/// Only titles TMDB knows and has rated (servers before 0.3.25 send the rest too).
List<TitleItem> _tmdbRated(List<TitleItem> items) =>
    items.where((t) => (t.ratings?.tmdbVoteAverage ?? 0) > 0).toList();

_HomeContent _contentFor(String section, HomeFeed? movies, HomeFeed? series) {
  const empty = HomeFeed(trending: [], popular: [], recent: []);
  final m = movies ?? empty;
  final s = series ?? empty;
  if (section == 'HOME') {
    final heroMovies = m.trending.take(5).toList();
    final heroSeries = s.trending.take(5).toList();
    final hero = _interleave(heroMovies, heroSeries);
    final eyebrows = [
      for (final item in hero)
        heroMovies.contains(item)
            ? '#${heroMovies.indexOf(item) + 1} trending · Movie'
            : '#${heroSeries.indexOf(item) + 1} trending · Series',
    ];
    return _HomeContent(hero, eyebrows, [
      // One Top 10 for movies and series together, in trending order.
      _RowSpec('Top 10 today', 'TRENDING',
          _interleave(m.trending, s.trending, take: 10),
          style: _RowStyle.top10),
      _RowSpec('Continue watching', 'CONTINUE_WATCHING',
          _interleave(m.continueWatching, s.continueWatching),
          style: _RowStyle.wide),
      _RowSpec('Popular movies', 'POPULARITY', m.popular, kind: 'MOVIE'),
      _RowSpec('Popular series', 'POPULARITY', s.popular, kind: 'SERIES'),
      _RowSpec('Recently added', 'DATE_ADDED',
          _tmdbRated(_interleave(m.recent, s.recent))),
    ]);
  }
  final feed = section == 'SERIES' ? s : m;
  final noun = section == 'SERIES' ? 'series' : 'movies';
  final hero = feed.trending.take(8).toList();
  return _HomeContent(
    hero,
    [
      for (var i = 0; i < hero.length; i++)
        '#${i + 1} trending · ${_kindLabel(section)}'
    ],
    [
      _RowSpec(
          'Top 10 $noun today', 'TRENDING', feed.trending.take(10).toList(),
          kind: section, style: _RowStyle.top10),
      // The server sends one mixed list; this section shows only its own kind.
      _RowSpec(
        'Continue watching',
        'CONTINUE_WATCHING',
        feed.continueWatching
            .where((t) => (t.kind == 'MOVIE') == (section == 'MOVIE'))
            .toList(),
        style: _RowStyle.wide,
      ),
      _RowSpec('Trending $noun', 'TRENDING', feed.trending.skip(10).toList(),
          kind: section),
      _RowSpec('Popular $noun', 'POPULARITY', feed.popular, kind: section),
      _RowSpec('Recently added', 'DATE_ADDED', _tmdbRated(feed.recent),
          kind: section),
    ],
  );
}

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  Future<void> _refresh(WidgetRef ref) => refreshCatalogData(ref);

  static HomeSection _sectionOf(String value) => switch (value) {
        'MOVIE' => HomeSection.movies,
        'SERIES' => HomeSection.series,
        _ => HomeSection.home,
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final section = ref.watch(homeSectionProvider);
    final movies = ref.watch(homeFeedProvider('MOVIE'));
    final series =
        section == 'MOVIE' ? null : ref.watch(homeFeedProvider('SERIES'));
    ref.watch(catalogWarmupProvider);
    final info = ref.watch(serverInfoProvider);

    void exitHeaderToBanner() {
      TvHomeScroll.exitHeader?.call();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        TvHomeScroll.toBanner?.call();
      });
    }

    void selectSection(HomeSection value) {
      final next = switch (value) {
        HomeSection.movies => 'MOVIE',
        HomeSection.series => 'SERIES',
        HomeSection.home => 'HOME',
      };
      ref.read(homeSectionProvider.notifier).state = next;
      // Search, See all and the catalog still follow the last kind picked.
      if (next != 'HOME') ref.read(selectedKindProvider.notifier).state = next;
    }

    // Movies and series load side by side; show what's there as soon as one is in.
    final feeds = [if (section != 'SERIES') movies, if (series != null) series];
    final loading = feeds.every((f) => f.isLoading && !f.hasValue);
    final failed = feeds.every((f) => f.hasError && !f.hasValue);

    Widget body;
    if (loading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (failed) {
      body = EmptyState(
        message: friendlyError(feeds.first.error!),
        onRefresh: () => _refresh(ref),
        showSettings: true,
      );
    } else {
      final kind = section == 'HOME' ? 'MOVIE' : section;
      final tmdb = info.asData?.value?.tmdbConfigured ?? false;
      final omdb = info.asData?.value?.omdbConfigured ?? true;
      final content =
          _contentFor(section, movies.valueOrNull, series?.valueOrNull);
      if (kindBlockedByMissingKeys(kind,
              omdbConfigured: omdb, tmdbConfigured: tmdb) ||
          content.isEmpty) {
        body = EmptyState(
          message: emptyKindMessage(
              kind: kind, omdbConfigured: omdb, tmdbConfigured: tmdb),
          onRefresh: () => _refresh(ref),
          showSettings: true,
        );
      } else {
        body = _HomeBody(section: section, content: content);
      }
    }

    return EpisodeAlertsListener(
      child: Scaffold(
        backgroundColor: AppTheme.canvas,
        body: TvNavHost(
          strategies: [
            TvNavBarStrategy(
              nodes: TvHeaderFocus.homeBar,
              onMoveDown: exitHeaderToBanner,
            ),
            TvNavHomeStrategy(),
          ],
          child: TvBackScope(
            overlapHeader: true,
            root: true,
            headerFocus: TvHeaderFocus.forKind(section),
            // Clear over the hero; once rows scroll under it, a flat
            // see-through black bar (no shadow below it).
            header: ValueListenableBuilder<bool>(
              valueListenable: _homeScrolled,
              builder: (context, scrolled, child) => AnimatedContainer(
                duration: PbMotion.base,
                color: scrolled ? const Color(0xB8000000) : const Color(0x00000000),
                child: child,
              ),
              child: SafeArea(
                bottom: false,
                child: PbTopBar(
                  section: _sectionOf(section),
                  onSection: selectSection,
                  onMoveDown: exitHeaderToBanner,
                ),
              ),
            ),
            body: KeyedSubtree(key: ValueKey(section), child: body),
          ),
        ),
      ),
    );
  }
}

class _HomeBody extends ConsumerStatefulWidget {
  const _HomeBody({required this.section, required this.content});

  final String section;
  final _HomeContent content;

  @override
  ConsumerState<_HomeBody> createState() => _HomeBodyState();
}

class _HomeBodyState extends ConsumerState<_HomeBody> {
  final ScrollController _scroll = ScrollController();

  void _trackScrolled() {
    _homeScrolled.value = _scroll.hasClients && _scroll.offset > 120;
  }

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_trackScrolled);
    _homeScrolled.value = false;
    TvHomeScroll.toTop = _toTop;
    TvHomeScroll.toBanner = _toBanner;
    if (isAndroidTv) {
      TvHeaderFocus.bannerDetails.addListener(_onBannerFocus);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_scroll.hasClients) _scroll.jumpTo(0);
      if (!isAndroidTv) return;
      final label = FocusManager.instance.primaryFocus?.debugLabel ?? '';
      if (label.startsWith('header-')) return;
      if (TvHeaderFocus.bannerDetails.canRequestFocus) {
        TvHeaderFocus.bannerDetails.requestFocus();
      }
    });
  }

  @override
  void dispose() {
    if (isAndroidTv) {
      TvHeaderFocus.bannerDetails.removeListener(_onBannerFocus);
    }
    if (identical(TvHomeScroll.toTop, _toTop)) {
      TvHomeScroll.toTop = null;
    }
    if (identical(TvHomeScroll.toBanner, _toBanner)) {
      TvHomeScroll.toBanner = null;
    }
    _scroll.dispose();
    super.dispose();
  }

  void _onBannerFocus() {
    if (!mounted || !isAndroidTv) return;
    if (TvHeaderFocus.bannerDetails.hasFocus) _toTop();
  }

  void _toTop() {
    if (!_scroll.hasClients) return;
    if (isAndroidTv) {
      _scroll.animateTo(0,
          duration: const Duration(milliseconds: 420),
          curve: Curves.easeInOutCubic);
    } else {
      _scroll.jumpTo(0);
    }
  }

  void _toBanner() {
    if (_scroll.hasClients) {
      if (isAndroidTv) {
        _scroll.animateTo(0,
            duration: const Duration(milliseconds: 420),
            curve: Curves.easeInOutCubic);
      } else {
        _scroll.jumpTo(0);
      }
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final node = TvHeaderFocus.bannerDetails;
      if (node.canRequestFocus) node.requestFocus();
    });
  }

  @override
  Widget build(BuildContext context) {
    final content = widget.content;
    var rail = 0;
    final list = ListView(
      controller: _scroll,
      cacheExtent: isAndroidTv ? 280 : 800,
      addAutomaticKeepAlives: false,
      clipBehavior: isAndroidTv ? Clip.none : Clip.hardEdge,
      physics: const ClampingScrollPhysics(),
      padding: EdgeInsets.only(
          bottom: isAndroidTv ? tvCenterBottomPad(context) : 48),
      children: [
        FeaturedBanner(
          key: ValueKey(widget.section),
          items: content.hero,
          eyebrows: content.heroEyebrows,
        ),
        for (final row in content.rows)
          if (row.items.isNotEmpty)
            _HomeRow(
              key: ValueKey('${widget.section}-${row.title}'),
              spec: row,
              railIndex: rail++,
            ),
      ],
    );
    return ClippedOverlay(child: list);
  }
}

void _openCatalog(BuildContext context, {String? kind, required String sort}) {
  final container = ProviderScope.containerOf(context);
  container.read(catalogProvider.notifier).clearForNewView();
  if (kind != null) {
    container.read(selectedKindProvider.notifier).state = kind;
  }
  container.read(catalogFilterProvider.notifier).state = CatalogFilter(
    kind: kind,
    sort: sort,
    railLocked: true,
  );
  context.push('/catalog');
}

class FeaturedBanner extends ConsumerStatefulWidget {
  const FeaturedBanner(
      {super.key, required this.items, this.eyebrows = const []});

  final List<TitleItem> items;

  /// One line per slide, e.g. "#1 trending · Movie".
  final List<String> eyebrows;

  @override
  ConsumerState<FeaturedBanner> createState() => _FeaturedBannerState();
}

class _FeaturedBannerState extends ConsumerState<FeaturedBanner> {
  /// My List taps not yet reflected in the feed (title id -> on the list).
  final Map<String, bool> _listed = {};

  bool _onList(TitleItem item) =>
      _listed[item.id] ?? item.userState?.favorite == true;

  Future<void> _toggleList(TitleItem item) async {
    final next = !_onList(item);
    setState(() => _listed[item.id] = next);
    try {
      await ref.read(graphQLClientProvider).mutate(
            MutationOptions(
              document: gql(SET_FAVORITE),
              variables: {'titleId': item.id, 'favorite': next},
            ),
          );
      ref.invalidate(favoritesFeedProvider);
    } catch (_) {
      if (mounted) setState(() => _listed[item.id] = !next);
    }
  }

  PageController? _page;
  final GlobalKey _bannerKey = GlobalKey();
  Timer? _timer;
  bool _paused = false;
  int _index = 0;

  @override
  void initState() {
    super.initState();
    if (!isAndroidTv) {
      _page = PageController();
    }
    _timer = Timer.periodic(
      Duration(seconds: isAndroidTv ? 8 : 5),
      (_) => _advance(),
    );
  }

  @override
  void didUpdateWidget(covariant FeaturedBanner oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.items != widget.items) {
      _index = 0;
      final page = _page;
      if (page != null && page.hasClients) {
        page.jumpToPage(0);
      }
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _page?.dispose();
    super.dispose();
  }

  bool get _holdRotation {
    // Any hero button focused (they share the label).
    return FocusManager.instance.primaryFocus?.debugLabel == 'banner-details';
  }

  void _advance() {
    if (_paused || _holdRotation || !mounted || widget.items.length < 2) return;
    // Home is covered (detail / player on top): don't rotate or decode
    // backdrops nobody can see.
    if (!TickerMode.of(context)) return;
    if (isAndroidTv) {
      setState(() => _index = (_index + 1) % widget.items.length);
      return;
    }
    final page = _page;
    if (page == null || !page.hasClients) return;
    page.animateToPage(
      _index + 1,
      duration: const Duration(milliseconds: 900),
      curve: Curves.easeInOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.items.isEmpty) return const SizedBox.shrink();
    final item = widget.items[_index % widget.items.length];
    final art = BannerArt(
      url: bestBannerUrl(
        backdropUrl: item.backdropUrl,
        thumbUrl: item.thumbUrl,
        posterUrl: item.posterUrl,
      ),
      fallbackUrl: item.posterUrl,
      logoUrl: item.logoUrl,
    );
    return MouseRegion(
      onEnter: (_) => _paused = true,
      onExit: (_) => _paused = false,
      child: HeroBannerFrame(
        bannerKey: _bannerKey,
        topInset: HeroBannerFrame.headerGap(context),
        art: isAndroidTv
            ? AnimatedSwitcher(
                duration: const Duration(milliseconds: 550),
                switchInCurve: Curves.easeOut,
                switchOutCurve: Curves.easeIn,
                layoutBuilder: (current, previous) {
                  return Stack(
                    fit: StackFit.expand,
                    children: [
                      ...previous,
                      if (current != null) current,
                    ],
                  );
                },
                transitionBuilder: (child, animation) {
                  return FadeTransition(opacity: animation, child: child);
                },
                child: SizedBox.expand(key: ValueKey(item.id), child: art),
              )
            : ExcludeFocus(
                child: PageView.builder(
                  controller: _page,
                  physics: const NeverScrollableScrollPhysics(),
                  onPageChanged: (i) => setState(() => _index = i),
                  itemBuilder: (context, i) {
                    final slide = widget.items[i % widget.items.length];
                    return GestureDetector(
                      onTap: () => context.push('/title/${slide.id}'),
                      child: AnimatedBuilder(
                        animation: _page!,
                        builder: (context, child) {
                          final page = _page!;
                          final value = page.hasClients
                              ? (page.page ?? i.toDouble())
                              : i.toDouble();
                          final opacity =
                              (1.0 - (value - i).abs()).clamp(0.0, 1.0);
                          return Opacity(opacity: opacity, child: child);
                        },
                        child: BannerArt(
                          url: bestBannerUrl(
                            backdropUrl: slide.backdropUrl,
                            thumbUrl: slide.thumbUrl,
                            posterUrl: slide.posterUrl,
                          ),
                          fallbackUrl: slide.posterUrl,
                          logoUrl: slide.logoUrl,
                        ),
                      ),
                    );
                  },
                ),
              ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 450),
              switchInCurve: Curves.easeOut,
              switchOutCurve: Curves.easeIn,
              layoutBuilder: (current, previous) {
                return Stack(
                  alignment: Alignment.topLeft,
                  children: [
                    ...previous,
                    if (current != null) current,
                  ],
                );
              },
              transitionBuilder: (child, animation) {
                return FadeTransition(opacity: animation, child: child);
              },
              child: _BannerCopy(
                key: ValueKey(item.id),
                item: item,
                eyebrow: _index % widget.items.length < widget.eyebrows.length
                    ? widget.eyebrows[_index % widget.items.length]
                    : 'Trending now',
              ),
            ),
            const SizedBox(height: 4),
            _HeroButtons(
              onList: _onList(item),
              onPlay: () => context.push('/title/${item.id}?play=1'),
              onToggleList: () => unawaited(_toggleList(item)),
              onInfo: () => context.push('/title/${item.id}'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

/// Play (amber) · My List · More info, on desktop and TV alike.
class _HeroButtons extends StatelessWidget {
  const _HeroButtons({
    required this.onList,
    required this.onPlay,
    required this.onToggleList,
    required this.onInfo,
  });

  final bool onList;
  final VoidCallback onPlay;
  final VoidCallback onToggleList;
  final VoidCallback onInfo;

  @override
  Widget build(BuildContext context) {
    final tv = isAndroidTv;
    final size = Size(0, tv ? PbSize.buttonHeightTv : 40);
    final text = tv ? PbTypeTv.button : PbType.button;
    return Row(
      children: [
        TvFocus(
          allowHorizontal: false,
          child: FilledButton.icon(
            focusNode: tv ? TvHeaderFocus.bannerDetails : null,
            onPressed: onPlay,
            style: FilledButton.styleFrom(minimumSize: size, textStyle: text),
            icon: const Icon(Icons.play_arrow_rounded),
            label: const Text('Play'),
          ),
        ),
        const SizedBox(width: 10),
        TvFocus(
          allowHorizontal: false,
          child: OutlinedButton.icon(
            focusNode: tv ? TvHeaderFocus.bannerList : null,
            onPressed: onToggleList,
            style: OutlinedButton.styleFrom(minimumSize: size, textStyle: text),
            icon: Icon(onList ? Icons.check_rounded : Icons.add_rounded),
            label: const Text('My List'),
          ),
        ),
        const SizedBox(width: 10),
        TvFocus(
          allowHorizontal: false,
          child: OutlinedButton.icon(
            focusNode: tv ? TvHeaderFocus.bannerInfo : null,
            onPressed: onInfo,
            style: OutlinedButton.styleFrom(minimumSize: size, textStyle: text),
            icon: const Icon(Icons.info_outline_rounded),
            label: const Text('More info'),
          ),
        ),
      ],
    );
  }
}

class _BannerCopy extends StatelessWidget {
  const _BannerCopy({super.key, required this.item, required this.eyebrow});

  final TitleItem item;
  final String eyebrow;

  @override
  Widget build(BuildContext context) {
    return HeroBannerCopy(
      eyebrow: eyebrow,
      title: item.title,
      synopsis: item.synopsis ?? '',
      meta: TitleMetaRow(item: item, maxGenres: 3),
    );
  }
}

/// Desktop / web: Netflix-style strips at both ends of a row. Each pages the
/// row by most of its width; it shows only when there's more that way.
class _RowArrows extends StatefulWidget {
  const _RowArrows(
      {required this.controller, required this.gutter, required this.child});

  final ScrollController controller;
  final double gutter;
  final Widget child;

  @override
  State<_RowArrows> createState() => _RowArrowsState();
}

class _RowArrowsState extends State<_RowArrows> {
  var _back = false;
  var _more = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_update);
    WidgetsBinding.instance.addPostFrameCallback((_) => _update());
  }

  @override
  void dispose() {
    widget.controller.removeListener(_update);
    super.dispose();
  }

  void _update() {
    final c = widget.controller;
    if (!mounted || !c.hasClients) return;
    final p = c.position;
    final back = p.pixels > 4;
    final more = p.pixels < p.maxScrollExtent - 4;
    if (back != _back || more != _more) {
      setState(() {
        _back = back;
        _more = more;
      });
    }
  }

  void _page(int dir) {
    final c = widget.controller;
    if (!c.hasClients) return;
    final p = c.position;
    final target =
        (p.pixels + dir * (p.viewportDimension - widget.gutter * 2) * 0.9)
            .clamp(0.0, p.maxScrollExtent);
    c.animateTo(target,
        duration: const Duration(milliseconds: 520),
        curve: Curves.easeInOutCubic);
  }

  Widget _arrow(int dir) {
    final left = dir < 0;
    return Positioned(
      left: left ? 0 : null,
      right: left ? null : 0,
      top: 12,
      bottom: 12,
      width: widget.gutter < 44 ? 44 : widget.gutter,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          canRequestFocus: false,
          onTap: () => _page(dir),
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: left ? Alignment.centerLeft : Alignment.centerRight,
                end: left ? Alignment.centerRight : Alignment.centerLeft,
                colors: [
                  PbColors.ground.withValues(alpha: 0.92),
                  PbColors.ground.withValues(alpha: 0)
                ],
              ),
            ),
            child: Icon(
              left ? Icons.chevron_left_rounded : Icons.chevron_right_rounded,
              size: 40,
              color: PbColors.text,
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollMetricsNotification>(
      onNotification: (_) {
        _update();
        return false;
      },
      child: Stack(
        children: [
          Positioned.fill(child: widget.child),
          if (_back) _arrow(-1),
          if (_more) _arrow(1),
        ],
      ),
    );
  }
}

class _HomeRow extends StatefulWidget {
  const _HomeRow({super.key, required this.spec, required this.railIndex});

  final _RowSpec spec;
  final int railIndex;

  List<TitleItem> get items => spec.items;

  @override
  State<_HomeRow> createState() => _HomeRowState();
}

class _HomeRowState extends State<_HomeRow> {
  final FocusNode _seeAll = FocusNode(debugLabel: 'see-all');
  final Map<int, FocusNode> _posterFocus = {};
  final GlobalKey _rowKey = GlobalKey();
  final ScrollController _horizontal = ScrollController();
  late final TvHomeRail _rail = TvHomeRail(
    index: widget.railIndex,
    seeAll: _seeAll,
    firstPoster: _posterAt(0),
    reveal: _revealRow,
    prepareFirst: () => _prepareAt(0),
    prepareAt: _prepareAt,
    posterAt: _posterAt,
    itemCount: () => widget.items.length,
  );

  FocusNode _posterAt(int index) {
    return _posterFocus.putIfAbsent(
      index,
      () => FocusNode(debugLabel: 'poster'),
    );
  }

  @override
  void initState() {
    super.initState();
    TvHomeRails.attach(_rail);
  }

  @override
  void dispose() {
    TvHomeRails.detach(_rail);
    _seeAll.dispose();
    for (final node in _posterFocus.values) {
      node.dispose();
    }
    _posterFocus.clear();
    _horizontal.dispose();
    super.dispose();
  }

  void _revealRow() {
    final ctx = _rowKey.currentContext;
    if (ctx == null) return;
    tvEnsureVisible(ctx, centerRow: true);
  }

  void _prepareAt(int column) {
    // Intentionally no-op: cross-rail focus must not jump the horizontal strip.
    // Selection is by FocusNode index; ensureVisible runs after focus if needed.
  }

  /// Card width, strip extent and strip height for this row's style.
  ({double width, double extent, double height}) _dims(bool tv) {
    final gap = tv ? TvPosterDim.gap : 14.0;
    switch (widget.spec.style) {
      case _RowStyle.wide:
        final w = tv ? PbSize.wideCardWidthTv : PbSize.wideCardWidthDesktop;
        return (width: w, extent: w + gap, height: w * 9 / 16 + 24);
      case _RowStyle.top10:
        final w = tv ? TvPosterDim.width : PbSize.posterWidthDesktop;
        return (
          width: w,
          extent: w + Top10Tile.numberWidth(w) + gap * 0.6,
          height: w * 1.5 + 24 + Top10Tile.nameHeight
        );
      case _RowStyle.poster:
        final w = tv ? TvPosterDim.width : PbSize.posterWidthDesktop;
        return (width: w, extent: w + gap, height: w * 1.5 + 24);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.items.isEmpty) return const SizedBox.shrink();
    final tv = isAndroidTv;
    final spec = widget.spec;
    final dims = _dims(tv);
    final gutter = tv ? PbSpace.gutterTv : PbSpace.gutterDesktop;
    return TvHomeRailScope(
      rail: _rail,
      child: TvFocusReveal(
        onReveal: _revealRow,
        child: Padding(
          key: _rowKey,
          padding: const EdgeInsets.only(top: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: EdgeInsets.only(left: gutter, right: gutter - 12),
                // The row's name, "See all" at the right end (as on TV).
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(
                      child: Text(spec.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: (tv ? PbTypeTv.h2 : PbType.h2)
                              .copyWith(color: PbColors.text)),
                    ),
                    const SizedBox(width: 6),
                    _SeeAllButton(
                      focusNode: _seeAll,
                      onReveal: _revealRow,
                      onPressed: () => _openCatalog(context,
                          kind: spec.kind, sort: spec.sort),
                    ),
                  ],
                ),
              ),
              SizedBox(
                height: dims.height,
                // TV: eager children so column-N FocusNodes stay attached without
                // jumpTo-scrolling the strip before selection.
                child: tv
                    ? _strip(tv, dims, gutter)
                    : _RowArrows(
                        controller: _horizontal,
                        gutter: gutter,
                        child: _strip(tv, dims, gutter)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _strip(bool tv, ({double width, double extent, double height}) dims,
      double gutter) {
    return ListView.builder(
      controller: _horizontal,
      clipBehavior: Clip.none,
      cacheExtent: tv ? 8000 : 600,
      addAutomaticKeepAlives: true,
      padding: EdgeInsets.symmetric(horizontal: gutter, vertical: 12),
      scrollDirection: Axis.horizontal,
      physics: const ClampingScrollPhysics(),
      itemExtent: dims.extent,
      itemCount: widget.items.length,
      itemBuilder: (context, i) =>
          _tile(i, dims.width, tv ? TvPosterDim.gap : 14.0),
    );
  }

  Widget _tile(int i, double width, double gap) {
    final item = widget.items[i];
    final node = _posterAt(i);
    final Widget card = switch (widget.spec.style) {
      _RowStyle.wide =>
        SizedBox(width: width, child: WideCard(item: item, focusNode: node)),
      _RowStyle.top10 => Top10Tile(
          rank: i + 1,
          posterWidth: width,
          name: item.title,
          child: PosterCard(item: item, focusNode: node),
        ),
      _RowStyle.poster =>
        SizedBox(width: width, child: PosterCard(item: item, focusNode: node)),
    };
    return Padding(
      padding: EdgeInsets.only(
          right: widget.spec.style == _RowStyle.top10 ? gap * 0.6 : gap),
      child: Align(alignment: Alignment.bottomLeft, child: card),
    );
  }
}

class _SeeAllButton extends StatefulWidget {
  const _SeeAllButton({required this.onPressed, this.focusNode, this.onReveal});

  final VoidCallback onPressed;
  final FocusNode? focusNode;
  final VoidCallback? onReveal;

  @override
  State<_SeeAllButton> createState() => _SeeAllButtonState();
}

class _SeeAllButtonState extends State<_SeeAllButton> {
  late final FocusNode _node;
  late final bool _ownsNode;

  @override
  void initState() {
    super.initState();
    _ownsNode = widget.focusNode == null;
    _node = widget.focusNode ?? FocusNode(debugLabel: 'see-all');
    _node.addListener(_onFocus);
  }

  @override
  void dispose() {
    _node.removeListener(_onFocus);
    if (_ownsNode) _node.dispose();
    super.dispose();
  }

  void _onFocus() {
    // Vertical scroll to the row is handled by _tvFocusSeeAll / _tvFocusRailPosters
    // in the focus policy — don't issue a second scroll here.
  }

  @override
  Widget build(BuildContext context) {
    return TvFocus(
      child: TextButton(
        focusNode: _node,
        onPressed: widget.onPressed,
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          minimumSize: const Size(56, 36),
          foregroundColor: PbColors.textMuted,
          textStyle: (isAndroidTv ? PbTypeTv.meta : PbType.meta)
              .copyWith(fontWeight: FontWeight.w600),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        child: const Text('See all'),
      ),
    );
  }
}
