import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'platform/device_profile.dart';

/// Native Android device traits (emulator vs real SoC vs Leanback).
class TvDevice {
  TvDevice._();

  static const _channel = MethodChannel('app.peanutbutter/device');

  static bool? _emulator;
  static bool? _leanback;
  static String? _hardware;
  static String? _model;
  static List<String> _abis = const [];

  static bool get ready => _emulator != null;

  static bool get isEmulator => _emulator ?? false;

  /// True on Android TV / Leanback devices (not phones).
  static bool get isLeanback => _leanback ?? false;

  static String get hardware => _hardware ?? '';

  static String get model => _model ?? '';

  static List<String> get abis => _abis;

  /// Prefer MediaKit on real Android TVs when VLC is unavailable.
  static bool get preferMediaKitVideo {
    if (kIsWeb || !Platform.isAndroid) return false;
    if (isEmulator) return false;
    if (_abis.any((a) => a.contains('x86'))) return false;
    return isLeanback;
  }

  static Future<void> init() async {
    if (kIsWeb || !Platform.isAndroid) {
      _emulator = false;
      _leanback = false;
      DeviceProfile.refresh();
      return;
    }
    try {
      final raw = await _channel.invokeMethod<dynamic>('deviceProfile');
      if (raw is Map) {
        _emulator = raw['emulator'] == true;
        _leanback = raw['leanback'] == true;
        _hardware = raw['hardware']?.toString();
        _model = raw['model']?.toString();
        final abis = raw['abis'];
        if (abis is List) {
          _abis = abis.map((e) => e.toString()).toList(growable: false);
        }
      } else {
        _emulator = false;
        _leanback = false;
      }
    } catch (e) {
      debugPrint('TvDevice.init failed: $e');
      _emulator = false;
      _leanback = false;
    }
    DeviceProfile.refresh();
    debugPrint(
      'TvDevice emulator=$isEmulator leanback=$isLeanback model=$model '
      'hardware=$hardware abis=$abis profile=${DeviceProfile.current.kind}',
    );
  }
}
