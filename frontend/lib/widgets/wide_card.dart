import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../design/tokens.g.dart';
import '../models.dart';
import '../tv.dart';
import '../window_layout.dart';
import 'cached_art.dart';
import 'poster_card.dart';
import 'tv_chrome.dart';

/// Continue watching: a 16:9 still with the name, time left and an amber bar.
class WideCard extends StatefulWidget {
  const WideCard({super.key, required this.item, this.focusNode});

  final TitleItem item;
  final FocusNode? focusNode;

  /// "31 min left", "1h 12m left", or "Resume" when the length isn't known.
  static String timeLeft(TitleItem item) {
    final state = item.userState;
    final duration = state?.durationMs ?? 0;
    final position = state?.positionMs ?? 0;
    if (state == null || duration <= 0 || position <= 0 || position >= duration) {
      return 'Resume';
    }
    final minutes = ((duration - position) / 60000).ceil();
    if (minutes < 60) return '$minutes min left';
    final h = minutes ~/ 60;
    final m = minutes % 60;
    return m == 0 ? '${h}h left' : '${h}h ${m}m left';
  }

  @override
  State<WideCard> createState() => _WideCardState();
}

class _WideCardState extends State<WideCard> {
  late final FocusNode _focus = widget.focusNode ?? FocusNode(debugLabel: 'poster');
  bool _hover = false;

  @override
  void dispose() {
    if (widget.focusNode == null) _focus.dispose();
    super.dispose();
  }

  void _open() => context.push('/title/${widget.item.id}');

  void _onFocus(bool focused) {
    if (mounted) setState(() {});
    if (!focused || !isAndroidTv) return;
    TvFocusReveal.maybeOf(context)?.call();
    if (TvHomeRails.suppressHorizontalEnsureVisible) return;
    if (Scrollable.maybeOf(context, axis: Axis.horizontal) != null) {
      tvEnsureVisibleAxis(context, axis: Axis.horizontal, alignment: 0.42);
    }
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final tv = isAndroidTv;
    final focused = _focus.hasFocus;
    final progress = titleProgress(item);
    return TvFocus(
      child: FocusableActionDetector(
        focusNode: _focus,
        mouseCursor: SystemMouseCursors.click,
        onFocusChange: _onFocus,
        onShowHoverHighlight: (v) => setState(() => _hover = v),
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.gameButtonA): ActivateIntent(),
        },
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) {
            _open();
            return null;
          }),
        },
        child: GestureDetector(
          onTap: _open,
          child: AnimatedScale(
            scale: focused ? (tv ? PbSize.focusScaleTv : 1.03) : (_hover ? 1.03 : 1),
            duration: PbMotion.base,
            curve: Curves.easeOut,
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(PbRadius.card + 3),
                border: Border.all(
                  color: focused ? PbColors.focus : Colors.transparent,
                  width: PbSize.focusRing,
                ),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(PbRadius.card),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    const ColoredBox(color: PbColors.surface),
                    CachedArt(
                      url: bestBannerUrl(
                        backdropUrl: item.backdropUrl,
                        thumbUrl: item.thumbUrl,
                        posterUrl: item.posterUrl,
                      ),
                      memCacheWidth: 600,
                    ),
                    const DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.bottomCenter,
                          end: Alignment.topCenter,
                          colors: [Color(0xD9000000), Color(0x00000000)],
                          stops: [0.0, 0.6],
                        ),
                      ),
                    ),
                    Positioned(
                      left: 12,
                      right: 12,
                      bottom: 14,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            item.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: (tv ? PbTypeTv.title : PbType.title).copyWith(color: PbColors.text),
                          ),
                          Text(
                            WideCard.timeLeft(item),
                            style: (tv ? PbTypeTv.meta : PbType.meta).copyWith(color: PbColors.textMuted),
                          ),
                        ],
                      ),
                    ),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: LinearProgressIndicator(
                        value: progress > 0 ? progress : 0.02,
                        minHeight: 4,
                        backgroundColor: Colors.white.withValues(alpha: 0.18),
                        color: PbColors.primary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Top 10: a big outlined rank number tucked behind the poster.
class Top10Tile extends StatelessWidget {
  const Top10Tile({
    super.key,
    required this.rank,
    required this.child,
    required this.posterWidth,
  });

  final int rank;
  final Widget child;
  final double posterWidth;

  /// Width the number adds before the poster.
  static double numberWidth(double posterWidth) => posterWidth * 0.4;

  @override
  Widget build(BuildContext context) {
    final height = posterWidth * 1.5;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        SizedBox(
          width: numberWidth(posterWidth),
          height: height,
          child: OverflowBox(
            alignment: Alignment.bottomRight,
            maxWidth: double.infinity,
            child: Transform.translate(
              offset: Offset(posterWidth * 0.16, height * 0.06),
              child: Text(
                '$rank',
                style: PbType.hero.copyWith(
                  fontSize: height * 0.72,
                  height: 1,
                  letterSpacing: -height * 0.04,
                  foreground: Paint()
                    ..style = PaintingStyle.stroke
                    ..strokeWidth = 2.5
                    ..color = const Color(0xFF4A4E5A),
                ),
              ),
            ),
          ),
        ),
        SizedBox(width: posterWidth, height: height, child: child),
      ],
    );
  }
}
