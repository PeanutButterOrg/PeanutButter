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
  /// Focus from the keyboard or remote (not a mouse click): show the ring.
  bool _ring = false;

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
    final focused = _focus.hasFocus && (tv || _ring);
    final progress = titleProgress(item);
    return TvFocus(
      child: FocusableActionDetector(
        focusNode: _focus,
        mouseCursor: SystemMouseCursors.click,
        onFocusChange: _onFocus,
        onShowHoverHighlight: (v) => setState(() => _hover = v),
        onShowFocusHighlight: (v) => setState(() => _ring = v),
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

/// Top 10, as in the design: a big outlined rank number with the poster
/// tucked over its right edge (most of the digit still shows), and the
/// title's name under the poster.
class Top10Tile extends StatelessWidget {
  const Top10Tile({
    super.key,
    required this.rank,
    required this.child,
    required this.posterWidth,
    this.name = '',
  });

  final int rank;
  final Widget child;
  final double posterWidth;
  final String name;

  /// Room the number takes before the poster (after the overlap).
  static double numberWidth(double posterWidth) => posterWidth * 0.8 - _overlap(posterWidth);

  static double _overlap(double posterWidth) => posterWidth * 0.07;

  /// Height under the poster for the name.
  static const double nameHeight = 26;

  /// Space Grotesk's digits stand 0.70 of the font size tall (its cap height).
  static const double _digitHeight = 0.70;

  @override
  Widget build(BuildContext context) {
    final height = posterWidth * 1.5;
    final box = posterWidth * 0.8;
    const stroke = 3.0;
    // As on Netflix: digits in their natural shape (never squeezed), most of
    // the poster's height, standing on its bottom edge and tucked under the
    // poster. "10" comes out smaller (same shape) so it fits the same room.
    const tuckShare = 0.2;
    TextStyle styleAt(double size) => PbType.hero.copyWith(
          fontSize: size,
          height: 1,
          letterSpacing: rank >= 10 ? -size * 0.04 : 0,
        );
    final byHeight = (height - stroke) * 0.86 / _digitHeight;
    final probe = TextPainter(
      // Every single digit sized from the widest ("8"), so 1–9 stand equally tall.
      text: TextSpan(text: rank >= 10 ? '$rank' : '8', style: styleAt(byHeight)),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    final visible = probe.width * (1 - tuckShare);
    final fontSize = visible <= box ? byHeight : byHeight * box / visible;
    final style = PbType.hero.copyWith(
      fontSize: fontSize,
      height: 1,
      letterSpacing: rank >= 10 ? -fontSize * 0.04 : 0,
      foreground: Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..color = const Color(0xFF6E7483),
    );
    final painter = TextPainter(
      text: TextSpan(text: '$rank', style: style),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    final baseline = painter.computeDistanceToActualBaseline(TextBaseline.alphabetic);
    return SizedBox(
      width: box + posterWidth - _overlap(posterWidth),
      height: height + nameHeight,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            left: box + painter.width * tuckShare - painter.width,
            top: height - stroke / 2 - baseline,
            width: painter.width,
            // Decorative and sized to the poster: drawn exactly as measured
            // above, whatever the system text size.
            child: Text(
              '$rank',
              maxLines: 1,
              softWrap: false,
              textScaler: TextScaler.noScaling,
              style: style,
            ),
          ),
          Positioned(right: 0, top: 0, height: height, width: posterWidth, child: child),
          Positioned(
            right: 0,
            bottom: 0,
            width: posterWidth,
            height: nameHeight - 6,
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: PbType.meta.copyWith(color: PbColors.text, fontWeight: FontWeight.w500),
            ),
          ),
        ],
      ),
    );
  }
}
