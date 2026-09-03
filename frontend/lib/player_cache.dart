import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Clears temporary player/cache files on the device (not the server).
class PlayerCache {
  static Future<void> clear() async {
    if (kIsWeb) return;
    for (final dir in [await getTemporaryDirectory(), await getApplicationCacheDirectory()]) {
      await _wipe(dir);
    }
  }

  static Future<void> _wipe(Directory dir) async {
    if (!await dir.exists()) return;
    await for (final entity in dir.list()) {
      try {
        if (entity is File) {
          await entity.delete();
        } else if (entity is Directory) {
          await entity.delete(recursive: true);
        }
      } catch (_) {}
    }
  }
}
