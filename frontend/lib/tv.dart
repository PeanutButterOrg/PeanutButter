import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

bool get isAndroidTv => !kIsWeb && Platform.isAndroid;

/// Optional Back interceptor used when a modal overlay is open.
class TvPreviewLock {
  static VoidCallback? dismiss;
}

class TvHomeScroll {
  static void Function()? toTop;
  static void Function()? toBanner;
  static void Function()? enterHeader;
  static void Function()? exitHeader;
  static bool pendingHeader = false;
}

/// Lets a focused poster ask its home stream to scroll into the center of the screen.
class TvFocusReveal extends InheritedWidget {
  const TvFocusReveal({super.key, required this.onReveal, required super.child});

  final VoidCallback onReveal;

  static VoidCallback? maybeOf(BuildContext context) {
    return context.getInheritedWidgetOfExactType<TvFocusReveal>()?.onReveal;
  }

  @override
  bool updateShouldNotify(TvFocusReveal oldWidget) => onReveal != oldWidget.onReveal;
}

class TvHeaderFocus {
  static final FocusNode movies = FocusNode(debugLabel: 'header-movies');
  static final FocusNode series = FocusNode(debugLabel: 'header-series');
  static final FocusNode anime = FocusNode(debugLabel: 'header-anime');
  static final FocusNode refresh = FocusNode(debugLabel: 'header-refresh');
  static final FocusNode search = FocusNode(debugLabel: 'header-search-btn');
  static final FocusNode settings = FocusNode(debugLabel: 'header-settings');
  static final FocusNode catalogSort = FocusNode(debugLabel: 'header-catalog-sort');
  static final FocusNode bannerDetails = FocusNode(debugLabel: 'banner-details');

  static List<FocusNode> get homeBar => [movies, series, anime, refresh, search, settings];

  static FocusNode forKind(String kind) {
    return switch (kind) {
      'SERIES' => series,
      'ANIME' => anime,
      _ => movies,
    };
  }

  static void step(List<FocusNode> nodes, int delta) {
    if (nodes.isEmpty) return;
    final primary = FocusManager.instance.primaryFocus;
    var i = -1;
    for (var k = 0; k < nodes.length; k++) {
      final node = nodes[k];
      if (identical(primary, node)) {
        i = k;
        break;
      }
      if (primary != null && primary.ancestors.contains(node)) {
        i = k;
        break;
      }
      if (primary?.debugLabel != null && primary!.debugLabel == node.debugLabel) {
        i = k;
        break;
      }
    }
    if (i < 0) i = 0;
    final next = (i + delta).clamp(0, nodes.length - 1);
    if (next == i) return;
    nodes[next].requestFocus();
  }
}

/// Ordered home streams so D-pad zigzag never depends on on-screen geometry.
class TvHomeRail {
  TvHomeRail({
    required this.index,
    required this.seeAll,
    required this.firstPoster,
    required this.reveal,
    required this.prepareFirst,
  });

  final int index;
  final FocusNode seeAll;
  final FocusNode firstPoster;
  final VoidCallback reveal;
  final VoidCallback prepareFirst;
}

class TvHomeRails {
  static final List<TvHomeRail> _rails = [];

  static List<TvHomeRail> get all {
    final copy = [..._rails]..sort((a, b) => a.index.compareTo(b.index));
    return copy;
  }

  static void attach(TvHomeRail rail) {
    _rails.removeWhere((r) => r.index == rail.index || identical(r.seeAll, rail.seeAll));
    _rails.add(rail);
  }

  static void detach(TvHomeRail rail) {
    _rails.remove(rail);
  }

  static TvHomeRail? bySeeAll(FocusNode node) {
    for (final rail in all) {
      if (identical(rail.seeAll, node)) return rail;
    }
    return null;
  }

  static TvHomeRail? byPoster(FocusNode node) {
    final ctx = node.context;
    if (ctx != null && ctx.mounted) {
      final scoped = TvHomeRailScope.maybeOf(ctx);
      if (scoped != null) return scoped;
    }
    for (final rail in all) {
      if (identical(rail.firstPoster, node)) return rail;
    }
    return null;
  }

  static TvHomeRail? after(TvHomeRail rail) {
    final rails = all;
    final i = rails.indexWhere((r) => identical(r, rail) || r.index == rail.index);
    if (i < 0 || i + 1 >= rails.length) return null;
    return rails[i + 1];
  }

  static TvHomeRail? before(TvHomeRail rail) {
    final rails = all;
    final i = rails.indexWhere((r) => identical(r, rail) || r.index == rail.index);
    if (i <= 0) return null;
    return rails[i - 1];
  }
}

class TvHomeRailScope extends InheritedWidget {
  const TvHomeRailScope({super.key, required this.rail, required super.child});

  final TvHomeRail rail;

  static TvHomeRail? maybeOf(BuildContext context) {
    return context.getInheritedWidgetOfExactType<TvHomeRailScope>()?.rail;
  }

  @override
  bool updateShouldNotify(TvHomeRailScope oldWidget) => !identical(rail, oldWidget.rail);
}

/// Blocks Flutter's implicit `showOnScreen` (duration 0) so D-pad focus does not
/// jump the list before [tvAnimateReveal] runs. Animated ensureVisible still works.
class TvNoJumpScroll extends SingleChildRenderObjectWidget {
  const TvNoJumpScroll({super.key, required Widget super.child});

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderTvNoJumpScroll();
}

class _RenderTvNoJumpScroll extends RenderProxyBox {
  @override
  void showOnScreen({
    RenderObject? descendant,
    Rect? rect,
    Duration duration = Duration.zero,
    Curve curve = Curves.ease,
  }) {
    // Block ALL automatic showOnScreen calls — our focus policy drives all scrolls.
    // This prevents Flutter's focus engine from issuing a competing instant-jump
    // before tvAnimateReveal has a chance to run.
    return;
  }
}

/// Home poster strip on TV. Cards fill this row; do not shrink them to add empty padding.
class TvPosterDim {
  static const width = 152.0;
  static const gap = 16.0;
  static const extent = 168.0;
  static const rowHeight = 252.0;
  static const scale = 1.12;
  static const streamHeight = 310.0;
}

/// Overlay KindSwitch row on home; keep focused streams below this.
const kTvOverlayHeader = 88.0;

/// Slack so the last stream can sit above the bottom edge.
double tvCenterBottomPad(BuildContext context) {
  final height = MediaQuery.sizeOf(context).height;
  final pad = (height - kTvOverlayHeader) / 2 - TvPosterDim.streamHeight / 2 + 72;
  return pad.clamp(200.0, 380.0);
}

void tvEnsureVisible(BuildContext context, {double alignment = 0.15, bool belowHeader = false, bool centerRow = false}) {
  if (!isAndroidTv) {
    Scrollable.ensureVisible(
      context,
      alignment: alignment,
      alignmentPolicy: ScrollPositionAlignmentPolicy.explicit,
      duration: Duration.zero,
    );
    return;
  }
  if (centerRow) {
    tvCenterInView(context, overlayHeader: true);
    return;
  }
  var align = alignment;
  if (belowHeader) {
    final height = MediaQuery.sizeOf(context).height;
    align = height > 0 ? (160 / height).clamp(0.2, 0.36) : 0.24;
  }
  tvAnimateReveal(context, axis: Axis.vertical, alignment: align, leisurely: true);
}

/// Scrolls the focused item to the optical center of the screen.
void tvCenterInView(BuildContext context, {bool overlayHeader = false}) {
  tvAnimateReveal(
    context,
    axis: Axis.vertical,
    center: true,
    header: overlayHeader ? kTvOverlayHeader : 0,
    leisurely: true,
  );
}

/// Directional scroll to [context] on one axis so D-pad up/down feels like moving the page.
void tvAnimateReveal(
  BuildContext context, {
  required Axis axis,
  double alignment = 0.0,
  bool center = false,
  double header = 0,
  bool leisurely = false,
}) {
  if (!isAndroidTv) return;
  final scrollable = Scrollable.maybeOf(context, axis: axis);
  if (scrollable == null) return;
  final box = context.findRenderObject();
  if (box is! RenderBox || !box.hasSize || !box.attached) return;
  RenderAbstractViewport? viewport;
  var node = box.parent;
  while (node != null) {
    if (node is RenderViewportBase && node.axis == axis) {
      viewport = node;
      break;
    }
    node = node.parent;
  }
  viewport ??= RenderAbstractViewport.maybeOf(box);
  if (viewport == null) return;

  var align = alignment;
  if (center) {
    final vp = scrollable.position.viewportDimension;
    final child = axis == Axis.vertical ? box.size.height : box.size.width;
    final span = (vp - child).clamp(1.0, double.infinity);
    align = (0.5 + header / (2 * span)).clamp(0.0, 1.0);
  }

  final revealed = viewport.getOffsetToReveal(box, align);
  final target = revealed.offset.clamp(
    scrollable.position.minScrollExtent,
    scrollable.position.maxScrollExtent,
  );
  final current = scrollable.position.pixels;
  final delta = (target - current).abs();
  if (delta < 1.5) return;
  final ms = leisurely
      ? (280 + delta * 0.45).clamp(320, 560).round()
      : (120 + delta * 0.28).clamp(160, 320).round();
  scrollable.position.animateTo(
    target,
    duration: Duration(milliseconds: ms),
    curve: Curves.easeInOutCubic,
  );
}

/// Scrolls only one axis so left/right in a poster row cannot tuck the row title under the overlay.
void tvEnsureVisibleAxis(
  BuildContext context, {
  required Axis axis,
  double alignment = 0.12,
}) {
  tvAnimateReveal(context, axis: axis, alignment: alignment);
}
