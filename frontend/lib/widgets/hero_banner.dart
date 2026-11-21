import 'package:flutter/material.dart';

import '../design/tokens.g.dart';
import '../theme.dart';
import '../tv.dart';

/// Home and title pages share this hero: full-width art, left scrim, copy slot.
class HeroBannerFrame extends StatelessWidget {
  const HeroBannerFrame({
    super.key,
    required this.art,
    required this.child,
    this.bannerKey,
    this.topInset,
  });

  final Widget art;
  final Widget child;
  final Key? bannerKey;
  final double? topInset;

  static double heightFor(BuildContext context) {
    final height = MediaQuery.sizeOf(context).height;
    if (isAndroidTv) {
      return (height * 0.58).clamp(460.0, 620.0);
    }
    return (height * 0.62).clamp(440.0, 600.0);
  }

  /// Clearance under Movies/Series chrome and the detail back button.
  static double headerGap(BuildContext context) {
    final pad = MediaQuery.paddingOf(context).top;
    if (isAndroidTv) return pad + 64;
    return pad + 56;
  }

  @override
  Widget build(BuildContext context) {
    final inset = topInset ?? 0;
    return KeyedSubtree(
      key: bannerKey,
      child: SizedBox(
        height: heightFor(context),
        child: Stack(
          fit: StackFit.expand,
          children: [
            const ColoredBox(color: AppTheme.canvas),
            // Full-bleed art — always cover the banner bounds.
            Positioned.fill(child: art),
            const IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    colors: [
                      Color(0xF50E0E12),
                      Color(0xE60E0E12),
                      Color(0x990E0E12),
                      Color(0x000E0E12),
                    ],
                    stops: [0.0, 0.22, 0.48, 0.72],
                  ),
                ),
              ),
            ),
            const IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      Color(0x000E0E12),
                      Color(0x660E0E12),
                      AppTheme.canvas,
                    ],
                    stops: [0.4, 0.62, 0.82, 1.0],
                  ),
                ),
              ),
            ),
            Positioned(
              left: isAndroidTv ? PbSpace.gutterTv : PbSpace.gutterDesktop,
              top: inset > 0 ? inset : null,
              bottom: 36,
              width: 560,
              child: inset > 0
                  ? Align(alignment: Alignment.bottomLeft, child: child)
                  : child,
            ),
          ],
        ),
      ),
    );
  }
}

class HeroBannerCopy extends StatelessWidget {
  const HeroBannerCopy({
    super.key,
    required this.eyebrow,
    required this.title,
    required this.meta,
    required this.synopsis,
    this.belowTitle,
    this.action,
  });

  final String eyebrow;
  final String title;
  final Widget meta;
  final String synopsis;
  final Widget? belowTitle;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          eyebrow.toUpperCase(),
          style: (isAndroidTv ? PbTypeTv.label : PbType.label).copyWith(
            color: PbColors.primary,
            letterSpacing: 1.1,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: (isAndroidTv ? PbTypeTv.hero : PbType.hero).copyWith(
            color: PbColors.text,
            height: 1.05,
            letterSpacing: -1.0,
          ),
        ),
        if (belowTitle != null) ...[
          const SizedBox(height: 12),
          belowTitle!,
        ],
        const SizedBox(height: 12),
        SizedBox(
          height: 28,
          child: Align(
            alignment: Alignment.centerLeft,
            child: ClipRect(child: meta),
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 42,
          child: Text(
            synopsis,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: (isAndroidTv ? PbTypeTv.body : PbType.body).copyWith(
              color: const Color(0xFFD6DAE3),
              fontSize: isAndroidTv ? 16 : 15,
              height: 1.45,
            ),
          ),
        ),
        if (action != null) ...[
          const SizedBox(height: 12),
          action!,
        ],
        const SizedBox(height: 16),
      ],
    );
  }
}
