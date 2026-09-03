import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models.dart';
import '../theme.dart';
import '../tv.dart';
import 'cached_art.dart';
import 'rt_badge.dart';
import 'tv_chrome.dart';

class PosterCard extends ConsumerStatefulWidget {
  const PosterCard({super.key, required this.item, this.focusNode});

  final TitleItem item;
  final FocusNode? focusNode;

  @override
  ConsumerState<PosterCard> createState() => _PosterCardState();
}

class _PosterCardState extends ConsumerState<PosterCard> {
  late final FocusNode _focus;
  late final bool _ownsFocus;

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
    final horizontal = Scrollable.maybeOf(context, axis: Axis.horizontal);
    if (horizontal != null) {
      tvEnsureVisibleAxis(context, axis: Axis.horizontal, alignment: 0.42);
    }
  }

  void _openDetails() {
    context.push('/title/${widget.item.id}');
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final tv = isAndroidTv;
    final highlighted = _focus.hasFocus;
    return TvFocus(
      child: FocusableActionDetector(
        focusNode: _focus,
        mouseCursor: SystemMouseCursors.click,
        onShowFocusHighlight: (_) {},
        onFocusChange: _onFocus,
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
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
              scale: highlighted ? (tv ? TvPosterDim.scale : 1.08) : 1,
              alignment: Alignment.center,
              duration: Duration(milliseconds: tv ? 220 : 180),
              curve: Curves.easeOut,
              child: tv
                  ? Material(
                      elevation: highlighted ? 36 : 2,
                      shadowColor: Colors.black,
                      color: Colors.transparent,
                      surfaceTintColor: Colors.transparent,
                      borderRadius: BorderRadius.circular(12),
                      clipBehavior: Clip.antiAlias,
                      child: _posterFace(item, compact: true),
                    )
                  : Material(
                      elevation: highlighted ? 18 : 2,
                      shadowColor: Colors.black,
                      color: Colors.transparent,
                      surfaceTintColor: Colors.transparent,
                      borderRadius: BorderRadius.circular(12),
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
    return Stack(
      fit: StackFit.expand,
      children: [
        CachedArt(url: item.posterUrl, memCacheWidth: compact ? 280 : 420),
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0x66000000), Colors.transparent, Color(0xCC000000)],
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
                  RatingBadge(item: item),
                  const Spacer(),
                  if (item.bestQuality != null && item.bestQuality!.isNotEmpty)
                    _badge(item.bestQuality!, Colors.black87),
                ],
              ),
              const Spacer(),
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
          ),
        ),
        if (_progressOf(item) > 0.02)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: LinearProgressIndicator(
              value: _progressOf(item),
              minHeight: 3,
              backgroundColor: Colors.white24,
              color: AppTheme.seed,
            ),
          ),
      ],
    );
  }

  double _progressOf(TitleItem item) {
    final state = item.userState;
    if (state == null || state.watched || state.positionMs < 2000) return 0;
    final duration = state.durationMs ?? 0;
    if (duration <= 0) return 0.08;
    return (state.positionMs / duration).clamp(0.0, 1.0);
  }

  Widget _badge(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(5)),
      child: Text(
        text,
        style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
      ),
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
