import 'package:flutter/material.dart';

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
    return (height * 0.48).clamp(380.0, 540.0);
  }

  static double headerGap(BuildContext context) {
    if (!isAndroidTv) return 0;
    return MediaQuery.paddingOf(context).top + 64;
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
            art,
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
              left: 32,
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
          eyebrow,
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: Colors.white70,
                letterSpacing: 1.2,
              ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 72,
          child: Text(
            title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.displaySmall?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                  height: 1.05,
                ),
          ),
        ),
        if (belowTitle != null) ...[
          const SizedBox(height: 12),
          belowTitle!,
        ],
        const SizedBox(height: 10),
        SizedBox(
          height: 22,
          child: ClipRect(child: meta),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 42,
          child: Text(
            synopsis,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white70, fontSize: 15, height: 1.4),
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
