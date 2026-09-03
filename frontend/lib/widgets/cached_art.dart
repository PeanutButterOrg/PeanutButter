import 'dart:io' show Platform;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import '../models.dart';

/// Disk cache for posters and backdrops so scrolling does not re-download art.
class ArtCache {
  static final CacheManager posters = CacheManager(
    Config(
      'catalog_art',
      stalePeriod: const Duration(days: 45),
      maxNrOfCacheObjects: 8000,
    ),
  );

  static Future<void> prefetch(Iterable<TitleItem> items, {int concurrency = 8}) async {
    final urls = <String>{};
    for (final item in items) {
      for (final url in [item.thumbUrl, item.backdropUrl, item.posterUrl, item.logoUrl]) {
        if (url == null || url.isEmpty) continue;
        urls.add(url);
      }
    }
    if (urls.isEmpty) return;
    final list = urls.toList();
    for (var i = 0; i < list.length; i += concurrency) {
      final chunk = list.skip(i).take(concurrency);
      await Future.wait(
        chunk.map((url) async {
          try {
            await posters.downloadFile(url).timeout(const Duration(seconds: 12));
          } catch (_) {}
        }),
      );
    }
  }

  static Future<void> clear() async {
    await posters.emptyCache();
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  }
}

class CachedArt extends StatelessWidget {
  const CachedArt({
    super.key,
    required this.url,
    this.fallbackUrl,
    this.fit = BoxFit.cover,
    this.alignment = Alignment.center,
    this.memCacheWidth,
  });

  final String? url;
  final String? fallbackUrl;
  final BoxFit fit;
  final Alignment alignment;
  final int? memCacheWidth;

  @override
  Widget build(BuildContext context) {
    final src = (url != null && url!.isNotEmpty) ? url : fallbackUrl;
    if (src == null || src.isEmpty) {
      return ColoredBox(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: const Center(child: Icon(Icons.movie_outlined, color: Colors.white24)),
      );
    }
    return CachedNetworkImage(
      imageUrl: src,
      cacheManager: ArtCache.posters,
      cacheKey: src,
      fit: fit,
      alignment: alignment,
      width: double.infinity,
      height: double.infinity,
      memCacheWidth: memCacheWidth,
      fadeInDuration: Duration.zero,
      fadeOutDuration: Duration.zero,
      placeholder: (_, __) => ColoredBox(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
      ),
      errorWidget: (_, __, ___) {
        if (fallbackUrl != null && fallbackUrl != src && fallbackUrl!.isNotEmpty) {
          return CachedNetworkImage(
            imageUrl: fallbackUrl!,
            cacheManager: ArtCache.posters,
            cacheKey: fallbackUrl,
            fit: fit,
            alignment: alignment,
            width: double.infinity,
            height: double.infinity,
            memCacheWidth: memCacheWidth,
            fadeInDuration: Duration.zero,
            errorWidget: (_, __, ___) => const ColoredBox(
              color: Color(0xFF1C1C24),
              child: Center(child: Icon(Icons.broken_image_outlined, color: Colors.white24)),
            ),
          );
        }
        return const ColoredBox(
          color: Color(0xFF1C1C24),
          child: Center(child: Icon(Icons.broken_image_outlined, color: Colors.white24)),
        );
      },
    );
  }
}

/// Slow pan-and-zoom so still art feels like it is playing.
class KenBurnsArt extends StatefulWidget {
  const KenBurnsArt({
    super.key,
    required this.url,
    this.fallbackUrl,
    this.memCacheWidth,
    this.fit = BoxFit.cover,
    this.alignment = Alignment.center,
    this.duration = const Duration(seconds: 18),
  });

  final String? url;
  final String? fallbackUrl;
  final int? memCacheWidth;
  final BoxFit fit;
  final Alignment alignment;
  final Duration duration;

  @override
  State<KenBurnsArt> createState() => _KenBurnsArtState();
}

class _KenBurnsArtState extends State<KenBurnsArt> with SingleTickerProviderStateMixin {
  AnimationController? _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: widget.duration)..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final art = CachedArt(
      url: widget.url,
      fallbackUrl: widget.fallbackUrl,
      fit: widget.fit,
      alignment: widget.alignment,
      memCacheWidth: widget.memCacheWidth,
    );
    final controller = _controller;
    if (controller == null) return art;
    return ClipRect(
      child: AnimatedBuilder(
        animation: controller,
        builder: (context, child) {
          final t = Curves.easeInOut.transform(controller.value);
          return Transform.scale(
            scale: 1.02 + (0.045 * t),
            alignment: Alignment(0.06 * (t * 2 - 1), 0),
            filterQuality: FilterQuality.low,
            child: child,
          );
        },
        child: art,
      ),
    );
  }
}

/// Wide banner art: centered crop with darkened sides for title copy.
class BannerArt extends StatelessWidget {
  const BannerArt({
    super.key,
    required this.url,
    this.fallbackUrl,
    this.logoUrl,
  });

  final String? url;
  final String? fallbackUrl;
  final String? logoUrl;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        KenBurnsArt(
          url: url,
          fallbackUrl: fallbackUrl,
          fit: BoxFit.cover,
          alignment: Alignment.center,
          memCacheWidth: !kIsWeb && Platform.isAndroid ? 720 : 1600,
        ),
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: [
                Color(0xF50E0E12),
                Color(0xE00E0E12),
                Color(0x990E0E12),
                Color(0x440E0E12),
                Color(0x140E0E12),
                Color(0x660E0E12),
              ],
              stops: [0.0, 0.18, 0.34, 0.52, 0.78, 1.0],
            ),
          ),
        ),
        if (logoUrl != null && logoUrl!.isNotEmpty)
          Positioned(
            left: 36,
            top: 28,
            width: 280,
            height: 72,
            child: CachedArt(
              url: logoUrl,
              fit: BoxFit.contain,
              alignment: Alignment.centerLeft,
              memCacheWidth: 700,
            ),
          ),
      ],
    );
  }
}
