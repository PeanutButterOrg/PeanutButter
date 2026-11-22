import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';

import '../design/tokens.g.dart';
import '../models.dart';
import '../service_logos.dart';
import '../tv.dart';
import 'cached_art.dart';
import 'rt_badge.dart';
import 'tv_chrome.dart';

class PosterCard extends ConsumerStatefulWidget {
  const PosterCard({super.key, required this.item, this.focusNode, this.onOpen});

  final TitleItem item;
  final FocusNode? focusNode;
  /// Instead of opening the title page by [item]'s id (a filmography credit
  /// that isn't in the catalog yet).
  final VoidCallback? onOpen;

  @override
  ConsumerState<PosterCard> createState() => _PosterCardState();
}

class _PosterCardState extends ConsumerState<PosterCard> {
  late final FocusNode _focus;
  late final bool _ownsFocus;
  bool _hover = false;
  /// Focus from the keyboard or remote (not a mouse click): show the ring.
  bool _ring = false;

  @override
  void initState() {
    super.initState();
    _ownsFocus = widget.focusNode == null;
    _focus = widget.focusNode ?? FocusNode(debugLabel: 'poster');
  }

  @override
  void dispose() {
    if (_ownsFocus) _focus.dispose();
    super.dispose();
  }

  void _onFocus(bool focused) {
    if (mounted) setState(() {});
    if (!focused || !isAndroidTv) return;
    TvFocusReveal.maybeOf(context)?.call();
    if (TvHomeRails.suppressHorizontalEnsureVisible) return;
    final horizontal = Scrollable.maybeOf(context, axis: Axis.horizontal);
    if (horizontal != null) {
      tvEnsureVisibleAxis(context, axis: Axis.horizontal, alignment: 0.42);
    }
  }

  void _openDetails() {
    if (widget.onOpen != null) return widget.onOpen!();
    context.push('/title/${widget.item.id}');
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final tv = isAndroidTv;
    final highlighted = _focus.hasFocus && (tv || _ring);
    final lifted = highlighted || _hover;
    return TvFocus(
      child: FocusableActionDetector(
        focusNode: _focus,
        mouseCursor: SystemMouseCursors.click,
        onShowFocusHighlight: (v) => setState(() => _ring = v),
        onShowHoverHighlight: (v) => setState(() => _hover = v),
        onFocusChange: _onFocus,
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.numpadEnter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.gameButtonA): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.gameButtonStart): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.accept): ActivateIntent(),
        },
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              _openDetails();
              return null;
            },
          ),
        },
        child: GestureDetector(
          onTap: _openDetails,
          onSecondaryTapDown: (d) => _menu(context, d.globalPosition),
          child: RepaintBoundary(
            child: AnimatedScale(
              scale: tv
                  ? (highlighted ? PbSize.focusScaleTv : 1)
                  : (lifted ? 1.04 : 1),
              alignment: Alignment.center,
              duration: Duration(milliseconds: tv ? 160 : 180),
              curve: Curves.easeOut,
              child: tv
                  ? DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(PbRadius.card + 3),
                        border: Border.all(
                          color: highlighted ? PbColors.focus : Colors.transparent,
                          width: PbSize.focusRing,
                        ),
                        boxShadow: highlighted
                            ? [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.55),
                                  blurRadius: 18,
                                  offset: const Offset(0, 8),
                                ),
                              ]
                            : null,
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(PbRadius.card),
                        child: _posterFace(item, compact: true),
                      ),
                    )
                  : Material(
                      elevation: lifted ? 14 : 2,
                      shadowColor: Colors.black,
                      color: PbColors.surface,
                      surfaceTintColor: Colors.transparent,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(PbRadius.card),
                        side: highlighted
                            ? const BorderSide(color: PbColors.focus, width: PbSize.focusRing)
                            : BorderSide.none,
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: _posterFace(item, compact: false),
                    ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _posterFace(TitleItem item, {required bool compact}) {
    final hasArt = item.posterUrl != null && item.posterUrl!.isNotEmpty;
    return Stack(
      fit: StackFit.expand,
      children: [
        CachedArt(url: item.posterUrl, memCacheWidth: compact ? 280 : 420),
        if (!hasArt)
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.transparent, Color(0xCC000000)],
              ),
            ),
          ),
        Padding(
          padding: EdgeInsets.all(compact ? 6 : 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  // Star score only: stream quality belongs in Choose a stream.
                  RatingBadge(item: item),
                  const Spacer(),
                  if (item.userState?.favorite == true ||
                      item.userState?.watched == true) ...[
                    const SizedBox(width: 4),
                    _stateChip(item.userState!, compact: compact),
                  ],
                  // The streaming service's logo in a chip of its own, after liked / watched.
                  if (item.services.isNotEmpty) ...[
                    const SizedBox(width: 4),
                    _serviceChip(item.services.first, compact: compact),
                  ],
                ],
              ),
              const Spacer(),
              if (!hasArt) ...[
              Text(
                item.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                  fontSize: compact ? 11 : 13,
                  height: 1.2,
                ),
              ),
              if (item.year != null)
                Text(
                  '${item.year}',
                  style: TextStyle(color: Colors.white70, fontSize: compact ? 10 : 11),
                ),
              ],
            ],
          ),
        ),
        if (titleProgress(item) > 0.02)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: LinearProgressIndicator(
              value: titleProgress(item),
              minHeight: 3,
              backgroundColor: Colors.white24,
              color: PbColors.primary,
            ),
          ),
      ],
    );
  }

  /// The service's logo in its colour; a short text mark when there's no logo.
  Widget _serviceMark(ServiceTag s, {required double size, required bool compact}) {
    final hex = (s.badge.color & 0xFFFFFF).toRadixString(16).padLeft(6, '0');
    final logo = serviceLogoPaths[s.id];
    final outline = serviceLogoStrokePaths[s.id];
    if (logo != null || outline != null) {
      final path = logo != null
          ? '<path fill="#$hex" d="$logo"/>'
          : '<path fill="none" stroke="#$hex" stroke-width="2" stroke-linecap="round" '
              'stroke-linejoin="round" d="$outline"/>';
      // Cropped to the logo's own bounds: every service at the same height,
      // wide wordmarks wider (up to a cap) instead of tiny in a square.
      final b = serviceLogoBounds[s.id] ?? const [0.0, 0.0, 24.0, 24.0];
      final maxWidth = size * 2.25;
      final height = (maxWidth * b[3] / b[2]).clamp(0.0, size).toDouble();
      final width = height * b[2] / b[3];
      return SvgPicture.string(
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="${b[0]} ${b[1]} ${b[2]} ${b[3]}">$path</svg>',
        width: width,
        height: height,
      );
    }
    return Text(
      s.badge.label,
      style: TextStyle(
        color: Color(s.badge.color),
        fontSize: compact ? 11 : 13,
        fontWeight: FontWeight.w800,
        height: 1.1,
      ),
    );
  }

  /// Liked / watched in one chip styled like the rating chip (same dark
  /// glass, radius and height), so it sits quietly on any poster art.
  Widget _stateChip(UserState state, {required bool compact}) {
    final accent = Theme.of(context).colorScheme.primary;
    final size = compact ? 14.0 : 17.0;
    final icons = <Widget>[
      if (state.favorite)
        Icon(Icons.favorite_rounded, size: size, color: PbColors.primary),
      if (state.watched)
        Icon(Icons.check_circle_rounded, size: size, color: accent),
    ];
    return Semantics(
      label: [if (state.favorite) 'Liked', if (state.watched) 'Watched'].join(', '),
      child: _glassChip(
        compact: compact,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var k = 0; k < icons.length; k++) ...[
              if (k > 0) SizedBox(width: compact ? 3 : 4),
              icons[k],
            ],
          ],
        ),
      ),
    );
  }

  /// Trending only: one streaming service (the list it ranks highest on).
  Widget _serviceChip(ServiceTag service, {required bool compact}) {
    return Semantics(
      label: service.name,
      child: _glassChip(
        compact: compact,
        child: _serviceMark(service, size: compact ? 14.0 : 17.0, compact: compact),
      ),
    );
  }

  /// One height for every chip (liked / watched, each service), contents centred.
  Widget _glassChip({required Widget child, required bool compact}) {
    return Container(
      height: compact ? 22 : 26,
      alignment: Alignment.center,
      padding: EdgeInsets.symmetric(horizontal: compact ? 5 : 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(compact ? 6 : 8),
      ),
      child: child,
    );
  }

  Future<void> _menu(BuildContext context, Offset pos) async {
    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(pos.dx, pos.dy, pos.dx, pos.dy),
      items: const [
        PopupMenuItem(value: 'edit', child: Text('Edit')),
      ],
    );
    if (!context.mounted) return;
    if (selected == 'edit') {
      context.push('/edit/${widget.item.id}');
    }
  }
}

/// Resume progress (0–1) for a title's bar; 0 when there's nothing to resume.
double titleProgress(TitleItem item) {
  final state = item.userState;
  if (state == null || state.watched) return 0;
  // The server's figure covers the whole season for a series, not the episode
  // playing. Keep a sliver so early progress still shows on the card.
  if (state.progressPercent > 0) {
    return state.progressPercent.clamp(0.02, 1.0);
  }
  if (state.positionMs < 2000) return 0;
  final duration = state.durationMs ?? 0;
  if (duration <= 0) return 0.08;
  return (state.positionMs / duration).clamp(0.0, 1.0);
}
