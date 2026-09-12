import 'package:flutter/material.dart';

import '../models.dart';
import '../tv.dart';
import 'poster_card.dart';
import 'tv_chrome.dart';

/// Poster wall that fills the available width so the last column is not left empty.
class PosterGrid extends StatefulWidget {
  const PosterGrid({
    super.key,
    required this.items,
    this.onEndReached,
    this.loadingMore = false,
    this.controller,
    this.onMoveUp,
    this.firstFocus,
  });

  final List<TitleItem> items;
  final VoidCallback? onEndReached;
  final bool loadingMore;
  final ScrollController? controller;
  /// TV: Up from the top row (e.g. return to search field).
  final VoidCallback? onMoveUp;
  /// TV: optional focus node for the first poster.
  final FocusNode? firstFocus;

  @override
  State<PosterGrid> createState() => _PosterGridState();
}

class _PosterGridState extends State<PosterGrid> {
  /// Avoid spamming loadMore for the same list length.
  int _triggeredForLength = -1;

  void _maybeLoadMore(ScrollMetrics metrics) {
    if (widget.onEndReached == null || widget.loadingMore) return;
    // extentAfter == 0 when content fits the viewport — still load more.
    final nearEnd = metrics.extentAfter < 900;
    if (!nearEnd) return;
    if (_triggeredForLength == widget.items.length) return;
    _triggeredForLength = widget.items.length;
    widget.onEndReached!();
  }

  void _scheduleFillCheck() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || widget.onEndReached == null || widget.loadingMore) return;
      final c = widget.controller;
      if (c != null && c.hasClients) {
        _maybeLoadMore(c.position);
        return;
      }
      // No attached controller (browse): if the list is short, ask for another page.
      if (widget.items.isNotEmpty && widget.items.length < 60) {
        if (_triggeredForLength == widget.items.length) return;
        _triggeredForLength = widget.items.length;
        widget.onEndReached!();
      }
    });
  }

  @override
  void initState() {
    super.initState();
    _scheduleFillCheck();
  }

  @override
  void didUpdateWidget(covariant PosterGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.items.length != widget.items.length ||
        oldWidget.loadingMore != widget.loadingMore) {
      if (!widget.loadingMore) {
        _scheduleFillCheck();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final tv = isAndroidTv;
        const hPad = 20.0;
        final minCard = tv ? 148.0 : 148.0;
        final gap = tv ? 14.0 : 12.0;
        final available = (constraints.maxWidth - hPad * 2).clamp(minCard, 4000.0);
        final perRow = ((available + gap) / (minCard + gap)).floor().clamp(3, 10);
        Widget grid = NotificationListener<Notification>(
          onNotification: (n) {
            ScrollMetrics? metrics;
            if (n is ScrollNotification) {
              metrics = n.metrics;
            } else if (n is ScrollMetricsNotification) {
              metrics = n.metrics;
            }
            if (metrics != null) {
              _maybeLoadMore(metrics);
            }
            return false;
          },
          child: CustomScrollView(
            controller: widget.controller,
            cacheExtent: tv ? 280 : 800,
            clipBehavior: tv ? Clip.none : Clip.hardEdge,
            slivers: [
              SliverPadding(
                padding: EdgeInsets.fromLTRB(
                  hPad,
                  8,
                  hPad,
                  tv ? (constraints.maxHeight * 0.38).clamp(160.0, 320.0) : 48,
                ),
                sliver: SliverGrid(
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: perRow,
                    crossAxisSpacing: gap,
                    mainAxisSpacing: gap,
                    childAspectRatio: 2 / 3,
                  ),
                  delegate: SliverChildBuilderDelegate(
                    (context, i) => PosterCard(
                      item: widget.items[i],
                      focusNode: i == 0 ? widget.firstFocus : null,
                    ),
                    childCount: widget.items.length,
                    addAutomaticKeepAlives: false,
                  ),
                ),
              ),
              if (widget.loadingMore)
                const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                ),
            ],
          ),
        );
        if (!tv) return grid;
        return FocusTraversalGroup(
          policy: TvGridFocusPolicy(onMoveUp: widget.onMoveUp),
          child: TvNoJumpScroll(child: grid),
        );
      },
    );
  }
}
