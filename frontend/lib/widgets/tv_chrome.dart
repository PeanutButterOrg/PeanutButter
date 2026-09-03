import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../tv.dart';

// Focus policies own every arrow; they must not fall through to geometry.
// ignore_for_file: must_call_super

/// On Android TV, D-pad stays in [body]. Back moves focus to [header].
/// A second Back exits ([root]) or pops the route.
class TvBackScope extends StatefulWidget {
  const TvBackScope({
    super.key,
    required this.header,
    required this.body,
    this.overlapHeader = false,
    this.root = false,
    this.popOnFirstBack = false,
    this.headerLive = false,
    this.headerFocus,
    this.onBackToHeader,
    this.handleBack,
  });

  final Widget header;
  final Widget body;
  final bool overlapHeader;
  final bool root;
  final bool popOnFirstBack;
  final bool headerLive;
  final FocusNode? headerFocus;
  final VoidCallback? onBackToHeader;
  /// Return true to consume Back (e.g. collapse the search field).
  final bool Function()? handleBack;

  @override
  State<TvBackScope> createState() => _TvBackScopeState();
}

class _TvBackScopeState extends State<TvBackScope> {
  final FocusNode _headerHost = FocusNode(
    debugLabel: 'tv-header-host',
    canRequestFocus: false,
    skipTraversal: true,
  );
  bool _headerMode = false;
  DateTime? _exitArmedAt;
  bool _allowPop = false;

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addListener(_syncHeaderMode);
    if (widget.root) {
      TvHomeScroll.enterHeader = _focusHeader;
      TvHomeScroll.exitHeader = _exitHeaderMode;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (TvHomeScroll.pendingHeader) {
          TvHomeScroll.pendingHeader = false;
          _focusHeader();
        }
      });
    }
  }

  void _exitHeaderMode() {
    if (!_headerMode) return;
    setState(() {
      _headerMode = false;
      _exitArmedAt = null;
    });
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_syncHeaderMode);
    if (identical(TvHomeScroll.enterHeader, _focusHeader)) {
      TvHomeScroll.enterHeader = null;
    }
    if (identical(TvHomeScroll.exitHeader, _exitHeaderMode)) {
      TvHomeScroll.exitHeader = null;
    }
    _headerHost.dispose();
    super.dispose();
  }

  bool _focusInHeader(FocusNode? node) {
    if (node == null) return false;
    if (identical(node, _headerHost) || node.ancestors.contains(_headerHost)) return true;
    final label = node.debugLabel ?? '';
    return label.startsWith('header-');
  }

  void _syncHeaderMode() {
    if (!isAndroidTv || !_headerMode || !mounted) return;
    final primary = FocusManager.instance.primaryFocus;
    if (_focusInHeader(primary)) return;
    setState(() => _headerMode = false);
    _exitArmedAt = null;
  }

  void _focusHeader() {
    setState(() => _headerMode = true);
    _exitArmedAt = DateTime.now();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (widget.headerFocus != null) {
        widget.headerFocus!.requestFocus();
      } else if (widget.root) {
        TvHeaderFocus.movies.requestFocus();
      } else {
        for (final node in _headerHost.descendants) {
          if (node.skipTraversal || !node.canRequestFocus) continue;
          node.requestFocus();
          break;
        }
      }
      if (widget.root) TvHomeScroll.toTop?.call();
      widget.onBackToHeader?.call();
    });
  }

  bool get _exitArmed {
    final armed = _exitArmedAt;
    if (armed == null) return false;
    return DateTime.now().difference(armed) < const Duration(seconds: 3);
  }

  void _exitApp() {
    SystemNavigator.pop();
  }

  void _popRoute() {
    if (!mounted) return;
    setState(() => _allowPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      } else if (mounted) {
        setState(() => _allowPop = false);
      }
    });
  }

  void _onBack() {
    if (!isAndroidTv) return;
    if (widget.handleBack?.call() == true) return;
    if (TvPreviewLock.dismiss != null) {
      TvPreviewLock.dismiss!();
      return;
    }
    if (widget.root) {
      if (!_headerMode) {
        _focusHeader();
        return;
      }
      _exitApp();
      return;
    }
    final inHeader = _headerMode || _focusInHeader(FocusManager.instance.primaryFocus);
    if (inHeader || _exitArmed) {
      _popRoute();
      return;
    }
    _focusHeader();
  }

  @override
  Widget build(BuildContext context) {
    final header = Focus(
      focusNode: _headerHost,
      canRequestFocus: false,
      skipTraversal: true,
      descendantsAreFocusable: !isAndroidTv || _headerMode || widget.headerLive || widget.popOnFirstBack,
      descendantsAreTraversable: !isAndroidTv || _headerMode || widget.headerLive || widget.popOnFirstBack,
      child: widget.header,
    );

    if (!isAndroidTv) {
      if (widget.overlapHeader) {
        return Stack(
          fit: StackFit.expand,
          children: [
            Positioned.fill(child: widget.body),
            Positioned(top: 0, left: 0, right: 0, child: header),
          ],
        );
      }
      return Column(
        children: [
          header,
          Expanded(child: widget.body),
        ],
      );
    }

    final body = Focus(
      canRequestFocus: false,
      skipTraversal: true,
      descendantsAreFocusable: !isAndroidTv || !_headerMode || widget.headerLive,
      descendantsAreTraversable: !isAndroidTv || !_headerMode || widget.headerLive,
      child: widget.body,
    );

    final stacked = widget.overlapHeader
        ? Stack(
            fit: StackFit.expand,
            children: [
              Positioned.fill(child: body),
              Positioned(top: 0, left: 0, right: 0, child: header),
            ],
          )
        : Column(
            children: [
              header,
              Expanded(child: body),
            ],
          );

    return PopScope(
      canPop: !isAndroidTv || _allowPop,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _onBack();
      },
      child: stacked,
    );
  }
}

/// Maps D-pad arrows to focus movement so scrollables cannot swallow Up/Down.
class TvFocus extends StatelessWidget {
  const TvFocus({super.key, required this.child, this.allowHorizontal = true});

  final Widget child;
  final bool allowHorizontal;

  @override
  Widget build(BuildContext context) {
    if (!isAndroidTv) return child;
    return Shortcuts(
      shortcuts: {
        const SingleActivator(LogicalKeyboardKey.arrowUp): const DirectionalFocusIntent(TraversalDirection.up),
        const SingleActivator(LogicalKeyboardKey.arrowDown): const DirectionalFocusIntent(TraversalDirection.down),
        const SingleActivator(LogicalKeyboardKey.arrowLeft): allowHorizontal
            ? const DirectionalFocusIntent(TraversalDirection.left)
            : const DoNothingIntent(),
        const SingleActivator(LogicalKeyboardKey.arrowRight): allowHorizontal
            ? const DirectionalFocusIntent(TraversalDirection.right)
            : const DoNothingIntent(),
      },
      child: TvNoJumpScroll(child: child),
    );
  }
}

/// Compact header action that D-pad can reach after Movies / Series / Anime.
class TvHeaderButton extends StatelessWidget {
  const TvHeaderButton({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.focusNode,
    this.busy = false,
    this.onMoveDown,
    this.onMoveLeft,
    this.onMoveRight,
  });

  final String tooltip;
  final Widget icon;
  final VoidCallback onPressed;
  final FocusNode? focusNode;
  final bool busy;
  final VoidCallback? onMoveDown;
  final VoidCallback? onMoveLeft;
  final VoidCallback? onMoveRight;

  @override
  Widget build(BuildContext context) {
    Widget button = IconButton(
      focusNode: focusNode,
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      onPressed: busy ? () {} : onPressed,
      icon: busy
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : icon,
    );
    final shortcuts = <ShortcutActivator, Intent>{
      if (onMoveDown != null) const SingleActivator(LogicalKeyboardKey.arrowDown): const _HeaderDownIntent(),
      if (onMoveLeft != null) const SingleActivator(LogicalKeyboardKey.arrowLeft): const _HeaderLeftIntent(),
      if (onMoveRight != null) const SingleActivator(LogicalKeyboardKey.arrowRight): const _HeaderRightIntent(),
    };
    if (shortcuts.isNotEmpty) {
      button = Shortcuts(
        shortcuts: shortcuts,
        child: Actions(
          actions: {
            _HeaderDownIntent: CallbackAction<_HeaderDownIntent>(
              onInvoke: (_) {
                onMoveDown?.call();
                return null;
              },
            ),
            _HeaderLeftIntent: CallbackAction<_HeaderLeftIntent>(
              onInvoke: (_) {
                onMoveLeft?.call();
                return null;
              },
            ),
            _HeaderRightIntent: CallbackAction<_HeaderRightIntent>(
              onInvoke: (_) {
                onMoveRight?.call();
                return null;
              },
            ),
          },
          child: button,
        ),
      );
    }
    return TvFocus(
      allowHorizontal: onMoveLeft == null && onMoveRight == null,
      child: button,
    );
  }
}

class _HeaderDownIntent extends Intent {
  const _HeaderDownIntent();
}

class _HeaderLeftIntent extends Intent {
  const _HeaderLeftIntent();
}

class _HeaderRightIntent extends Intent {
  const _HeaderRightIntent();
}

/// Top bar only: Movies → Series → Anime → Refresh → Search → Settings.
class TvBarFocusPolicy extends WidgetOrderTraversalPolicy {
  TvBarFocusPolicy({required this.nodes, this.onMoveDown});

  final List<FocusNode> nodes;
  final VoidCallback? onMoveDown;

  /// Top bar is a closed chain so geometry traversal is never used.
  @override
  bool inDirection(FocusNode currentNode, TraversalDirection direction) {
    final inBar = nodes.any((node) {
      if (identical(currentNode, node)) return true;
      if (currentNode.ancestors.contains(node)) return true;
      return currentNode.debugLabel != null && currentNode.debugLabel == node.debugLabel;
    });
    if (!inBar) return super.inDirection(currentNode, direction);
    if (direction == TraversalDirection.down) {
      onMoveDown?.call();
      return true;
    }
    if (direction == TraversalDirection.up) return true;
    TvHeaderFocus.step(
      nodes,
      direction == TraversalDirection.right ? 1 : -1,
    );
    return true;
  }
}

bool _tvIsSeeAll(FocusNode node) => node.debugLabel == 'see-all';

Offset? _tvOrigin(FocusNode node) {
  final ctx = node.context;
  if (ctx == null || !ctx.mounted) return null;
  final box = ctx.findRenderObject();
  if (box is! RenderBox || !box.hasSize || !box.attached) return null;
  return box.localToGlobal(Offset.zero);
}

void _tvFocus(FocusNode node, {double alignment = 0.15, bool belowHeader = false, bool centerRow = false}) {
  node.requestFocus();
  if (centerRow) return;
  final ctx = node.context;
  if (ctx != null) {
    tvEnsureVisible(ctx, alignment: alignment, belowHeader: belowHeader);
  }
}

void _tvFocusRow(FocusNode node) {
  node.requestFocus();
  final ctx = node.context;
  if (ctx != null) tvEnsureVisibleAxis(ctx, axis: Axis.horizontal, alignment: 0.42);
}

List<FocusNode> _tvLabeled(FocusNode current, bool Function(FocusNode) test) {
  final ctx = current.context;
  if (ctx == null) return const [];
  final scope = FocusScope.of(ctx);
  final seen = <FocusNode>{};
  final out = <FocusNode>[];
  for (final node in [...scope.descendants, ...scope.traversalDescendants]) {
    if (!seen.add(node)) continue;
    if (!test(node)) continue;
    out.add(node);
  }
  return out;
}

List<FocusNode> _tvRowStream(FocusNode from, String label, {double band = 140}) {
  final origin = _tvOrigin(from);
  if (origin == null) return const [];
  final nodes = _tvLabeled(from, (n) => n.debugLabel == label).where((n) {
    final pos = _tvOrigin(n);
    return pos != null && (pos.dy - origin.dy).abs() < band;
  }).toList();
  nodes.sort((a, b) {
    final ax = _tvOrigin(a)?.dx ?? 0;
    final bx = _tvOrigin(b)?.dx ?? 0;
    return ax.compareTo(bx);
  });
  return nodes;
}

FocusNode? _tvStreamNeighbor(FocusNode current, String label, {required bool right}) {
  final row = _tvRowStream(current, label);
  final i = row.indexWhere((n) => identical(n, current));
  if (i < 0) return null;
  if (right && i + 1 < row.length) return row[i + 1];
  if (!right && i > 0) return row[i - 1];
  return null;
}

bool _tvHorizontal(TraversalDirection direction) =>
    direction == TraversalDirection.left || direction == TraversalDirection.right;

/// Move focus to the first poster of a rail and scroll the row into view.
void _tvFocusRailPosters(TvHomeRail rail) {
  rail.prepareFirst();
  rail.reveal();
  if (rail.firstPoster.canRequestFocus) {
    rail.firstPoster.requestFocus();
  }
}

/// Focus a row's "See all" and keep that stream in view.
void _tvFocusRailSeeAll(TvHomeRail rail) {
  rail.reveal();
  if (rail.seeAll.canRequestFocus) {
    rail.seeAll.requestFocus();
  }
}

void _tvFocusBannerDetails() {
  TvHomeScroll.toTop?.call();
  final node = TvHeaderFocus.bannerDetails;
  if (node.canRequestFocus) node.requestFocus();
}

/// Vertical zigzag through home:
/// Details → See all → first card → next See all → first card → …
/// Left/Right on See all jumps into that row's first card.
/// Left/Right on cards moves within the row.
class TvHomeFocusPolicy extends ReadingOrderTraversalPolicy {
  @override
  bool inDirection(FocusNode currentNode, TraversalDirection direction) {
    final label = currentNode.debugLabel;
    final right = direction == TraversalDirection.right;

    // ── Banner Details ────────────────────────────────────────────────────────
    if (label == 'banner-details' && _tvHorizontal(direction)) return true;

    if (label == 'banner-details' && direction == TraversalDirection.up) {
      TvHomeScroll.enterHeader?.call();
      return true;
    }

    if (label == 'banner-details' && direction == TraversalDirection.down) {
      TvHomeScroll.toTop?.call();
      final rails = TvHomeRails.all;
      if (rails.isNotEmpty) _tvFocusRailSeeAll(rails.first);
      return true;
    }

    // ── Posters ───────────────────────────────────────────────────────────────
    if (label == 'poster' && _tvHorizontal(direction)) {
      final next = _tvStreamNeighbor(currentNode, 'poster', right: right);
      if (next != null) _tvFocusRow(next);
      return true;
    }

    if (label == 'poster' && direction == TraversalDirection.down) {
      final rail = TvHomeRails.byPoster(currentNode);
      final next = rail == null ? null : TvHomeRails.after(rail);
      if (next != null) _tvFocusRailSeeAll(next);
      return true;
    }

    if (label == 'poster' && direction == TraversalDirection.up) {
      final rail = TvHomeRails.byPoster(currentNode);
      if (rail != null) {
        _tvFocusRailSeeAll(rail);
      } else {
        _tvFocusBannerDetails();
      }
      return true;
    }

    // ── See All ───────────────────────────────────────────────────────────────
    if (_tvIsSeeAll(currentNode) && _tvHorizontal(direction)) {
      // Left or Right → first card in the recycler under this See all
      final rail = TvHomeRails.bySeeAll(currentNode);
      if (rail != null) _tvFocusRailPosters(rail);
      return true;
    }

    if (_tvIsSeeAll(currentNode) && direction == TraversalDirection.down) {
      final rail = TvHomeRails.bySeeAll(currentNode);
      if (rail != null) _tvFocusRailPosters(rail);
      return true;
    }

    if (_tvIsSeeAll(currentNode) && direction == TraversalDirection.up) {
      final rail = TvHomeRails.bySeeAll(currentNode);
      final prev = rail == null ? null : TvHomeRails.before(rail);
      if (prev != null) {
        _tvFocusRailPosters(prev);
      } else {
        _tvFocusBannerDetails();
      }
      return true;
    }

    return super.inDirection(currentNode, direction);
  }
}

/// D-pad navigation for poster grids (Search / Catalog / See all).
class TvGridFocusPolicy extends ReadingOrderTraversalPolicy {
  TvGridFocusPolicy({this.onMoveUp});

  /// Called when Up is pressed on the top row (e.g. return to the search field).
  final VoidCallback? onMoveUp;

  @override
  bool inDirection(FocusNode currentNode, TraversalDirection direction) {
    if (currentNode.debugLabel != 'poster') {
      return super.inDirection(currentNode, direction);
    }

    final posters = _tvLabeled(currentNode, (n) => n.debugLabel == 'poster');
    if (posters.isEmpty) return true;

    posters.sort((a, b) {
      final ay = _tvOrigin(a)?.dy ?? 0;
      final by = _tvOrigin(b)?.dy ?? 0;
      final dy = ay.compareTo(by);
      if (dy != 0) return dy;
      final ax = _tvOrigin(a)?.dx ?? 0;
      final bx = _tvOrigin(b)?.dx ?? 0;
      return ax.compareTo(bx);
    });

    final i = posters.indexWhere((n) => identical(n, currentNode));
    if (i < 0) return true;

    final origin = _tvOrigin(currentNode);
    if (origin == null) return true;

    FocusNode? pick;
    if (_tvHorizontal(direction)) {
      final right = direction == TraversalDirection.right;
      final row = posters.where((n) {
        final y = _tvOrigin(n)?.dy;
        return y != null && (y - origin.dy).abs() < 72;
      }).toList()
        ..sort((a, b) => (_tvOrigin(a)?.dx ?? 0).compareTo(_tvOrigin(b)?.dx ?? 0));
      final ri = row.indexWhere((n) => identical(n, currentNode));
      if (ri < 0) return true;
      if (right && ri + 1 < row.length) pick = row[ri + 1];
      if (!right && ri > 0) pick = row[ri - 1];
    } else if (direction == TraversalDirection.down) {
      var best = double.infinity;
      for (final n in posters) {
        final pos = _tvOrigin(n);
        if (pos == null || pos.dy <= origin.dy + 40) continue;
        final score = (pos.dy - origin.dy) * 1000 + (pos.dx - origin.dx).abs();
        if (score < best) {
          best = score;
          pick = n;
        }
      }
    } else if (direction == TraversalDirection.up) {
      var best = double.infinity;
      for (final n in posters) {
        final pos = _tvOrigin(n);
        if (pos == null || pos.dy >= origin.dy - 40) continue;
        final score = (origin.dy - pos.dy) * 1000 + (pos.dx - origin.dx).abs();
        if (score < best) {
          best = score;
          pick = n;
        }
      }
      if (pick == null) {
        onMoveUp?.call();
        return true;
      }
    }

    if (pick != null) {
      _tvFocus(pick, alignment: 0.35, belowHeader: true);
    }
    return true;
  }
}

const _kDetailActions = {'detail-play', 'detail-watched', 'detail-favorite'};

/// Title page: actions → Cast stream → seasons. Left/Right stay in the current stream.
class TvDetailFocusPolicy extends ReadingOrderTraversalPolicy {
  @override
  bool inDirection(FocusNode currentNode, TraversalDirection direction) {
    final label = currentNode.debugLabel ?? '';
    final right = direction == TraversalDirection.right;

    if (_kDetailActions.contains(label) && _tvHorizontal(direction)) {
      final next = _tvActionNeighbor(currentNode, right: right);
      if (next != null) _tvFocus(next, alignment: 0.2);
      return true;
    }

    if (_kDetailActions.contains(label) && direction == TraversalDirection.up) {
      final back = _tvLabeled(currentNode, (n) => n.debugLabel == 'detail-back');
      if (back.isNotEmpty) {
        _tvFocus(back.first, alignment: 0);
        return true;
      }
    }

    if (label == 'detail-back' && direction == TraversalDirection.down) {
      final play = _tvLabeled(currentNode, (n) => n.debugLabel == 'detail-play');
      final watched = _tvLabeled(currentNode, (n) => n.debugLabel == 'detail-watched');
      final target = play.isNotEmpty ? play.first : (watched.isNotEmpty ? watched.first : null);
      if (target != null) {
        _tvFocus(target, alignment: 0);
        return true;
      }
    }

    if (label == 'detail-back' && _tvHorizontal(direction)) {
      return true;
    }

    if (_kDetailActions.contains(label) && direction == TraversalDirection.down) {
      final cast = _tvLabeled(currentNode, (n) => n.debugLabel == 'cast');
      if (cast.isNotEmpty) {
        cast.sort((a, b) => (_tvOrigin(a)?.dx ?? 0).compareTo(_tvOrigin(b)?.dx ?? 0));
        _tvFocus(cast.first, alignment: 0.2);
        return true;
      }
      final seasons = _tvLabeled(currentNode, (n) => n.debugLabel == 'season');
      if (seasons.isNotEmpty) {
        _tvFocus(seasons.first, alignment: 0.2);
        return true;
      }
      final episode = _tvLabeled(currentNode, (n) => n.debugLabel == 'episode');
      if (episode.isNotEmpty) {
        _tvFocus(episode.first, alignment: 0.2);
        return true;
      }
      return true;
    }

    if (label == 'cast' && _tvHorizontal(direction)) {
      final next = _tvStreamNeighbor(currentNode, 'cast', right: right);
      if (next != null) _tvFocusRow(next);
      return true;
    }

    if (label == 'cast' && direction == TraversalDirection.up) {
      final play = _tvLabeled(currentNode, (n) => n.debugLabel == 'detail-play');
      final watched = _tvLabeled(currentNode, (n) => n.debugLabel == 'detail-watched');
      final target = play.isNotEmpty ? play.first : (watched.isNotEmpty ? watched.first : null);
      if (target != null) {
        _tvFocus(target, alignment: 0);
        return true;
      }
    }

    if (label == 'cast' && direction == TraversalDirection.down) {
      final seasons = _tvLabeled(currentNode, (n) => n.debugLabel == 'season');
      if (seasons.isNotEmpty) {
        _tvFocus(seasons.first, alignment: 0.2);
        return true;
      }
      final episode = _tvLabeled(currentNode, (n) => n.debugLabel == 'episode');
      if (episode.isNotEmpty) {
        _tvFocus(episode.first, alignment: 0.2);
        return true;
      }
      return true;
    }

    if (label == 'season' && _tvHorizontal(direction)) {
      final next = _tvStreamNeighbor(currentNode, 'season', right: right);
      if (next != null) _tvFocusRow(next);
      return true;
    }

    if (label == 'season' && direction == TraversalDirection.up) {
      final cast = _tvLabeled(currentNode, (n) => n.debugLabel == 'cast');
      if (cast.isNotEmpty) {
        cast.sort((a, b) => (_tvOrigin(a)?.dx ?? 0).compareTo(_tvOrigin(b)?.dx ?? 0));
        _tvFocus(cast.first, alignment: 0.2);
        return true;
      }
      final play = _tvLabeled(currentNode, (n) => n.debugLabel == 'detail-play');
      final watched = _tvLabeled(currentNode, (n) => n.debugLabel == 'detail-watched');
      final target = play.isNotEmpty ? play.first : (watched.isNotEmpty ? watched.first : null);
      if (target != null) {
        _tvFocus(target, alignment: 0);
        return true;
      }
    }

    if (label == 'season' && direction == TraversalDirection.down) {
      final episode = _tvLabeled(currentNode, (n) => n.debugLabel == 'episode');
      if (episode.isNotEmpty) {
        _tvFocus(episode.first, alignment: 0.2);
        return true;
      }
      return true;
    }

    if (label == 'episode' && _tvHorizontal(direction)) {
      return true;
    }

    if (label == 'episode' && direction == TraversalDirection.up) {
      final origin = _tvOrigin(currentNode);
      final episodes = _tvLabeled(currentNode, (n) => n.debugLabel == 'episode');
      FocusNode? prev;
      var bestY = double.negativeInfinity;
      for (final node in episodes) {
        final y = _tvOrigin(node)?.dy;
        if (y == null || origin == null || y >= origin.dy - 8) continue;
        if (y >= bestY) {
          bestY = y;
          prev = node;
        }
      }
      if (prev != null) {
        _tvFocus(prev, alignment: 0.2);
        return true;
      }
      final seasons = _tvLabeled(currentNode, (n) => n.debugLabel == 'season');
      if (seasons.isNotEmpty) {
        _tvFocus(seasons.first, alignment: 0.2);
        return true;
      }
      final cast = _tvLabeled(currentNode, (n) => n.debugLabel == 'cast');
      if (cast.isNotEmpty) {
        cast.sort((a, b) => (_tvOrigin(a)?.dx ?? 0).compareTo(_tvOrigin(b)?.dx ?? 0));
        _tvFocus(cast.first, alignment: 0.2);
        return true;
      }
    }

    return super.inDirection(currentNode, direction);
  }
}

FocusNode? _tvActionNeighbor(FocusNode current, {required bool right}) {
  final actions = _tvLabeled(current, (n) => _kDetailActions.contains(n.debugLabel ?? ''));
  actions.sort((a, b) => (_tvOrigin(a)?.dx ?? 0).compareTo(_tvOrigin(b)?.dx ?? 0));
  final i = actions.indexWhere((n) => identical(n, current));
  if (i < 0) return null;
  if (right && i + 1 < actions.length) return actions[i + 1];
  if (!right && i > 0) return actions[i - 1];
  return null;
}

