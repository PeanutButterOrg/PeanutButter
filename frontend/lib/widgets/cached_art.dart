import 'dart:io' show Platform;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import '../models.dart';

bool _looksLikeImage(List<int> bytes) {
  if (bytes.length < 12) return false;
  // JPEG / PNG / GIF / WEBP — reject HTML/JSON error bodies that confuse ImageDecoder.
  if (bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) return true;
  if (bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47) {
    return true;
  }
  if (bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46) return true;
  if (bytes[0] == 0x52 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x46 &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x45 &&
      bytes[10] == 0x42 &&
      bytes[11] == 0x50) {
    return true;
  }
  return false;
}

class _BytesResponse implements FileServiceResponse {
  _BytesResponse(this._bytes, this.statusCode, {String? contentType})
      : _contentType = contentType,
        _received = DateTime.now();

  final List<int> _bytes;
  final String? _contentType;
  final DateTime _received;

  @override
  Stream<List<int>> get content => Stream<List<int>>.value(_bytes);

  @override
  int? get contentLength => _bytes.length;

  @override
  final int statusCode;

  @override
  DateTime get validTill => _received.add(const Duration(days: 30));

  @override
  String? get eTag => null;

  @override
  String get fileExtension {
    final type = (_contentType ?? '').split(';').first.trim().toLowerCase();
    if (type.contains('png')) return '.png';
    if (type.contains('webp')) return '.webp';
    if (type.contains('gif')) return '.gif';
    if (_bytes.length >= 8 &&
        _bytes[0] == 0x89 &&
        _bytes[1] == 0x50 &&
        _bytes[2] == 0x4E &&
        _bytes[3] == 0x47) {
      return '.png';
    }
    if (_bytes.length >= 12 &&
        _bytes[0] == 0x52 &&
        _bytes[8] == 0x57 &&
        _bytes[9] == 0x45) {
      return '.webp';
    }
    return '.jpg';
  }
}

/// Rejects non-image HTTP bodies before they hit FlutterJNI ImageDecoder.
class _ArtFileService extends FileService {
  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 12),
      responseType: ResponseType.bytes,
      followRedirects: true,
      validateStatus: (s) => s != null && s < 500,
    ),
  );

  @override
  Future<FileServiceResponse> get(String url, {Map<String, String>? headers}) async {
    final response = await _dio.get<List<int>>(
      url,
      options: Options(headers: headers),
    );
    final status = response.statusCode ?? 0;
    final body = response.data ?? const <int>[];
    if (status < 200 || status >= 300 || !_looksLikeImage(body)) {
      throw HttpExceptionWithStatus(
        status == 200 ? 415 : status,
        'Not a decodable image',
        uri: Uri.tryParse(url),
      );
    }
    final contentType = response.headers.value('content-type');
    return _BytesResponse(body, status, contentType: contentType);
  }
}

/// Disk cache for posters and backdrops so scrolling does not re-download art.
class ArtCache {
  static final CacheManager posters = CacheManager(
    Config(
      'catalog_art',
      stalePeriod: const Duration(days: 45),
      maxNrOfCacheObjects: 8000,
      fileService: _ArtFileService(),
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

/// Wide banner art: always fills the hero (cover), with a left scrim for copy.
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
          memCacheWidth: !kIsWeb && Platform.isAndroid ? 720 : 1920,
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
