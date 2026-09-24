import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Loads libmpv on a Java background thread so the Flutter UI isolate never
/// blocks on first [Player] construction (Android TV ANR).
class MediaKitAndroidVideo {
  MediaKitAndroidVideo._();

  static const _channel =
      MethodChannel('com.alexmercerind.media_kit_libs_android_video');

  static Future<bool>? _loading;
  static var _ready = false;

  static bool get isReady => _ready;

  /// Kick off (or await) background libmpv load. Safe to call many times.
  static Future<bool> preload() {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return Future.value(true);
    }
    if (_ready) return Future.value(true);
    return _loading ??= _load();
  }

  static Future<bool> _load() async {
    try {
      final ok = await _channel
          .invokeMethod<bool>('loadNativeLibraries')
          .timeout(const Duration(seconds: 30), onTimeout: () => false);
      _ready = ok == true;
      return _ready;
    } catch (e, st) {
      debugPrint('MediaKitAndroidVideo.preload failed: $e\n$st');
      _ready = false;
      return false;
    } finally {
      _loading = null;
    }
  }
}
