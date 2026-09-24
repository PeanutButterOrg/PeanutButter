import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';

import '../tv_device.dart';

/// Coarse device class used to pick playback + input + nav strategies.
enum DeviceKind { desktop, phone, tv }

/// Cross-platform capabilities. Screens should prefer this over raw
/// `Platform.isX` / `isAndroidTv` checks.
abstract class DeviceProfile {
  const DeviceProfile();

  DeviceKind get kind;

  /// D-pad / Leanback remote navigation.
  bool get prefersDpad;

  /// Fullscreen soft-keyboard overlay instead of inline `TextField`.
  bool get usesSoftKeyboardOverlay;

  /// Player chrome auto-hides after idle.
  bool get autoHidePlayerChrome;

  /// Desktop process restart (Jackett loader).
  bool get canRelaunchProcess;

  bool get isDesktop => kind == DeviceKind.desktop;
  bool get isTv => kind == DeviceKind.tv;
  bool get isPhone => kind == DeviceKind.phone;

  static DeviceProfile? _override;
  static DeviceProfile? _cached;

  /// Tests only.
  static set debugOverride(DeviceProfile? value) {
    _override = value;
    _cached = null;
  }

  static DeviceProfile get current {
    final o = _override;
    if (o != null) return o;
    return _cached ??= resolve();
  }

  /// Call after [TvDevice.init] so Leanback is known.
  static void refresh() {
    if (_override != null) return;
    _cached = resolve();
  }

  static DeviceProfile resolve() {
    if (kIsWeb) return const DesktopDeviceProfile();
    if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
      return const DesktopDeviceProfile();
    }
    if (Platform.isAndroid) {
      if (TvDevice.ready && !TvDevice.isEmulator && TvDevice.isLeanback) {
        return const AndroidTvProfile();
      }
      return const AndroidPhoneProfile();
    }
    return const DesktopDeviceProfile();
  }
}

class DesktopDeviceProfile extends DeviceProfile {
  const DesktopDeviceProfile();

  @override
  DeviceKind get kind => DeviceKind.desktop;

  @override
  bool get prefersDpad => false;

  @override
  bool get usesSoftKeyboardOverlay => false;

  @override
  bool get autoHidePlayerChrome => true;

  @override
  bool get canRelaunchProcess => true;
}

class AndroidPhoneProfile extends DeviceProfile {
  const AndroidPhoneProfile();

  @override
  DeviceKind get kind => DeviceKind.phone;

  @override
  bool get prefersDpad => false;

  @override
  bool get usesSoftKeyboardOverlay => false;

  @override
  bool get autoHidePlayerChrome => true;

  @override
  bool get canRelaunchProcess => false;
}

class AndroidTvProfile extends DeviceProfile {
  const AndroidTvProfile();

  @override
  DeviceKind get kind => DeviceKind.tv;

  @override
  bool get prefersDpad => true;

  @override
  bool get usesSoftKeyboardOverlay => true;

  @override
  bool get autoHidePlayerChrome => true;

  @override
  bool get canRelaunchProcess => false;
}
