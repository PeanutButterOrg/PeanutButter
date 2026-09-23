import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'tv.dart';

/// Directional D-pad axes.
enum TvNavDir { up, down, left, right }

/// Where a move should go — id, live resolver, focus node, or side-effect.
class TvNavEdge {
  const TvNavEdge._({this.id, this.node, this.resolve, this.run});

  const TvNavEdge.id(String this.id)
      : node = null,
        resolve = null,
        run = null;

  const TvNavEdge.node(FocusNode this.node)
      : id = null,
        resolve = null,
        run = null;

  const TvNavEdge.resolve(Object? Function() this.resolve)
      : id = null,
        node = null,
        run = null;

  const TvNavEdge.action(VoidCallback this.run)
      : id = null,
        node = null,
        resolve = null;

  /// Stay put (consume the key).
  static const TvNavEdge stay = TvNavEdge._();

  final String? id;
  final FocusNode? node;
  final Object? Function()? resolve;
  final VoidCallback? run;

  bool get isStay => id == null && node == null && resolve == null && run == null;
}

/// Per-node directional map.
class TvNavLinks {
  const TvNavLinks({this.up, this.down, this.left, this.right});

  final TvNavEdge? up;
  final TvNavEdge? down;
  final TvNavEdge? left;
  final TvNavEdge? right;

  TvNavEdge? operator [](TvNavDir dir) => switch (dir) {
        TvNavDir.up => up,
        TvNavDir.down => down,
        TvNavDir.left => left,
        TvNavDir.right => right,
      };

  TvNavLinks copyWith({
    TvNavEdge? up,
    TvNavEdge? down,
    TvNavEdge? left,
    TvNavEdge? right,
  }) {
    return TvNavLinks(
      up: up ?? this.up,
      down: down ?? this.down,
      left: left ?? this.left,
      right: right ?? this.right,
    );
  }
}

/// Pluggable screen/zone behavior when no explicit edge is set.
abstract class TvNavStrategy {
  /// Return true if the move was handled.
  bool handle(TvNavController nav, FocusNode current, TvNavDir dir);
}

/// Central D-pad graph for one view (screen / dialog / overlay).
class TvNavController extends ChangeNotifier {
  TvNavController({List<TvNavStrategy>? strategies})
      : strategies = List<TvNavStrategy>.unmodifiable(strategies ?? const []);

  final List<TvNavStrategy> strategies;
  final Map<String, FocusNode> _byId = {};
  final Map<FocusNode, String> _idByNode = {};
  final Map<String, TvNavLinks> _links = {};
  final Map<String, VoidCallback> _onFocus = {};

  /// Register (or rebind) a focusable target.
  void register(
    String id,
    FocusNode node, {
    TvNavLinks? links,
    VoidCallback? onFocus,
  }) {
    final prev = _byId[id];
    if (prev != null && !identical(prev, node)) {
      _idByNode.remove(prev);
    }
    _byId[id] = node;
    _idByNode[node] = id;
    if (links != null) _links[id] = links;
    if (onFocus != null) _onFocus[id] = onFocus;
  }

  void unregister(String id) {
    final node = _byId.remove(id);
    if (node != null) _idByNode.remove(node);
    _links.remove(id);
    _onFocus.remove(id);
  }

  void unregisterNode(FocusNode node) {
    final id = _idByNode.remove(node);
    if (id == null) return;
    _byId.remove(id);
    _links.remove(id);
    _onFocus.remove(id);
  }

  void setLinks(String id, TvNavLinks links) {
    _links[id] = links;
  }

  void patchLinks(
    String id, {
    TvNavEdge? up,
    TvNavEdge? down,
    TvNavEdge? left,
    TvNavEdge? right,
  }) {
    final cur = _links[id] ?? const TvNavLinks();
    _links[id] = cur.copyWith(up: up, down: down, left: left, right: right);
  }

  String? idOf(FocusNode? node) {
    if (node == null) return null;
    final direct = _idByNode[node];
    if (direct != null) return direct;
    for (final e in _idByNode.entries) {
      if (identical(e.key, node) || node.ancestors.contains(e.key)) return e.value;
    }
    // Fallback: debugLabel used as id (poster cards, etc.).
    final label = node.debugLabel;
    if (label != null && label.isNotEmpty && _byId.containsKey(label)) return label;
    return label;
  }

  FocusNode? nodeOf(String id) => _byId[id];

  /// Focus [id] and run its reveal callback.
  bool focus(String id, {bool reveal = true}) {
    final node = _byId[id];
    if (node == null || !node.canRequestFocus) return false;
    node.requestFocus();
    if (reveal) _onFocus[id]?.call();
    return true;
  }

  bool focusNode(FocusNode node, {VoidCallback? reveal}) {
    if (!node.canRequestFocus) return false;
    node.requestFocus();
    reveal?.call();
    final id = _idByNode[node];
    if (id != null) _onFocus[id]?.call();
    return true;
  }

  /// Move from the current primary focus.
  bool move(TvNavDir dir) {
    if (!isAndroidTv) return false;
    final current = FocusManager.instance.primaryFocus;
    if (current == null) return false;

    final id = idOf(current);
    if (id != null) {
      final edge = _links[id]?[dir];
      if (edge != null) return _applyEdge(edge);
    }

    for (final strategy in strategies) {
      if (strategy.handle(this, current, dir)) return true;
    }
    // Consume the key so scrollables never steal D-pad.
    return true;
  }

  bool _applyEdge(TvNavEdge edge) {
    if (edge.run != null) {
      edge.run!();
      return true;
    }
    if (edge.isStay) return true;

    Object? target = edge.node ?? edge.id;
    if (edge.resolve != null) target = edge.resolve!();

    if (target == null) return true;
    if (target is VoidCallback) {
      target();
      return true;
    }
    if (target is FocusNode) return focusNode(target);
    if (target is String) return focus(target);
    return true;
  }

  /// Wire a horizontal row: left/right between neighbors + shared exits.
  void wireRow(
    List<String> ids, {
    TvNavEdge? exitUp,
    TvNavEdge? exitDown,
    TvNavEdge? exitLeft,
    TvNavEdge? exitRight,
  }) {
    for (var i = 0; i < ids.length; i++) {
      final id = ids[i];
      final cur = _links[id] ?? const TvNavLinks();
      _links[id] = cur.copyWith(
        left: i > 0 ? TvNavEdge.id(ids[i - 1]) : (exitLeft ?? cur.left ?? TvNavEdge.stay),
        right: i + 1 < ids.length
            ? TvNavEdge.id(ids[i + 1])
            : (exitRight ?? cur.right ?? TvNavEdge.stay),
        up: exitUp ?? cur.up,
        down: exitDown ?? cur.down,
      );
    }
  }

  /// Wire a grid (row-major). [columns] must be > 0.
  void wireGrid(
    List<String> ids, {
    required int columns,
    TvNavEdge? exitUp,
    TvNavEdge? exitDown,
    TvNavEdge? exitLeft,
    TvNavEdge? exitRight,
  }) {
    assert(columns > 0);
    for (var i = 0; i < ids.length; i++) {
      final id = ids[i];
      final row = i ~/ columns;
      final col = i % columns;
      final cur = _links[id] ?? const TvNavLinks();
      final left = col > 0
          ? TvNavEdge.id(ids[i - 1])
          : (exitLeft ?? cur.left ?? TvNavEdge.stay);
      final right = col + 1 < columns && i + 1 < ids.length
          ? TvNavEdge.id(ids[i + 1])
          : (exitRight ?? cur.right ?? TvNavEdge.stay);
      final up = row > 0
          ? TvNavEdge.id(ids[i - columns])
          : (exitUp ?? cur.up ?? TvNavEdge.stay);
      final downIdx = i + columns;
      final down = downIdx < ids.length
          ? TvNavEdge.id(ids[downIdx])
          : (exitDown ?? cur.down ?? TvNavEdge.stay);
      _links[id] = cur.copyWith(left: left, right: right, up: up, down: down);
    }
  }

  /// Wire a vertical chain.
  void wireColumn(
    List<String> ids, {
    TvNavEdge? exitUp,
    TvNavEdge? exitDown,
    TvNavEdge? exitLeft,
    TvNavEdge? exitRight,
  }) {
    for (var i = 0; i < ids.length; i++) {
      final id = ids[i];
      final cur = _links[id] ?? const TvNavLinks();
      _links[id] = cur.copyWith(
        up: i > 0 ? TvNavEdge.id(ids[i - 1]) : (exitUp ?? cur.up ?? TvNavEdge.stay),
        down: i + 1 < ids.length
            ? TvNavEdge.id(ids[i + 1])
            : (exitDown ?? cur.down ?? TvNavEdge.stay),
        left: exitLeft ?? cur.left ?? TvNavEdge.stay,
        right: exitRight ?? cur.right ?? TvNavEdge.stay,
      );
    }
  }
}

/// Provides [TvNavController] to a subtree.
class TvNavScope extends InheritedNotifier<TvNavController> {
  const TvNavScope({
    super.key,
    required TvNavController controller,
    required super.child,
  }) : super(notifier: controller);

  static TvNavController? maybeOf(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<TvNavScope>()?.notifier;
  }

  static TvNavController of(BuildContext context) {
    final c = maybeOf(context);
    assert(c != null, 'TvNavScope not found');
    return c!;
  }
}

class _TvNavMoveIntent extends Intent {
  const _TvNavMoveIntent(this.dir);
  final TvNavDir dir;
}

/// Installs D-pad Shortcuts → [TvNavController.move]. Wrap each TV screen once.
class TvNavSurface extends StatelessWidget {
  const TvNavSurface({
    super.key,
    required this.child,
    this.controller,
  });

  final Widget child;
  final TvNavController? controller;

  @override
  Widget build(BuildContext context) {
    if (!isAndroidTv) return child;
    final nav = controller ?? TvNavScope.maybeOf(context);
    if (nav == null) return TvNoJumpScroll(child: child);

    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.arrowUp): _TvNavMoveIntent(TvNavDir.up),
        SingleActivator(LogicalKeyboardKey.arrowDown): _TvNavMoveIntent(TvNavDir.down),
        SingleActivator(LogicalKeyboardKey.arrowLeft): _TvNavMoveIntent(TvNavDir.left),
        SingleActivator(LogicalKeyboardKey.arrowRight): _TvNavMoveIntent(TvNavDir.right),
      },
      child: Actions(
        actions: {
          _TvNavMoveIntent: CallbackAction<_TvNavMoveIntent>(
            onInvoke: (intent) {
              nav.move(intent.dir);
              return null;
            },
          ),
        },
        child: TvNoJumpScroll(child: child),
      ),
    );
  }
}

/// Registers a focusable child into the nearest [TvNavScope].
class TvNavItem extends StatefulWidget {
  const TvNavItem({
    super.key,
    required this.id,
    required this.child,
    this.focusNode,
    this.links,
    this.onFocus,
    this.autofocus = false,
    this.debugLabel,
  });

  final String id;
  final Widget child;
  final FocusNode? focusNode;
  final TvNavLinks? links;
  final VoidCallback? onFocus;
  final bool autofocus;
  final String? debugLabel;

  @override
  State<TvNavItem> createState() => _TvNavItemState();
}

class _TvNavItemState extends State<TvNavItem> {
  FocusNode? _owned;
  FocusNode get _node => widget.focusNode ?? _owned!;

  @override
  void initState() {
    super.initState();
    if (widget.focusNode == null) {
      _owned = FocusNode(debugLabel: widget.debugLabel ?? widget.id);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(covariant TvNavItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.id != widget.id) {
      TvNavScope.maybeOf(context)?.unregister(oldWidget.id);
    }
    _sync();
  }

  void _sync() {
    final nav = TvNavScope.maybeOf(context);
    if (nav == null) return;
    nav.register(
      widget.id,
      _node,
      links: widget.links,
      onFocus: widget.onFocus,
    );
  }

  @override
  void dispose() {
    // Don't use context in dispose after unmount — unregister via node map.
    _owned?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _node,
      autofocus: widget.autofocus,
      onFocusChange: (has) {
        if (has) widget.onFocus?.call();
      },
      child: widget.child,
    );
  }
}

/// Creates a [TvNavController] for a State and disposes it.
mixin TvNavHostMixin<T extends StatefulWidget> on State<T> {
  late final TvNavController tvNav;

  List<TvNavStrategy> get tvNavStrategies => const [];

  @override
  void initState() {
    super.initState();
    tvNav = TvNavController(strategies: tvNavStrategies);
  }

  @override
  void dispose() {
    tvNav.dispose();
    super.dispose();
  }

  Widget wrapTvNav(Widget child) {
    if (!isAndroidTv) return child;
    return TvNavScope(
      controller: tvNav,
      child: TvNavSurface(controller: tvNav, child: child),
    );
  }
}

/// Drop-in host for screens that are not already Stateful with [TvNavHostMixin].
class TvNavHost extends StatefulWidget {
  const TvNavHost({
    super.key,
    required this.child,
    this.strategies = const [],
  });

  final Widget child;
  final List<TvNavStrategy> strategies;

  @override
  State<TvNavHost> createState() => _TvNavHostState();
}

class _TvNavHostState extends State<TvNavHost> {
  late final TvNavController _nav =
      TvNavController(strategies: widget.strategies);

  @override
  void dispose() {
    _nav.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!isAndroidTv) return widget.child;
    return TvNavScope(
      controller: _nav,
      child: TvNavSurface(controller: _nav, child: widget.child),
    );
  }
}

// ── Built-in strategies (home / grid / detail / bar) ─────────────────────────

Offset? tvNavOrigin(FocusNode node) {
  final ctx = node.context;
  if (ctx == null || !ctx.mounted) return null;
  final box = ctx.findRenderObject();
  if (box is! RenderBox || !box.hasSize || !box.attached) return null;
  return box.localToGlobal(Offset.zero);
}

List<FocusNode> tvNavLabeled(FocusNode current, bool Function(FocusNode) test) {
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

List<FocusNode> tvNavRowStream(FocusNode from, String label, {double band = 140}) {
  final origin = tvNavOrigin(from);
  if (origin == null) return const [];
  final nodes = tvNavLabeled(from, (n) => n.debugLabel == label).where((n) {
    final pos = tvNavOrigin(n);
    return pos != null && (pos.dy - origin.dy).abs() < band;
  }).toList();
  nodes.sort((a, b) {
    final ax = tvNavOrigin(a)?.dx ?? 0;
    final bx = tvNavOrigin(b)?.dx ?? 0;
    return ax.compareTo(bx);
  });
  return nodes;
}

FocusNode? tvNavStreamNeighbor(FocusNode current, String label, {required bool right}) {
  final row = tvNavRowStream(current, label);
  final i = row.indexWhere((n) => identical(n, current));
  if (i < 0) return null;
  if (right && i + 1 < row.length) return row[i + 1];
  if (!right && i > 0) return row[i - 1];
  return null;
}

void tvNavFocus(
  FocusNode node, {
  double alignment = 0.15,
  bool belowHeader = false,
  bool centerRow = false,
}) {
  node.requestFocus();
  if (centerRow) return;
  final ctx = node.context;
  if (ctx != null) {
    tvEnsureVisible(ctx, alignment: alignment, belowHeader: belowHeader);
  }
}

void tvNavFocusRow(FocusNode node) {
  node.requestFocus();
  final ctx = node.context;
  if (ctx != null) tvEnsureVisibleAxis(ctx, axis: Axis.horizontal, alignment: 0.42);
}

/// Header KindSwitch / Favourites / Search bar.
class TvNavBarStrategy extends TvNavStrategy {
  TvNavBarStrategy({required this.nodes, this.onMoveDown});

  final List<FocusNode> nodes;
  final VoidCallback? onMoveDown;

  bool _inBar(FocusNode current) {
    return nodes.any((node) {
      if (identical(current, node)) return true;
      if (current.ancestors.contains(node)) return true;
      return current.debugLabel != null && current.debugLabel == node.debugLabel;
    });
  }

  @override
  bool handle(TvNavController nav, FocusNode current, TvNavDir dir) {
    if (!_inBar(current)) return false;
    if (dir == TvNavDir.down) {
      onMoveDown?.call();
      return true;
    }
    if (dir == TvNavDir.up) return true;
    TvHeaderFocus.step(nodes, dir == TvNavDir.right ? 1 : -1);
    return true;
  }
}

/// Home zigzag: banner → see-all ↔ posters ↔ next rail.
class TvNavHomeStrategy extends TvNavStrategy {
  @override
  bool handle(TvNavController nav, FocusNode current, TvNavDir dir) {
    final label = current.debugLabel;
    final right = dir == TvNavDir.right;
    final horizontal = dir == TvNavDir.left || dir == TvNavDir.right;

    if (label == 'banner-details' && horizontal) return true;
    if (label == 'banner-details' && dir == TvNavDir.up) {
      TvHomeScroll.enterHeader?.call();
      return true;
    }
    if (label == 'banner-details' && dir == TvNavDir.down) {
      TvHomeScroll.toTop?.call();
      final rails = TvHomeRails.all;
      if (rails.isNotEmpty) _focusSeeAll(rails.first);
      return true;
    }

    if (label == 'poster' && horizontal) {
      final next = tvNavStreamNeighbor(current, 'poster', right: right);
      if (next != null) tvNavFocusRow(next);
      return true;
    }
    if (label == 'poster' && dir == TvNavDir.down) {
      final rail = TvHomeRails.byPoster(current);
      final next = rail == null ? null : TvHomeRails.after(rail);
      if (next != null) _focusSeeAll(next);
      return true;
    }
    if (label == 'poster' && dir == TvNavDir.up) {
      final rail = TvHomeRails.byPoster(current);
      if (rail != null) {
        _focusSeeAll(rail);
      } else {
        _focusBanner();
      }
      return true;
    }

    if (label == 'see-all' && horizontal) {
      final rail = TvHomeRails.bySeeAll(current);
      if (rail != null) _focusPosters(rail);
      return true;
    }
    if (label == 'see-all' && dir == TvNavDir.down) {
      final rail = TvHomeRails.bySeeAll(current);
      if (rail != null) _focusPosters(rail);
      return true;
    }
    if (label == 'see-all' && dir == TvNavDir.up) {
      final rail = TvHomeRails.bySeeAll(current);
      final prev = rail == null ? null : TvHomeRails.before(rail);
      if (prev != null) {
        _focusPosters(prev);
      } else {
        _focusBanner();
      }
      return true;
    }

    return false;
  }

  void _focusPosters(TvHomeRail rail) {
    rail.prepareFirst();
    rail.reveal();
    if (rail.firstPoster.canRequestFocus) rail.firstPoster.requestFocus();
  }

  void _focusSeeAll(TvHomeRail rail) {
    rail.reveal();
    if (rail.seeAll.canRequestFocus) rail.seeAll.requestFocus();
  }

  void _focusBanner() {
    TvHomeScroll.toTop?.call();
    final node = TvHeaderFocus.bannerDetails;
    if (node.canRequestFocus) node.requestFocus();
  }
}

/// Poster grids (search / catalog / favourites).
class TvNavGridStrategy extends TvNavStrategy {
  TvNavGridStrategy({this.onMoveUp});

  final VoidCallback? onMoveUp;

  @override
  bool handle(TvNavController nav, FocusNode current, TvNavDir dir) {
    if (current.debugLabel != 'poster') return false;

    final posters = tvNavLabeled(current, (n) => n.debugLabel == 'poster');
    if (posters.isEmpty) return true;

    posters.sort((a, b) {
      final ay = tvNavOrigin(a)?.dy ?? 0;
      final by = tvNavOrigin(b)?.dy ?? 0;
      final dy = ay.compareTo(by);
      if (dy != 0) return dy;
      return (tvNavOrigin(a)?.dx ?? 0).compareTo(tvNavOrigin(b)?.dx ?? 0);
    });

    final origin = tvNavOrigin(current);
    if (origin == null) return true;

    FocusNode? pick;
    if (dir == TvNavDir.left || dir == TvNavDir.right) {
      final right = dir == TvNavDir.right;
      final row = posters.where((n) {
        final y = tvNavOrigin(n)?.dy;
        return y != null && (y - origin.dy).abs() < 72;
      }).toList()
        ..sort((a, b) => (tvNavOrigin(a)?.dx ?? 0).compareTo(tvNavOrigin(b)?.dx ?? 0));
      final ri = row.indexWhere((n) => identical(n, current));
      if (ri < 0) return true;
      if (right && ri + 1 < row.length) pick = row[ri + 1];
      if (!right && ri > 0) pick = row[ri - 1];
    } else if (dir == TvNavDir.down) {
      var best = double.infinity;
      for (final n in posters) {
        final pos = tvNavOrigin(n);
        if (pos == null || pos.dy <= origin.dy + 40) continue;
        final score = (pos.dy - origin.dy) * 1000 + (pos.dx - origin.dx).abs();
        if (score < best) {
          best = score;
          pick = n;
        }
      }
    } else if (dir == TvNavDir.up) {
      var best = double.infinity;
      for (final n in posters) {
        final pos = tvNavOrigin(n);
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
      tvNavFocus(pick, alignment: 0.35, belowHeader: true);
    }
    return true;
  }
}

const _kDetailActions = {'detail-play', 'detail-watched', 'detail-favorite'};

/// Title detail page: actions → cast → seasons → episodes.
class TvNavDetailStrategy extends TvNavStrategy {
  @override
  bool handle(TvNavController nav, FocusNode current, TvNavDir dir) {
    final label = current.debugLabel ?? '';
    final right = dir == TvNavDir.right;
    final horizontal = dir == TvNavDir.left || dir == TvNavDir.right;

    if (_kDetailActions.contains(label) && horizontal) {
      final next = _actionNeighbor(current, right: right);
      if (next != null) tvNavFocus(next, alignment: 0.2);
      return true;
    }
    if (_kDetailActions.contains(label) && dir == TvNavDir.up) {
      final back = tvNavLabeled(current, (n) => n.debugLabel == 'detail-back');
      if (back.isNotEmpty) {
        tvNavFocus(back.first, alignment: 0);
        return true;
      }
    }
    if (label == 'detail-back' && dir == TvNavDir.down) {
      final play = tvNavLabeled(current, (n) => n.debugLabel == 'detail-play');
      final watched = tvNavLabeled(current, (n) => n.debugLabel == 'detail-watched');
      final target = play.isNotEmpty ? play.first : (watched.isNotEmpty ? watched.first : null);
      if (target != null) {
        tvNavFocus(target, alignment: 0);
        return true;
      }
    }
    if (label == 'detail-back' && horizontal) return true;

    if (_kDetailActions.contains(label) && dir == TvNavDir.down) {
      return _focusFirstOf(current, const ['cast', 'season', 'episode']);
    }

    if (label == 'cast' && horizontal) {
      final next = tvNavStreamNeighbor(current, 'cast', right: right);
      if (next != null) tvNavFocusRow(next);
      return true;
    }
    if (label == 'cast' && dir == TvNavDir.up) {
      return _focusAction(current);
    }
    if (label == 'cast' && dir == TvNavDir.down) {
      return _focusFirstOf(current, const ['season', 'episode']);
    }

    if (label == 'season' && horizontal) {
      final next = tvNavStreamNeighbor(current, 'season', right: right);
      if (next != null) tvNavFocusRow(next);
      return true;
    }
    if (label == 'season' && dir == TvNavDir.up) {
      if (_focusFirstOf(current, const ['cast'])) return true;
      return _focusAction(current);
    }
    if (label == 'season' && dir == TvNavDir.down) {
      return _focusFirstOf(current, const ['episode']);
    }

    if (label == 'episode' && horizontal) return true;
    if (label == 'episode' && dir == TvNavDir.up) {
      final origin = tvNavOrigin(current);
      final episodes = tvNavLabeled(current, (n) => n.debugLabel == 'episode');
      FocusNode? prev;
      var bestY = double.negativeInfinity;
      for (final node in episodes) {
        final y = tvNavOrigin(node)?.dy;
        if (y == null || origin == null || y >= origin.dy - 8) continue;
        if (y >= bestY) {
          bestY = y;
          prev = node;
        }
      }
      if (prev != null) {
        tvNavFocus(prev, alignment: 0.2);
        return true;
      }
      if (_focusFirstOf(current, const ['season', 'cast'])) return true;
    }

    return false;
  }

  bool _focusAction(FocusNode current) {
    final play = tvNavLabeled(current, (n) => n.debugLabel == 'detail-play');
    final watched = tvNavLabeled(current, (n) => n.debugLabel == 'detail-watched');
    final target = play.isNotEmpty ? play.first : (watched.isNotEmpty ? watched.first : null);
    if (target == null) return true;
    tvNavFocus(target, alignment: 0);
    return true;
  }

  bool _focusFirstOf(FocusNode current, List<String> labels) {
    for (final label in labels) {
      final nodes = tvNavLabeled(current, (n) => n.debugLabel == label);
      if (nodes.isEmpty) continue;
      if (label == 'cast' || label == 'season') {
        nodes.sort((a, b) => (tvNavOrigin(a)?.dx ?? 0).compareTo(tvNavOrigin(b)?.dx ?? 0));
      }
      tvNavFocus(nodes.first, alignment: 0.2);
      return true;
    }
    return true;
  }

  FocusNode? _actionNeighbor(FocusNode current, {required bool right}) {
    final actions =
        tvNavLabeled(current, (n) => _kDetailActions.contains(n.debugLabel ?? ''));
    actions.sort((a, b) => (tvNavOrigin(a)?.dx ?? 0).compareTo(tvNavOrigin(b)?.dx ?? 0));
    final i = actions.indexWhere((n) => identical(n, current));
    if (i < 0) return null;
    if (right && i + 1 < actions.length) return actions[i + 1];
    if (!right && i > 0) return actions[i - 1];
    return null;
  }
}
