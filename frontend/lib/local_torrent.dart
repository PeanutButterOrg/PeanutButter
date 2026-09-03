import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:libtorrent_flutter/libtorrent_flutter.dart';
import 'package:path_provider/path_provider.dart';

/// Device-side streaming. Backend only supplies magnets / metadata.
class LocalTorrentEngine {
  LocalTorrentEngine._();
  static final LocalTorrentEngine instance = LocalTorrentEngine._();

  bool _ready = false;
  int? _torrentId;
  int? _streamId;
  String? _savePath;

  bool get supported =>
      !kIsWeb && (Platform.isAndroid || Platform.isLinux || Platform.isWindows || Platform.isMacOS);
  bool get isActive => _torrentId != null;

  Future<void> ensureInit() async {
    if (!supported || _ready) return;
    final tmp = await getTemporaryDirectory();
    _savePath = '${tmp.path}/peanutbutter-streams';
    await Directory(_savePath!).create(recursive: true);
    await LibtorrentFlutter.init(
      uploadLimit: 0,
      downloadLimit: 0,
      defaultSavePath: _savePath,
      fetchTrackers: true,
      pollInterval: const Duration(milliseconds: 400),
    );
    final engine = LibtorrentFlutter.instance;
    engine.configureSession(
      const BtConfig(
        cacheSize: 256 * 1024 * 1024,
        readerReadAhead: 95,
        preloadCache: 80,
        connectionsLimit: 80,
        // Without an HTTP reader, the plugin pauses the torrent after 30s.
        torrentDisconnectTimeout: 86400,
        disableTcp: false,
        disableUtp: false,
        disableUpload: false,
        disableDht: false,
        disableUpnp: false,
        downloadRateLimit: 0,
        uploadRateLimit: 0,
        responsiveMode: true,
      ),
    );
    engine.setDownloadLimit(0);
    engine.setUploadLimit(0);
    try {
      await TrackerManager.fetchBestTrackers().timeout(const Duration(seconds: 5));
    } catch (_) {}
    _ready = true;
  }

  Future<LocalStreamHandle> start({
    required String magnet,
    int? season,
    int? episode,
    void Function(LocalStreamStats stats)? onStats,
  }) async {
    await ensureInit();
    try {
      await TrackerManager.fetchBestTrackers().timeout(const Duration(seconds: 4));
    } catch (_) {}
    await stop();

    final engine = LibtorrentFlutter.instance;
    final magnetUri = TrackerManager.injectTrackers(_withPublicTrackers(magnet));
    final id = engine.addMagnet(magnetUri, _savePath, false);
    _torrentId = id;

    StreamSubscription<Map<int, TorrentInfo>>? updates;
    updates = engine.torrentUpdates.listen((map) {
      final live = map[id];
      if (live != null) onStats?.call(_statsFrom(live, null));
    });

    try {
      final metaDeadline = DateTime.now().add(const Duration(seconds: 180));
      while (DateTime.now().isBefore(metaDeadline)) {
        final info = engine.torrents[id];
        if (info != null && info.isPaused) {
          engine.resumeTorrent(id);
        }
        if (info != null && info.hasMetadata) break;
        if (info?.state == TorrentState.error) {
          await stop();
          throw info!.errorMsg.isNotEmpty
              ? info.errorMsg
              : 'Couldn’t start this stream. Try another result.';
        }
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      final meta = engine.torrents[id];
      if (meta == null || !meta.hasMetadata) {
        await stop();
        throw 'Couldn’t find enough peers to start this stream. Try another result.';
      }
      if (meta.isPaused) engine.resumeTorrent(id);

      final files = engine.getFiles(id);
      final fileIndex = _pickFile(files, season: season, episode: episode);
      if (fileIndex == null) {
        await stop();
        throw 'This source doesn’t contain a playable video file. Try another result.';
      }

      final priorities = List<int>.filled(files.length, 0);
      for (final f in files) {
        if (f.index >= 0 && f.index < priorities.length) {
          priorities[f.index] = f.index == fileIndex ? 7 : 0;
        }
      }
      if (priorities.isNotEmpty) {
        engine.setFilePriorities(id, priorities);
      }
      engine.resumeTorrent(id);

      final stream = engine.startStream(
        id,
        fileIndex: fileIndex,
        maxCacheBytes: 256 * 1024 * 1024,
      );
      _streamId = stream.id;
      engine.setCacheSettings(
        stream.id,
        capacity: 256 * 1024 * 1024,
        readAheadPct: 90,
        connectionsLimit: 80,
      );
      engine.preloadStream(stream.id, preloadBytes: 16 * 1024 * 1024);

      // Hand the HTTP URL to the player quickly so it becomes the torrent reader.
      var url = stream.url;
      final urlDeadline = DateTime.now().add(const Duration(seconds: 8));
      while (url.isEmpty && DateTime.now().isBefore(urlDeadline)) {
        final live = engine.torrents[id];
        if (live != null && live.isPaused) engine.resumeTorrent(id);
        final info = engine.getStreamInfo(stream.id);
        if (live != null) onStats?.call(_statsFrom(live, info));
        url = info?.url ?? url;
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      if (url.isEmpty) {
        await stop();
        throw 'Couldn’t start this stream. Try another result.';
      }
      return LocalStreamHandle(
        torrentId: id,
        streamId: stream.id,
        url: url,
        magnet: magnet,
      );
    } finally {
      await updates.cancel();
    }
  }

  LocalStreamStats? currentStats() {
    final tid = _torrentId;
    final sid = _streamId;
    if (tid == null || !_ready) return null;
    final engine = LibtorrentFlutter.instance;
    var t = engine.torrents[tid];
    if (t != null && t.isPaused) {
      engine.resumeTorrent(tid);
      t = engine.torrents[tid] ?? t;
    }
    if (t == null) return null;
    final s = sid == null ? null : engine.getStreamInfo(sid);
    return _statsFrom(t, s);
  }

  LocalStreamStats _statsFrom(TorrentInfo t, StreamInfo? s) {
    return LocalStreamStats(
      bufferPct: (s?.bufferPct ?? t.progress) * 100,
      downloadMbps: t.downloadRate / (1024 * 1024),
      seeders: t.numSeeds < 0 ? 0 : t.numSeeds,
      peers: t.numPeers < 0 ? 0 : t.numPeers,
      ready: s?.isReady ?? false,
      stateLabel: t.isPaused ? 'Paused' : t.state.label,
    );
  }

  Future<void> stop() async {
    if (!_ready) return;
    final engine = LibtorrentFlutter.instance;
    final sid = _streamId;
    final tid = _torrentId;
    _streamId = null;
    _torrentId = null;
    if (sid != null) {
      try {
        engine.stopStream(sid);
      } catch (_) {}
    }
    if (tid != null) {
      try {
        engine.disposeTorrent(tid);
      } catch (_) {
        try {
          engine.removeTorrent(tid, deleteFiles: true);
        } catch (_) {}
      }
    }
  }

  int? _pickFile(List<FileInfo> files, {int? season, int? episode}) {
    const videoExt = {'mkv', 'mp4', 'avi', 'webm', 'mov', 'm4v'};
    bool isVideo(FileInfo f) {
      final name = f.name.toLowerCase();
      final ext = name.contains('.') ? name.split('.').last : '';
      return videoExt.contains(ext) || f.isStreamable;
    }

    var videos = files.where(isVideo).toList();
    if (videos.isEmpty) return files.isEmpty ? null : files.first.index;

    videos = videos.where((f) {
      final h = ' ${f.name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ')} ';
      return !h.contains(' sample ') && !h.contains(' trailer ');
    }).toList();
    if (videos.isEmpty) {
      videos = files.where(isVideo).toList();
    }

    if (season != null && episode != null) {
      final tag = 's${season.toString().padLeft(2, '0')}e${episode.toString().padLeft(2, '0')}';
      final hits = videos.where((f) {
        final n = f.name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');
        return n.contains(tag) || n.contains('${season}x${episode.toString().padLeft(2, '0')}');
      }).toList();
      if (hits.isNotEmpty) videos = hits;
    }

    videos.sort((a, b) => b.size.compareTo(a.size));
    return videos.first.index;
  }
}

const _publicTrackers = [
  'udp://tracker.opentrackr.org:1337/announce',
  'udp://open.stealth.si:80/announce',
  'udp://tracker.openbittorrent.com:6969/announce',
  'udp://explodie.org:6969/announce',
  'udp://tracker.torrent.eu.org:451/announce',
  'udp://exodus.desync.com:6969/announce',
  'udp://open.demonii.com:1337/announce',
  'udp://tracker.moeking.me:6969/announce',
  'udp://tracker.tiny-vps.com:6969/announce',
  'udp://tracker.dler.org:6969/announce',
  'http://tracker.openbittorrent.com:80/announce',
  'wss://tracker.openwebtorrent.com',
];

String _withPublicTrackers(String magnet) {
  var uri = magnet.trim();
  if (!uri.toLowerCase().startsWith('magnet:')) return uri;
  for (final tr in _publicTrackers) {
    final enc = Uri.encodeComponent(tr);
    if (!uri.contains(enc) && !uri.contains(tr)) {
      uri = '$uri&tr=$enc';
    }
  }
  return uri;
}

class LocalStreamHandle {
  const LocalStreamHandle({
    required this.torrentId,
    required this.streamId,
    required this.url,
    required this.magnet,
  });

  final int torrentId;
  final int streamId;
  final String url;
  final String magnet;
}

class LocalStreamStats {
  const LocalStreamStats({
    required this.bufferPct,
    required this.downloadMbps,
    required this.seeders,
    required this.peers,
    required this.ready,
    this.stateLabel = '',
  });

  final double bufferPct;
  final double downloadMbps;
  final int seeders;
  final int peers;
  final bool ready;
  final String stateLabel;
}
