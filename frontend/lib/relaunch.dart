import 'dart:io';

import 'package:flutter/foundation.dart';

import 'platform/device_profile.dart';

/// Restart this desktop process so the Jackett catalog loader is the first screen.
/// Android TV stays in-process and shows the same loader overlay instead.
Future<void> relaunchApp() async {
  if (kIsWeb) return;
  if (!DeviceProfile.current.canRelaunchProcess) return;
  final exe = Platform.resolvedExecutable;
  await Process.start(
    exe,
    Platform.executableArguments,
    environment: Platform.environment,
    mode: ProcessStartMode.detached,
    workingDirectory: File(exe).parent.path,
  );
  exit(0);
}

bool get canRelaunchProcess => !kIsWeb && DeviceProfile.current.canRelaunchProcess;
