import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

Future<String> youtubePlaybackUrl(String videoId) async {
  final yt = YoutubeExplode();
  try {
    final manifest = await yt.videos.streamsClient.getManifest(videoId);
    final muxedHd = manifest.muxed.where((s) => s.videoResolution.height >= 720).toList();
    if (muxedHd.isNotEmpty) {
      return muxedHd.withHighestBitrate().url.toString();
    }
    final muxed = manifest.muxed;
    if (muxed.isNotEmpty) {
      return muxed.withHighestBitrate().url.toString();
    }
    final videoHd = manifest.videoOnly.where((s) => s.videoResolution.height >= 720);
    if (videoHd.isNotEmpty) {
      return videoHd.withHighestBitrate().url.toString();
    }
    return manifest.videoOnly.withHighestBitrate().url.toString();
  } finally {
    yt.close();
  }
}

void playTrailer(BuildContext context, {required String videoId, required String title}) {
  context.push(
    '/player/trailer',
    extra: {
      'url': '',
      'title': title,
      'youtubeKey': videoId,
    },
  );
}
