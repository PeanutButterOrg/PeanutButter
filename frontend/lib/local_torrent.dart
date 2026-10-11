import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:libtorrent_flutter/libtorrent_flutter.dart';
import 'package:path_provider/path_provider.dart';

/// Device-side streaming. Backend only supplies magnets / metadata.
///
/// Trackers: always merge [ngosang/trackerslist](https://github.com/ngosang/trackerslist)
/// best announces (serverInfo.streamTrackers + offline fallback + TrackerManager)
/// into every Jackett magnet. Indexer `tr=` alone is not enough.
class LocalTorrentEngine {
  LocalTorrentEngine._();
  static final LocalTorrentEngine instance = LocalTorrentEngine._();

  bool _ready = false;
  bool _nativeUnavailable = false;
  int? _torrentId;
  int? _streamId;
  String? _savePath;
  List<String> _extraTrackers = const [];

  bool get supported =>
      !_nativeUnavailable &&
      !kIsWeb &&
      (Platform.isAndroid || Platform.isLinux || Platform.isWindows || Platform.isMacOS);
  bool get isActive => _torrentId != null;

  /// Live list from serverInfo.streamTrackers (ngosang + optional Jackett harvest).
  void configureTrackers(List<String> trackers) {
    _extraTrackers = trackers
        .map((t) => t.trim())
        .where((t) => t.isNotEmpty)
        .toSet()
        .take(40)
        .toList(growable: false);
  }

  List<String> get _activeTrackers =>
      _extraTrackers.isNotEmpty ? _extraTrackers : _fallbackBest;

  Future<void> ensureInit() async {
    if (!supported || _ready) return;
    try {
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
      // Desktop (esp. macOS sandbox) needs DHT + UPnP + both transports.
      // connectionsLimit here is piece-request fanout, not peer count.
      engine.configureSession(
        const BtConfig(
          cacheSize: 256 * 1024 * 1024,
          readerReadAhead: 98,
          preloadCache: 90,
          connectionsLimit: 80,
          // Without an HTTP reader, the plugin pauses the torrent after 30s.
          torrentDisconnectTimeout: 86400,
          disableTcp: false,
          disableUtp: false,
          disableUpload: false,
          disableDht: false,
          disableUpnp: false,
          enableIpv6: true,
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
    } catch (e, st) {
      // Android Studio TV x86 emulator has no libtorrent x86 .so — keep app usable.
      _nativeUnavailable = true;
      debugPrint('LocalTorrentEngine unavailable: $e\n$st');
    }
  }

  Future<LocalStreamHandle> start({
    required String magnet,
    int? season,
    int? episode,
    int? fileIndex,
    void Function(LocalStreamStats stats)? onStats,
  }) async {
    await ensureInit();
    if (!_ready || _nativeUnavailable) {
      throw 'On-device torrent streaming isn’t available on this device. '
          'Update the app or try another platform build.';
    }
    try {
      await TrackerManager.fetchBestTrackers().timeout(const Duration(seconds: 4));
    } catch (_) {}
    // Keep pieces on disk by default so resume / clear-cache-off works.
    // Callers that want a wipe pass deleteFiles via stop() or purgeDownloads().
    await stop(deleteFiles: false);

    final engine = LibtorrentFlutter.instance;
    final id = await _addSource(engine, magnet.trim());
    _torrentId = id;

    StreamSubscription<Map<int, TorrentInfo>>? updates;
    updates = engine.torrentUpdates.listen((map) {
      final live = map[id];
      if (live != null) onStats?.call(_statsFrom(live, null));
    });

    try {
      // Hard ceiling; keep waiting past the soft deadline while peers/DHT are live.
      // Desktop (macOS especially) often needs longer for DHT/UPnP bootstrap.
      final softDeadline = DateTime.now().add(const Duration(seconds: 180));
      final hardDeadline = DateTime.now().add(const Duration(seconds: 360));
      var sawPeers = false;
      var lastPeers = 0;
      var lastSeeds = 0;
      var ticks = 0;
      while (DateTime.now().isBefore(hardDeadline)) {
        final info = engine.torrents[id];
        if (info != null && info.isPaused) {
          engine.resumeTorrent(id);
        }
        if (info != null) {
          lastPeers = info.numPeers < 0 ? 0 : info.numPeers;
          lastSeeds = info.numSeeds < 0 ? 0 : info.numSeeds;
          if (lastPeers > 0 || lastSeeds > 0 || info.downloadRate > 0) {
            sawPeers = true;
          }
          onStats?.call(_statsFrom(info, null));
        }
        if (info != null && info.hasMetadata) break;
        if (info?.state == TorrentState.error) {
          await stop();
          throw info!.errorMsg.isNotEmpty
              ? info.errorMsg
              : 'Couldn’t start this stream. Try another result.';
        }
        // Periodically re-inject trackers / resume — DHT can stall on first announce.
        ticks++;
        if (ticks % 40 == 0) {
          try {
            engine.resumeTorrent(id);
          } catch (_) {}
        }
        // No swarm activity after soft deadline → fail fast with a clear reason.
        if (DateTime.now().isAfter(softDeadline) && !sawPeers) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      final meta = engine.torrents[id];
      if (meta == null || !meta.hasMetadata) {
        await stop();
        if (sawPeers || lastPeers > 0) {
          throw 'Found peers but couldn’t fetch torrent metadata in time. '
              'Try another result.';
        }
        throw 'Couldn’t find enough peers to start this stream. Try another result.';
      }
      if (meta.isPaused) engine.resumeTorrent(id);

      final files = engine.getFiles(id);
      final chosen = fileIndex ?? _pickFile(files, season: season, episode: episode);
      if (chosen == null) {
        await stop();
        throw 'This source doesn’t contain a playable video file. Try another result.';
      }
      if (fileIndex != null && !files.any((f) => f.index == fileIndex)) {
        await stop();
        throw 'That file isn’t in this torrent anymore. Pick another file.';
      }

      final priorities = List<int>.filled(files.length, 0);
      for (final f in files) {
        if (f.index >= 0 && f.index < priorities.length) {
          priorities[f.index] = f.index == chosen ? 7 : 0;
        }
      }
      if (priorities.isNotEmpty) {
        engine.setFilePriorities(id, priorities);
      }
      engine.resumeTorrent(id);

      final stream = engine.startStream(
        id,
        fileIndex: chosen,
        maxCacheBytes: 512 * 1024 * 1024,
      );
      _streamId = stream.id;
      engine.setCacheSettings(
        stream.id,
        capacity: 512 * 1024 * 1024,
        readAheadPct: 95,
        connectionsLimit: 200,
      );
      engine.preloadStream(stream.id, preloadBytes: 32 * 1024 * 1024);

      // Wait until the HTTP stream URL exists AND we have a little head data
      // (or live download), so the player doesn't open an empty pipe.
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

      final headDeadline = DateTime.now().add(const Duration(seconds: 90));
      while (DateTime.now().isBefore(headDeadline)) {
        final live = engine.torrents[id];
        if (live != null && live.isPaused) engine.resumeTorrent(id);
        final info = engine.getStreamInfo(stream.id);
        if (live != null) onStats?.call(_statsFrom(live, info));
        final complete = (live?.progress ?? 0) >= 0.99;
        final ready = info?.isReady == true || complete;
        final buffered = (info?.bufferPct ?? live?.progress ?? 0) > 0.002;
        final downloading = (live?.downloadRate ?? 0) > 16 * 1024;
        // Open as soon as the HTTP pipe exists and we have any head data,
        // or the whole file is already on disk (100% complete case).
        if (ready || buffered || downloading || complete) break;
        if (live?.state == TorrentState.error) {
          await stop();
          throw live!.errorMsg.isNotEmpty
              ? live.errorMsg
              : 'Couldn’t start this stream. Try another result.';
        }
        await Future<void>.delayed(const Duration(milliseconds: 250));
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
    // Prefer torrent file progress for the HUD % (user-facing "downloaded").
    // Fall back to stream readahead window when metadata is thin.
    final torrentPct = (t.progress * 100).clamp(0.0, 100.0);
    final windowPct = ((s?.bufferPct ?? 0) * 100).clamp(0.0, 100.0);
    final complete = t.progress >= 0.99;
    final streamReady = s?.isReady == true || complete;
    // Once the HTTP stream can serve, report 100% readiness — capping at 99
    // forever made Android sit on "99% buffering" after the pipe was open.
    double bufferPct;
    if (streamReady || complete) {
      bufferPct = 100.0;
    } else if (windowPct >= torrentPct && windowPct > 0.5) {
      bufferPct = windowPct.clamp(0.0, 99.0);
    } else if (torrentPct >= 1.0) {
      bufferPct = torrentPct.clamp(0.0, 99.0);
    } else {
      bufferPct = torrentPct.clamp(0.0, 99.0);
    }
    return LocalStreamStats(
      bufferPct: bufferPct,
      downloadMbps: t.downloadRate / (1024 * 1024),
      seeders: t.numSeeds < 0 ? 0 : t.numSeeds,
      peers: t.numPeers < 0 ? 0 : t.numPeers,
      ready: streamReady || t.progress >= 0.01,
      stateLabel: s?.streamState.name ?? (t.isPaused ? 'Paused' : t.state.label),
      torrentComplete: complete,
    );
  }

  Future<void> stop({bool deleteFiles = true}) async {
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
        if (deleteFiles) {
          engine.removeTorrent(tid, deleteFiles: true);
        } else {
          engine.disposeTorrent(tid);
        }
      } catch (_) {
        try {
          engine.disposeTorrent(tid);
        } catch (_) {}
      }
    }
  }

  /// Stop every local torrent and delete downloaded stream pieces from disk.
  Future<void> purgeDownloads() async {
    if (!supported) return;
    try {
      await stop(deleteFiles: true);
    } catch (_) {}
    if (_ready) {
      try {
        final engine = LibtorrentFlutter.instance;
        final ids = engine.torrents.keys.toList();
        for (final id in ids) {
          try {
            engine.removeTorrent(id, deleteFiles: true);
          } catch (_) {
            try {
              engine.disposeTorrent(id);
            } catch (_) {}
          }
        }
      } catch (_) {}
    }
    final root = _savePath ??
        '${(await getTemporaryDirectory()).path}/peanutbutter-streams';
    final dir = Directory(root);
    try {
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    } catch (_) {
      // Best-effort: remove children if the folder is busy.
      try {
        if (await dir.exists()) {
          await for (final entity in dir.list(recursive: false)) {
            try {
              await entity.delete(recursive: true);
            } catch (_) {}
          }
        }
      } catch (_) {}
    }
  }

  /// Keep piece download going while the player is paused (HTTP reader may idle).
  void keepDownloading() {
    final id = _torrentId;
    if (id == null || !_ready) return;
    try {
      final engine = LibtorrentFlutter.instance;
      final info = engine.torrents[id];
      if (info != null && info.isPaused) {
        engine.resumeTorrent(id);
      }
      final sid = _streamId;
      if (sid != null) {
        engine.preloadStream(sid, preloadBytes: 32 * 1024 * 1024);
      }
    } catch (_) {}
  }

  /// After a player seek, move the HTTP reader window to [positionMs].
  ///
  /// libtorrent's stream server follows Range requests — we probe the estimated
  /// byte offset so piece deadlines jump to that point and download sequentially
  /// from there (not from t=0). Do **not** call [preloadStream] here — that
  /// re-prioritizes head+tail and undoes the seek window.
  void seekTo({required int positionMs, int? durationMs}) {
    final id = _torrentId;
    if (id == null || !_ready) return;
    try {
      final engine = LibtorrentFlutter.instance;
      final info = engine.torrents[id];
      if (info != null && info.isPaused) {
        engine.resumeTorrent(id);
      }
      // Fully downloaded — nothing to retarget; player seek alone is enough.
      if (info != null && info.progress >= 0.99) {
        return;
      }
      final sid = _streamId;
      if (sid == null) return;
      final stream = engine.getStreamInfo(sid);
      // Don't reset a 512MB cache on every scrub — that spikes RAM and can take
      // down the Windows process while libmpv is also seeking.
      final fileSize = stream?.fileSize ?? 0;
      final url = stream?.url ?? '';
      final dur = durationMs ?? 0;
      if (url.isNotEmpty && fileSize > 0 && dur > 0 && positionMs > 0) {
        final ratio = (positionMs / dur).clamp(0.0, 0.98);
        final offset = (fileSize * ratio).floor();
        // Keep reading ahead from the seek point so pieces fill sequentially.
        unawaited(_pullFromOffset(url, offset, fileSize));
      }
    } catch (_) {}
  }

  /// Open a lasting Range reader at [offset] so libtorrent's piece window
  /// follows playback instead of buffering the whole file from byte 0.
  Future<void> _pullFromOffset(String url, int offset, int fileSize) async {
    HttpClient? client;
    try {
      client = HttpClient()..connectionTimeout = const Duration(seconds: 4);
      final end = (offset + (4 * 1024 * 1024) - 1).clamp(offset, fileSize - 1);
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set(HttpHeaders.rangeHeader, 'bytes=$offset-$end');
      final res = await req.close().timeout(const Duration(seconds: 8));
      // Drain up to ~2 MB so the reader advances and peers send those pieces.
      var got = 0;
      await for (final chunk in res.timeout(const Duration(seconds: 12))) {
        got += chunk.length;
        if (got >= 2 * 1024 * 1024) break;
      }
    } catch (_) {
    } finally {
      client?.close(force: true);
    }
  }

  /// Magnets go through tracker injection. Jackett `.torrent` HTTP links are
  /// downloaded then added via [addTorrentFile] (addMagnet can't resolve them).
  Future<int> _addSource(LibtorrentFlutter engine, String source) async {
    final lower = source.toLowerCase();
    if (lower.startsWith('magnet:')) {
      final magnetUri = TrackerManager.injectTrackers(_mergeTrackers(source));
      return engine.addMagnet(magnetUri, _savePath, false);
    }
    if (lower.startsWith('http://') || lower.startsWith('https://')) {
      final bytes = await _downloadTorrentBytes(source);
      final dir = Directory(_savePath!);
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final file = File(
        '${dir.path}/src-${DateTime.now().millisecondsSinceEpoch}.torrent',
      );
      await file.writeAsBytes(bytes, flush: true);
      return engine.addTorrentFile(file.path, _savePath, false);
    }
    throw 'Unsupported torrent source. Pick another result.';
  }

  Future<List<int>> _downloadTorrentBytes(String url) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 12);
    try {
      final req = await client.getUrl(Uri.parse(url));
      final res = await req.close().timeout(const Duration(seconds: 20));
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw 'Couldn’t download that torrent file (HTTP ${res.statusCode}). '
            'Try another result.';
      }
      final bytes = await res.fold<List<int>>(<int>[], (a, b) {
        a.addAll(b);
        if (a.length > 8 * 1024 * 1024) {
          throw 'Torrent file is too large. Try another result.';
        }
        return a;
      }).timeout(const Duration(seconds: 25));
      if (bytes.length < 16) {
        throw 'That torrent download was empty. Try another result.';
      }
      return bytes;
    } finally {
      client.close(force: true);
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

/// Offline fallback matching ngosang trackers_best (same set the server embeds).
const _fallbackBest = [
  'udp://tracker.opentrackr.org:1337/announce',
  'udp://open.stealth.si:80/announce',
  'udp://tracker.torrent.eu.org:451/announce',
  'udp://open.demonii.com:1337/announce',
  'udp://exodus.desync.com:6969/announce',
  'udp://tracker.skynetcloud.site:6969/announce',
  'udp://tracker.qu.ax:6969/announce',
  'udp://tracker.tryhackx.org:6969/announce',
  'udp://tracker.corpscorp.online:80/announce',
  'udp://tracker.bittor.pw:1337/announce',
  'udp://tracker.nyaa.vc:6969/announce',
  'udp://tracker-udp.gbitt.info:80/announce',
  'udp://tracker.ducks.party:1984/announce',
  'udp://explodie.org:6969/announce',
  'udp://tracker2.dler.org:80/announce',
  'udp://tracker.gmi.gd:6969/announce',
  'udp://tracker.dler.org:6969/announce',
  'udp://retracker01-msk-virt.corbina.net:80/announce',
  'http://tracker.dler.com:6969/announce',
  'http://tracker.renfei.net:8080/announce',
  'http://open.acgtracker.com:1096/announce',
  'https://tracker.nanoha.org:443/announce',
  'http://tracker.gbitt.info/announce',
  'https://tracker.lilithraws.org/announce',
  'http://t.overflow.biz/announce',
  'https://tr.bangumi.moe:9696/announce',
];

String _mergeTrackers(String magnet) {
  var uri = magnet.trim();
  if (!uri.toLowerCase().startsWith('magnet:')) return uri;
  // Prefer HTTP(S) announces first — some desktop networks (and macOS paths)
  // drop UDP tracker traffic while TCP/HTTP still works.
  final trackers = [
    ...LocalTorrentEngine.instance._activeTrackers
        .where((t) => t.startsWith('http://') || t.startsWith('https://')),
    ...LocalTorrentEngine.instance._activeTrackers
        .where((t) => !t.startsWith('http://') && !t.startsWith('https://')),
  ].take(40);
  for (final tr in trackers) {
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
    this.torrentComplete = false,
  });

  final double bufferPct;
  final double downloadMbps;
  final int seeders;
  final int peers;
  final bool ready;
  final String stateLabel;
  final bool torrentComplete;
}
