import 'package:flutter/material.dart';

import '../models.dart';
import '../tv.dart';
import 'poster_card.dart';
import 'tv_chrome.dart';

/// Poster wall that fills the available width so the last column is not left empty.
class PosterGrid extends StatelessWidget {
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
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final tv = isAndroidTv;
        const hPad = 20.0;
        final minCard = tv ? 148.0 : 148.0;
        final gap = tv ? 14.0 : 12.0;
        final available = (constraints.maxWidth - hPad * 2).clamp(minCard, 4000.0);
        final perRow = ((available + gap) / (minCard + gap)).floor().clamp(3, 10);
        Widget grid = NotificationListener<ScrollNotification>(
          onNotification: (n) {
            if (n.metrics.pixels >= n.metrics.maxScrollExtent - 600) {
              onEndReached?.call();
            }
            return false;
          },
          child: CustomScrollView(
            controller: controller,
            cacheExtent: tv ? 280 : 800,
            clipBehavior: tv ? Clip.none : Clip.hardEdge,
            slivers: [
              SliverPadding(
                padding: EdgeInsets.fromLTRB(hPad, 8, hPad, tv ? (constraints.maxHeight * 0.38).clamp(160.0, 320.0) : 48),
                sliver: SliverGrid(
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: perRow,
                    crossAxisSpacing: gap,
                    mainAxisSpacing: gap,
                    childAspectRatio: 2 / 3,
                  ),
                  delegate: SliverChildBuilderDelegate(
                    (context, i) => PosterCard(
                      item: items[i],
                      focusNode: i == 0 ? firstFocus : null,
                    ),
                    childCount: items.length,
                    addAutomaticKeepAlives: false,
                  ),
                ),
              ),
              if (loadingMore)
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
          policy: TvGridFocusPolicy(onMoveUp: onMoveUp),
          child: TvNoJumpScroll(child: grid),
        );
      },
    );
  }
}
