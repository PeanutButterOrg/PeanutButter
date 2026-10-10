import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'platform/device_profile.dart';

/// How Android plays torrent / HTTP streams.
///
/// Default on physical Android TV is embedded **libVLC** (native SurfaceView
/// behind Flutter — same engine Popcorn/Butter used on Realtek boxes).
///
/// Linux / desktop keep media_kit unchanged — this enum is Android-only.
enum AndroidPlaybackBackend {
  /// In-app libVLC (SurfaceView) — preferred for Android TV boxes.
  vlc,

  /// Launch an external ACTION_VIEW player (VLC app / mpv / …).
  external,

  /// Flutter video_player (Exo) / MediaKit fallback.
  inApp,
}

/// Abstraction over Android playback backends.
class AndroidPlayback {
  AndroidPlayback._();

  static const _channel = MethodChannel('app.peanutbutter/playback');

  /// SharedPreferences key — also used by SettingsNotifier.
  static const prefsKey = 'androidPlaybackBackend';

  static AndroidPlaybackBackend? _override;

  /// Test / forced override. Null = use prefs + device defaults.
  static set debugOverride(AndroidPlaybackBackend? value) => _override = value;

  static AndroidPlaybackBackend fromPrefs(String? raw) {
    return switch (raw) {
      'vlc' => AndroidPlaybackBackend.vlc,
      'external' => AndroidPlaybackBackend.external,
      'inApp' => AndroidPlaybackBackend.inApp,
      // Migrate older default that pointed at external Intent hand-off.
      _ => defaultBackend,
    };
  }

  static String toPrefs(AndroidPlaybackBackend backend) => switch (backend) {
        AndroidPlaybackBackend.vlc => 'vlc',
        AndroidPlaybackBackend.external => 'external',
        AndroidPlaybackBackend.inApp => 'inApp',
      };

  /// Physical Android TVs → embedded VLC. Emulators / phones → in-app Exo.
  /// External Intent hand-off is never the default (TV boxes often lack VLC app).
  static AndroidPlaybackBackend get defaultBackend {
    if (kIsWeb || !Platform.isAndroid) return AndroidPlaybackBackend.inApp;
    if (DeviceProfile.current.isTv) return AndroidPlaybackBackend.vlc;
    return AndroidPlaybackBackend.inApp;
  }

  static bool get isAndroid => !kIsWeb && Platform.isAndroid;

  static AndroidPlaybackBackend effective(AndroidPlaybackBackend backend) {
    return _override ?? backend;
  }

  /// In-app libVLC (SurfaceView). Preferred decoder on physical Android TV.
  static bool usesVlc(AndroidPlaybackBackend backend) {
    return isAndroid && effective(backend) == AndroidPlaybackBackend.vlc;
  }

  /// Legacy external ACTION_VIEW — kept for debugging only, not used for TV.
  static bool usesExternal(AndroidPlaybackBackend backend) {
    return isAndroid && effective(backend) == AndroidPlaybackBackend.external;
  }

  /// Append `key=` for authenticated `/stream/{id}` URLs (VLC + external).
  static String urlWithAuth(String url, String apiToken) {
    final uri = Uri.tryParse(url);
    if (uri == null) return url;
    final host = uri.host.toLowerCase();
    if (host == '127.0.0.1' || host == 'localhost' || host == '::1') return url;
    final token = apiToken.replaceAll(RegExp(r'[^0-9]'), '');
    final key = token.length == 6 ? token : apiToken.trim();
    if (key.isEmpty) return url;
    final q = Map<String, String>.from(uri.queryParameters);
    q['key'] = key;
    return uri.replace(queryParameters: q).toString();
  }

  /// In-app libVLC via native SurfaceView behind Flutter (not PlatformView).
  static const _vlc = MethodChannel('app.peanutbutter/vlc');
  static const _vlcEvents = EventChannel('app.peanutbutter/vlcEvents');

  /// Start native libVLC on [url]. Returns Flutter texture id, or null.
  static Future<int?> startNativeVlc({
    required String url,
    int startMs = 0,
    Map<String, String> headers = const {},
  }) async {
    if (!isAndroid) return null;
    try {
      final raw = await _vlc.invokeMethod<dynamic>('start', {
        'url': url,
        'startMs': startMs,
        'headers': headers,
      });
      if (raw is Map && raw['textureId'] is num) {
        return (raw['textureId'] as num).toInt();
      }
      if (raw is num) return raw.toInt();
      return null;
    } catch (e, st) {
      debugPrint('AndroidPlayback.startNativeVlc failed: $e\n$st');
      return null;
    }
  }

  static Future<void> nativeVlcSetSurfaceSize(int width, int height) async {
    if (!isAndroid) return;
    try {
      await _vlc.invokeMethod<void>('setSurfaceSize', {
        'width': width,
        'height': height,
      });
    } catch (_) {}
  }

  static Future<void> stopNativeVlc() async {
    if (!isAndroid) return;
    try {
      await _vlc.invokeMethod<void>('stop');
    } catch (_) {}
  }

  static Future<void> disposeNativeVlc() async {
    if (!isAndroid) return;
    try {
      await _vlc.invokeMethod<void>('dispose');
    } catch (_) {}
  }

  static Future<void> nativeVlcPlay() async {
    if (!isAndroid) return;
    try {
      await _vlc.invokeMethod<void>('play');
    } catch (_) {}
  }

  static Future<void> nativeVlcPause() async {
    if (!isAndroid) return;
    try {
      await _vlc.invokeMethod<void>('pause');
    } catch (_) {}
  }

  static Future<void> nativeVlcSeek(int ms) async {
    if (!isAndroid) return;
    try {
      await _vlc.invokeMethod<void>('seek', {'ms': ms});
    } catch (_) {}
  }

  static Future<void> nativeVlcSetAudioTrack(int id) async {
    if (!isAndroid) return;
    try {
      await _vlc.invokeMethod<void>('setAudioTrack', {'id': id});
    } catch (_) {}
  }

  static Future<void> nativeVlcSetSpuTrack(int id) async {
    if (!isAndroid) return;
    try {
      await _vlc.invokeMethod<void>('setSpuTrack', {'id': id});
    } catch (_) {}
  }

  static Future<bool> nativeVlcAddSubtitle(String uri) async {
    if (!isAndroid) return false;
    try {
      final ok = await _vlc.invokeMethod<bool>('addSubtitle', {'uri': uri});
      return ok == true;
    } catch (_) {
      return false;
    }
  }

  static Stream<Map<String, dynamic>> get vlcEvents {
    return _vlcEvents.receiveBroadcastStream().map((event) {
      if (event is Map) {
        return event.map((k, v) => MapEntry(k.toString(), v));
      }
      return <String, dynamic>{'event': 'unknown'};
    });
  }

  /// Open [url] in an external video player. Returns false if none installed.
  static Future<bool> openExternal({
    required String url,
    required String title,
    String mimeType = 'video/*',
  }) async {
    if (!isAndroid) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('openExternal', {
        'url': url,
        'title': title,
        'mimeType': mimeType,
      });
      return ok == true;
    } catch (e, st) {
      debugPrint('AndroidPlayback.openExternal failed: $e\n$st');
      return false;
    }
  }

  static Future<bool> hasExternalPlayers() async {
    if (!isAndroid) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('hasExternalPlayers');
      return ok == true;
    } catch (_) {
      return false;
    }
  }
}
