import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../friendly_error.dart';
import '../models.dart';
import '../providers/catalog.dart';
import '../providers/settings.dart';
import '../tv.dart';
import '../widgets/cached_art.dart';
import '../widgets/empty_state.dart';
import '../widgets/hero_banner.dart';
import '../widgets/local_overlay.dart';
import '../widgets/poster_card.dart';
import '../widgets/rt_badge.dart';
import '../widgets/filter_bar.dart';
import '../widgets/tv_chrome.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  Future<void> _refresh(WidgetRef ref) => refreshCatalogData(ref);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final kind = ref.watch(selectedKindProvider);
    final refreshing = ref.watch(refreshBusyProvider);
    final feed = ref.watch(homeFeedProvider(kind));
    ref.watch(catalogWarmupProvider);
    final info = ref.watch(serverInfoProvider);

    return Scaffold(
      body: TvBackScope(
        overlapHeader: true,
        root: true,
        headerFocus: TvHeaderFocus.forKind(kind),
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
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 8, 0),
              child: FocusTraversalGroup(
                policy: TvBarFocusPolicy(
                  nodes: TvHeaderFocus.homeBar,
                  onMoveDown: () {
                    TvHomeScroll.exitHeader?.call();
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      TvHomeScroll.toBanner?.call();
                    });
                  },
                ),
                child: Row(
                children: [
                  KindSwitch(
                    kind: kind,
                    moviesFocus: TvHeaderFocus.movies,
                    onMoveTrailing: () => TvHeaderFocus.refresh.requestFocus(),
                    onMoveDown: () {
                      TvHomeScroll.exitHeader?.call();
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        TvHomeScroll.toBanner?.call();
                      });
                    },
                    onChanged: (value) {
                      ref.read(selectedKindProvider.notifier).state = value;
                    },
                  ),
                  const Spacer(),
                  TvHeaderButton(
                    tooltip: 'Refresh',
                    focusNode: TvHeaderFocus.refresh,
                    busy: refreshing,
                    onPressed: () => _refresh(ref),
                    onMoveLeft: () => TvHeaderFocus.anime.requestFocus(),
                    onMoveRight: () => TvHeaderFocus.search.requestFocus(),
                    onMoveDown: () {
                      TvHomeScroll.exitHeader?.call();
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        TvHomeScroll.toBanner?.call();
                      });
                    },
                    icon: const Icon(Icons.refresh_rounded),
                  ),
                  TvHeaderButton(
                    tooltip: 'Search',
                    focusNode: TvHeaderFocus.search,
                    onPressed: () => context.push('/search'),
                    onMoveLeft: () => TvHeaderFocus.refresh.requestFocus(),
                    onMoveRight: () => TvHeaderFocus.settings.requestFocus(),
                    // Down on search button → open the search screen
                    onMoveDown: () => context.push('/search'),
                    icon: const Icon(Icons.search_rounded),
                  ),
                  TvHeaderButton(
                    tooltip: 'Settings',
                    focusNode: TvHeaderFocus.settings,
                    onPressed: () => context.push('/settings'),
                    onMoveLeft: () => TvHeaderFocus.search.requestFocus(),
                    onMoveDown: () {
                      TvHomeScroll.exitHeader?.call();
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        TvHomeScroll.toBanner?.call();
                      });
                    },
                    icon: const Icon(Icons.settings_outlined),
                  ),
                ],
              ),
              ),
            ),
              ],
            ),
          ),
        ),
        body: KeyedSubtree(
          key: ValueKey(kind),
          child: feed.when(
            skipLoadingOnReload: true,
            skipLoadingOnRefresh: true,
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => EmptyState(
              message: friendlyError(e),
              onRefresh: () => _refresh(ref),
              showSettings: true,
            ),
            data: (data) {
              final omdb = info.asData?.value?.omdbConfigured ?? true;
              if (kindBlockedByMissingKeys(kind, omdbConfigured: omdb)) {
                return EmptyState(
                  message: emptyKindMessage(kind: kind, omdbConfigured: omdb),
                  onRefresh: () => _refresh(ref),
                  showSettings: true,
                );
              }
              final empty = data.trending.isEmpty && data.popular.isEmpty && data.recent.isEmpty;
              if (empty) {
                return EmptyState(
                  message: emptyKindMessage(kind: kind, omdbConfigured: omdb),
                  onRefresh: () => _refresh(ref),
                  showSettings: true,
                );
              }
              return _HomeBody(kind: kind, feed: data);
            },
          ),
        ),
      ),
    );
  }
}

class _HomeBody extends ConsumerStatefulWidget {
  const _HomeBody({required this.kind, required this.feed});

  final String kind;
  final HomeFeed feed;

  @override
  ConsumerState<_HomeBody> createState() => _HomeBodyState();
}

class _HomeBodyState extends ConsumerState<_HomeBody> {
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
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
      _scroll.animateTo(0, duration: const Duration(milliseconds: 420), curve: Curves.easeInOutCubic);
    } else {
      _scroll.jumpTo(0);
    }
  }

  void _toBanner() {
    if (_scroll.hasClients) {
      if (isAndroidTv) {
        _scroll.animateTo(0, duration: const Duration(milliseconds: 420), curve: Curves.easeInOutCubic);
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
    final kind = widget.kind;
    final feed = widget.feed;
    final list = ListView(
      controller: _scroll,
      cacheExtent: isAndroidTv ? 280 : 800,
      addAutomaticKeepAlives: false,
      clipBehavior: isAndroidTv ? Clip.none : Clip.hardEdge,
      physics: const ClampingScrollPhysics(),
      padding: EdgeInsets.only(bottom: isAndroidTv ? tvCenterBottomPad(context) : 48),
      children: [
          FeaturedBanner(key: ValueKey(kind), items: feed.trending),
        if (feed.continueWatching.isNotEmpty)
          _HomeRow(
            title: 'Continue watching',
            sort: 'CONTINUE_WATCHING',
            items: feed.continueWatching,
            kind: kind,
            allCatalogKinds: true,
            railIndex: 0,
          ),
        _HomeRow(title: 'Trending', sort: 'TRENDING', items: feed.trending, kind: kind, railIndex: 1),
        _HomeRow(title: 'Popular', sort: 'POPULARITY', items: feed.popular, kind: kind, railIndex: 2),
        _HomeRow(title: 'Last added', sort: 'DATE_ADDED', items: feed.recent, kind: kind, railIndex: 3),
      ],
    );
    return ClippedOverlay(
      child: isAndroidTv
          ? FocusTraversalGroup(policy: TvHomeFocusPolicy(), child: list)
          : list,
    );
  }
}

void _openCatalog(BuildContext context, {String? kind, required String sort}) {
  final container = ProviderScope.containerOf(context);
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

class FeaturedBanner extends StatefulWidget {
  const FeaturedBanner({super.key, required this.items});

  final List<TitleItem> items;

  @override
  State<FeaturedBanner> createState() => _FeaturedBannerState();
}

class _FeaturedBannerState extends State<FeaturedBanner> {
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
    return FocusManager.instance.primaryFocus?.debugLabel == 'banner-details';
  }

  void _advance() {
    if (_paused || _holdRotation || !mounted || widget.items.length < 2) return;
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
      url: item.thumbUrl ?? item.backdropUrl ?? item.posterUrl,
      fallbackUrl: item.posterUrl,
      logoUrl: item.logoUrl,
    );
    return MouseRegion(
      onEnter: (_) => _paused = true,
      onExit: (_) => _paused = false,
      child: HeroBannerFrame(
        bannerKey: _bannerKey,
        topInset: isAndroidTv ? HeroBannerFrame.headerGap(context) : 0,
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
                          final value = page.hasClients ? (page.page ?? i.toDouble()) : i.toDouble();
                          final opacity = (1.0 - (value - i).abs()).clamp(0.0, 1.0);
                          return Opacity(opacity: opacity, child: child);
                        },
                        child: BannerArt(
                          url: slide.thumbUrl ?? slide.backdropUrl ?? slide.posterUrl,
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
              ),
            ),
            const SizedBox(height: 12),
            TvFocus(
              allowHorizontal: false,
              child: FilledButton.icon(
                focusNode: isAndroidTv ? TvHeaderFocus.bannerDetails : null,
                onPressed: () => context.push('/title/${item.id}'),
                style: FilledButton.styleFrom(minimumSize: const Size(120, 48)),
                icon: const Icon(Icons.play_arrow_rounded),
                label: const Text('Details'),
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

class _BannerCopy extends StatelessWidget {
  const _BannerCopy({super.key, required this.item});

  final TitleItem item;

  @override
  Widget build(BuildContext context) {
    return HeroBannerCopy(
      eyebrow: 'Trending now',
      title: item.title,
      synopsis: item.synopsis ?? '',
      meta: Row(
        children: [
          RatingBadge(item: item, compact: false),
          if (item.year != null) ...[
            const SizedBox(width: 8),
            Text('${item.year}', style: const TextStyle(color: Colors.white70, fontSize: 14)),
          ],
          for (final label in item.mediaLabels) ...[
            const SizedBox(width: 8),
            Text(label, style: const TextStyle(color: Colors.white70, fontSize: 14)),
          ],
          for (final genre in item.genres.take(2)) ...[
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                genre,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white70, fontSize: 14),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _HomeRow extends StatefulWidget {
  const _HomeRow({
    required this.title,
    required this.sort,
    required this.items,
    required this.kind,
    required this.railIndex,
    this.allCatalogKinds = false,
  });

  final String title;
  final String sort;
  final List<TitleItem> items;
  final String kind;
  /// When true, See all opens the catalog with no kind filter (movies+series+anime).
  final bool allCatalogKinds;
  final int railIndex;

  @override
  State<_HomeRow> createState() => _HomeRowState();
}

class _HomeRowState extends State<_HomeRow> {
  final FocusNode _seeAll = FocusNode(debugLabel: 'see-all');
  final FocusNode _first = FocusNode(debugLabel: 'poster');
  final GlobalKey _rowKey = GlobalKey();
  final ScrollController _horizontal = ScrollController();
  late final TvHomeRail _rail = TvHomeRail(
    index: widget.railIndex,
    seeAll: _seeAll,
    firstPoster: _first,
    reveal: _revealRow,
    prepareFirst: _prepareFirst,
  );

  @override
  void initState() {
    super.initState();
    TvHomeRails.attach(_rail);
  }

  @override
  void dispose() {
    TvHomeRails.detach(_rail);
    _seeAll.dispose();
    _first.dispose();
    _horizontal.dispose();
    super.dispose();
  }

  void _revealRow() {
    final ctx = _rowKey.currentContext;
    if (ctx == null) return;
    tvEnsureVisible(ctx, centerRow: true);
  }

  void _prepareFirst() {
    if (_horizontal.hasClients && _horizontal.offset > 1) {
      _horizontal.jumpTo(0);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.items.isEmpty) return const SizedBox.shrink();
    final tv = isAndroidTv;
    return TvHomeRailScope(
      rail: _rail,
      child: TvFocusReveal(
      onReveal: _revealRow,
      child: Padding(
        key: _rowKey,
        padding: const EdgeInsets.only(top: 4),
        child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                Text(
                  widget.title,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                ),
                const Spacer(),
                _SeeAllButton(
                  focusNode: _seeAll,
                  onReveal: _revealRow,
                  onPressed: () => _openCatalog(
                    context,
                    kind: widget.allCatalogKinds ? null : widget.kind,
                    sort: widget.sort,
                  ),
                ),
              ],
            ),
          ),
          SizedBox(
            height: tv ? TvPosterDim.rowHeight : 248,
            child: ListView.builder(
              controller: _horizontal,
              clipBehavior: Clip.none,
              cacheExtent: tv ? 800 : 600,
              addAutomaticKeepAlives: true,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
              scrollDirection: Axis.horizontal,
              physics: const ClampingScrollPhysics(),
              itemExtent: tv ? TvPosterDim.extent : 168,
              itemCount: widget.items.length,
              itemBuilder: (context, i) {
                final item = widget.items[i];
                return Padding(
                  padding: EdgeInsets.only(right: tv ? TvPosterDim.gap : 12),
                  child: SizedBox(
                    width: tv ? TvPosterDim.width : 156,
                    child: PosterCard(item: item, focusNode: i == 0 ? _first : null),
                  ),
                );
              },
            ),
          ),
        ],
      ),
      ),
    ),
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
          padding: const EdgeInsets.symmetric(horizontal: 14),
          minimumSize: const Size(64, 40),
          tapTargetSize: MaterialTapTargetSize.padded,
        ),
        child: const Text('See all'),
      ),
    );
  }
}
