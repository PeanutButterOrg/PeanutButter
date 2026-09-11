import 'dart:async';

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

/// Single Android client — much faster than the default multi-client fallback chain.
const List<YoutubeApiClient> _fastYtClients = [YoutubeApiClient.android];

MuxedStreamInfo? _bestMuxed(Iterable<MuxedStreamInfo> muxed, int preferHeight) {
  MuxedStreamInfo? bestAtOrUnder;
  MuxedStreamInfo? bestOverall;
  for (final s in muxed) {
    final h = s.videoResolution.height;
    if (h <= 0) continue;
    if (bestOverall == null ||
        h > bestOverall.videoResolution.height ||
        (h == bestOverall.videoResolution.height &&
            s.bitrate.bitsPerSecond > bestOverall.bitrate.bitsPerSecond)) {
      bestOverall = s;
    }
    if (h <= preferHeight) {
      if (bestAtOrUnder == null ||
          h > bestAtOrUnder.videoResolution.height ||
          (h == bestAtOrUnder.videoResolution.height &&
              s.bitrate.bitsPerSecond > bestAtOrUnder.bitrate.bitsPerSecond)) {
        bestAtOrUnder = s;
      }
    }
  }
  return bestAtOrUnder ?? bestOverall;
}

YoutubeQualityOption _optionFromMuxed(MuxedStreamInfo s) {
  final h = s.videoResolution.height;
  return YoutubeQualityOption(
    label: h >= 2160 ? '4K' : '${h}p',
    height: h,
    url: s.url.toString(),
  );
}

/// Resolve one playable muxed URL quickly (for trailer autoplay).
Future<YoutubeQualityOption?> youtubeFastMuxed(
  String videoId, {
  int preferHeight = 720,
}) async {
  final yt = YoutubeExplode();
  try {
    final manifest = await yt.videos.streamsClient.getManifest(
      videoId,
      ytClients: _fastYtClients,
    );
    final pick = _bestMuxed(manifest.muxed, preferHeight);
    return pick == null ? null : _optionFromMuxed(pick);
  } finally {
    yt.close();
  }
}

/// Muxed (audio+video) streams only — reliable instant playback in media_kit.
Future<List<YoutubeQualityOption>> youtubeQualityOptions(String videoId) async {
  final yt = YoutubeExplode();
  try {
    final manifest = await yt.videos.streamsClient.getManifest(
      videoId,
      ytClients: _fastYtClients,
    );
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
      for (final h in heights) _optionFromMuxed(byHeight[h]!),
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

Future<void> playTrailer(
  BuildContext context, {
  required String videoId,
  required String title,
  String? preferredQuality,
}) async {
  final height = youtubeHeightForQuality(preferredQuality ?? '720p');
  YoutubeQualityOption? pick;
  try {
    pick = await youtubeFastMuxed(videoId, preferHeight: height)
        .timeout(const Duration(seconds: 8));
  } catch (_) {
    pick = null;
  }
  if (!context.mounted) return;
  context.push(
    '/player/trailer',
    extra: {
      'url': pick?.url ?? '',
      'title': title,
      'youtubeKey': videoId,
      'preferredQuality': preferredQuality ?? '720p',
      if (pick != null) 'trailerHeight': pick.height,
    },
  );
}
