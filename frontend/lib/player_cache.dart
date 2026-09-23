import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'local_torrent.dart';

/// Clears temporary player / stream files on the device (not the server).
class PlayerCache {
  /// Wipe streamed torrent pieces, media temp files, and app cache dirs.
  static Future<void> clear() async {
    if (kIsWeb) return;

    // Release file locks first or deletes silently fail.
    try {
      await LocalTorrentEngine.instance.purgeDownloads();
    } catch (_) {}

    try {
      final tmp = await getTemporaryDirectory();
      await _wipeTree(Directory('${tmp.path}/peanutbutter-streams'));
      await _wipeChildren(tmp, skipNames: const {'.'});
    } catch (_) {}

    try {
      await _wipeChildren(await getApplicationCacheDirectory());
    } catch (_) {}

    try {
      final support = await getApplicationSupportDirectory();
      await _wipeNamed(support, const ['peanutbutter-streams', 'streams', 'torrents']);
    } catch (_) {}
  }

  static Future<void> _wipeNamed(Directory parent, List<String> names) async {
    if (!await parent.exists()) return;
    for (final name in names) {
      await _wipeTree(Directory('${parent.path}/$name'));
    }
  }

  static Future<void> _wipeTree(Directory dir) async {
    try {
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    } catch (_) {
      await _wipeChildren(dir);
    }
  }

  static Future<void> _wipeChildren(
    Directory dir, {
    Set<String> skipNames = const {},
  }) async {
    if (!await dir.exists()) return;
    await for (final entity in dir.list()) {
      final name = entity.uri.pathSegments.isEmpty
          ? ''
          : entity.uri.pathSegments.last;
      if (skipNames.contains(name)) continue;
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
