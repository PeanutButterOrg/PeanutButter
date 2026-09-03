import 'dart:io';

import 'package:flutter/foundation.dart';

/// Restart this desktop process so the Jackett catalog loader is the first screen.
/// Android TV stays in-process and shows the same loader overlay instead.
Future<void> relaunchApp() async {
  if (kIsWeb) return;
  if (!(Platform.isLinux || Platform.isMacOS || Platform.isWindows)) return;
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

bool get canRelaunchProcess {
  if (kIsWeb) return false;
  return Platform.isLinux || Platform.isMacOS || Platform.isWindows;
}
