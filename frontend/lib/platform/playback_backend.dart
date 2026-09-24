import 'dart:async';

import 'package:flutter/widgets.dart';

import '../android_playback.dart';
import 'device_profile.dart';

/// Which engine [PlaybackBackendFactory] selected.
enum PlaybackEngine { mediaKit, exo, vlc }

/// Shared track descriptor for audio / subtitle menus.
class PlaybackTrack {
  const PlaybackTrack({required this.id, required this.label});
  final String id;
  final String label;
}

/// Strategy interface for device-specific video engines.
///
/// [PlayerScreen] owns chrome / seek settle / Skip / Play Next; backends only
/// open media and expose position/tracks/surface.
abstract class PlaybackBackend {
  PlaybackEngine get engine;

  Future<void> open({
    required String url,
    int startMs = 0,
    Map<String, String> headers = const {},
  });

  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);
  Future<void> dispose();

  Duration get position;
  Duration get duration;
  bool get isPlaying;
  bool get hasVideo;

  List<PlaybackTrack> get audioTracks;
  List<PlaybackTrack> get subtitleTracks;
  String? get activeAudioId;
  String? get activeSubtitleId;

  Future<void> setAudioTrack(String id);
  Future<void> setSubtitleTrack(String? id);

  /// Video surface widget (Texture / Video / VideoPlayer).
  Widget buildVideo(BuildContext context);
}

/// Picks media_kit / Exo / VLC from [DeviceProfile] + settings.
class PlaybackBackendFactory {
  PlaybackBackendFactory._();

  static PlaybackEngine resolveEngine(
    DeviceProfile profile,
    AndroidPlaybackBackend androidBackend,
  ) {
    if (profile.isDesktop) return PlaybackEngine.mediaKit;
    if (profile.isTv) {
      final effective = AndroidPlayback.effective(androidBackend);
      if (effective == AndroidPlaybackBackend.vlc) return PlaybackEngine.vlc;
      if (effective == AndroidPlaybackBackend.inApp) return PlaybackEngine.exo;
      // external is ignored for in-player — fall back to VLC on TV.
      return PlaybackEngine.vlc;
    }
    // Phone / emulator: Exo (inApp). Settings may still force VLC.
    final effective = AndroidPlayback.effective(androidBackend);
    if (effective == AndroidPlaybackBackend.vlc) return PlaybackEngine.vlc;
    return PlaybackEngine.exo;
  }

  static bool usesVlc(DeviceProfile profile, AndroidPlaybackBackend backend) =>
      resolveEngine(profile, backend) == PlaybackEngine.vlc;

  static bool usesExo(DeviceProfile profile, AndroidPlaybackBackend backend) =>
      resolveEngine(profile, backend) == PlaybackEngine.exo;

  static bool usesMediaKit(DeviceProfile profile, AndroidPlaybackBackend backend) =>
      resolveEngine(profile, backend) == PlaybackEngine.mediaKit;
}
