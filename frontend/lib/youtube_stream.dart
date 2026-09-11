import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

class YoutubeQualityOption {
  const YoutubeQualityOption({
    required this.label,
    required this.height,
    required this.url,
  });

  final String label;
  final int height;
  final String url;
}

/// HTTP headers YouTube CDN often expects for progressive streams.
const Map<String, String> youtubeStreamHeaders = {
  'User-Agent':
      'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
  'Referer': 'https://www.youtube.com/',
  'Origin': 'https://www.youtube.com',
};

/// Muxed (audio+video) streams only — reliable instant playback in media_kit.
/// Adaptive video-only + separate audio caused black screens / silent play.
Future<List<YoutubeQualityOption>> youtubeQualityOptions(String videoId) async {
  final yt = YoutubeExplode();
  try {
    final manifest = await yt.videos.streamsClient.getManifest(videoId);
    final byHeight = <int, MuxedStreamInfo>{};
    for (final s in manifest.muxed) {
      final h = s.videoResolution.height;
      if (h <= 0) continue;
      final prev = byHeight[h];
      if (prev == null || s.bitrate.bitsPerSecond > prev.bitrate.bitsPerSecond) {
        byHeight[h] = s;
      }
    }
    final heights = byHeight.keys.toList()..sort();
    return [
      for (final h in heights)
        YoutubeQualityOption(
          label: h >= 2160 ? '4K' : '${h}p',
          height: h,
          url: byHeight[h]!.url.toString(),
        ),
    ];
  } finally {
    yt.close();
  }
}

YoutubeQualityOption? youtubePickQuality(
  List<YoutubeQualityOption> options, {
  required int preferHeight,
}) {
  if (options.isEmpty) return null;
  YoutubeQualityOption? pick;
  for (final o in options) {
    if (o.height <= preferHeight) pick = o;
  }
  // Prefer the best available muxed stream (usually 720p) when prefer is higher.
  return pick ?? options.last;
}

int youtubeHeightForQuality(String quality) {
  switch (quality.toLowerCase()) {
    case '480p':
      return 480;
    case '720p':
      return 720;
    case '1080p':
      return 1080;
    case '2160p':
    case '4k':
      return 2160;
    default:
      return 720;
  }
}

void playTrailer(
  BuildContext context, {
  required String videoId,
  required String title,
  String? preferredQuality,
}) {
  context.push(
    '/player/trailer',
    extra: {
      'url': '',
      'title': title,
      'youtubeKey': videoId,
      // Muxed streams top out ~720p; request that for instant reliable play.
      'preferredQuality': preferredQuality ?? '720p',
    },
  );
}
