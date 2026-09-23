import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../tv.dart';
import '../tv_nav.dart';

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

/// Marks a focusable control for TV. Prefer wrapping the screen in
/// [TvNavScope] + [TvNavSurface]; without a scope, arrows fall through to
/// FocusTraversalGroup policies (legacy).
class TvFocus extends StatelessWidget {
  const TvFocus({super.key, required this.child, this.allowHorizontal = true});

  final Widget child;
  final bool allowHorizontal;

  @override
  Widget build(BuildContext context) {
    if (!isAndroidTv) return child;
    final hasNav = TvNavScope.maybeOf(context) != null;
    if (hasNav) return TvNoJumpScroll(child: child);
    return Shortcuts(
      shortcuts: {
        const SingleActivator(LogicalKeyboardKey.arrowUp):
            const DirectionalFocusIntent(TraversalDirection.up),
        const SingleActivator(LogicalKeyboardKey.arrowDown):
            const DirectionalFocusIntent(TraversalDirection.down),
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
    final button = IconButton(
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

    final nav = TvNavScope.maybeOf(context);
    final id = focusNode?.debugLabel;
    if (nav != null && id != null && focusNode != null) {
      nav.register(
        id,
        focusNode!,
        links: TvNavLinks(
          down: onMoveDown != null ? TvNavEdge.action(onMoveDown!) : TvNavEdge.stay,
          left: onMoveLeft != null ? TvNavEdge.action(onMoveLeft!) : null,
          right: onMoveRight != null ? TvNavEdge.action(onMoveRight!) : null,
          up: TvNavEdge.stay,
        ),
      );
    }
    return TvFocus(child: button);
  }
}
