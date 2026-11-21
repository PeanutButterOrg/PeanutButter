import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'local_torrent.dart';

/// Clears temporary player / stream files on the device (not the server).
class PlayerCache {
  /// Wipe streamed torrent pieces, media temp files, and app cache dirs.
  ///
  /// [onlyGeneration]: a closing player's cleanup. Stops as soon as another
  /// stream has started (the torrent engine's number moved on), so it can't
  /// wipe the next video's pieces.
  static Future<void> clear({int? onlyGeneration}) async {
    if (kIsWeb) return;
    bool stale() => onlyGeneration != null && onlyGeneration != LocalTorrentEngine.instance.generation;

    // Release file locks first or deletes silently fail.
    try {
      await LocalTorrentEngine.instance.purgeDownloads(onlyGeneration: onlyGeneration);
    } catch (_) {}

    if (stale()) return;
    try {
      // Only our own folder. The temp dir is shared with every other program
      // on Linux (/tmp) and Windows (%TEMP%) — wiping all of it deleted other
      // apps' files.
      final tmp = await getTemporaryDirectory();
      await _wipeTree(Directory('${tmp.path}/peanutbutter-streams'));
    } catch (_) {}

    if (stale()) return;
    try {
      // Keep artwork: this is the *stream* cache. Settings → Artwork cache
      // clears posters explicitly via ArtCache.clear().
      await _wipeChildren(
        await getApplicationCacheDirectory(),
        skipNames: const {'catalog_art', 'libCachedImageData'},
      );
    } catch (_) {}

    if (stale()) return;
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
      // Not uri.pathSegments: a directory URI ends in '/', so .last is ''.
      final name = entity.path.split(Platform.pathSeparator).last;
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
