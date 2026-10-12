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
  bool _nativeUnavailable = false;
  int? _torrentId;
  int? _streamId;
  String? _savePath;
  /// Active Range probe from [seekTo]; closed in [stop] so leave can't abort.
  HttpClient? _rangeClient;
  int _pullGen = 0;

  bool get supported =>
      !_nativeUnavailable &&
      !kIsWeb &&
      (Platform.isAndroid || Platform.isLinux || Platform.isWindows || Platform.isMacOS);
  bool get isActive => _torrentId != null;

  /// Stub for newer settings/serverInfo callers; 9d785cb used TrackerManager only.
  void configureTrackers(List<String> trackers) {}

  Future<void> prepareTrackers(List<String> serverTrackers) async {
    configureTrackers(serverTrackers);
    try {
      await TrackerManager.fetchBestTrackers().timeout(const Duration(seconds: 4));
    } catch (_) {}
  }

  Future<void> _clearSaveDir() async {
    final root = _savePath;
    if (root == null || root.isEmpty) return;
    final dir = Directory(root);
    try {
      if (!await dir.exists()) {
        await dir.create(recursive: true);
        return;
      }
      await for (final entity in dir.list(recursive: false)) {
        try {
          await entity.delete(recursive: true);
        } catch (_) {}
      }
    } catch (_) {
      try {
        await dir.create(recursive: true);
      } catch (_) {}
    }
  }

  Future<void> ensureInit() async {
    if (!supported || _ready) return;
    try {
      final tmp = await getTemporaryDirectory();
      _savePath = '${tmp.path}/peanutbutter-streams';
      await Directory(_savePath!).create(recursive: true);
      // IPv4-only random port. Default "0.0.0.0:0,[::]:0" also binds Docker /
      // veth interfaces on Linux and announces junk endpoints to the swarm.
      await LibtorrentFlutter.init(
        listenInterface: '0.0.0.0:0',
        uploadLimit: 0,
        downloadLimit: 0,
        defaultSavePath: _savePath,
        fetchTrackers: true,
        pollInterval: const Duration(milliseconds: 400),
      );
      final engine = LibtorrentFlutter.instance;
      engine.configureSession(
        const BtConfig(
          cacheSize: 512 * 1024 * 1024,
          readerReadAhead: 98,
          preloadCache: 90,
          connectionsLimit: 200,
          // Without an HTTP reader, the plugin pauses the torrent after 30s.
          torrentDisconnectTimeout: 86400,
          disableTcp: false,
          disableUtp: false,
          disableUpload: false,
          disableDht: false,
          disableUpnp: false,
          // libtorrent_flutter pins listen to 0.0.0.0:6881 when this is false,
          // which collides with other BitTorrent clients (e.g. Motrix) and hurts
          // macOS/Linux NAT mapping. true keeps createSession's random ports.
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
    try {
      await TrackerManager.fetchBestTrackers().timeout(const Duration(seconds: 4));
    } catch (_) {}
    // Wipe the previous stream's pieces. Leaving partial rarest-first data
    // forces a long "checking files" pass, hash-fails, and peer bans that
    // collapse download rate to a few KB/s on the next play.
    await stop(deleteFiles: true);
    await _clearSaveDir();

    final engine = LibtorrentFlutter.instance;
    final magnetUri = TrackerManager.injectTrackers(_withPublicTrackers(magnet));
    // streamOnly=false: streamOnly=true zeroes every file priority after
    // metadata, libtorrent marks the torrent "finished", and the session
    // sticks paused (~0 KB/s). Pause ourselves right after metadata instead,
    // then let startStream() apply head piece deadlines + resume.
    final id = engine.addMagnet(magnetUri, _savePath, false);
    _torrentId = id;

    StreamSubscription<Map<int, TorrentInfo>>? updates;
    updates = engine.torrentUpdates.listen((map) {
      final live = map[id];
      if (live != null) onStats?.call(_statsFrom(live, null));
    });

    try {
      final metaDeadline = DateTime.now().add(const Duration(seconds: 180));
      List<FileInfo> files = const [];
      while (DateTime.now().isBefore(metaDeadline)) {
        final info = engine.torrents[id];
        if (info != null && !info.hasMetadata && info.isPaused) {
          engine.resumeTorrent(id);
        }
        // Prefer getFiles(): FFI hasMetadata can stay false after the native
        // metadata_received alert while status is stuck on checking_files.
        try {
          files = engine.getFiles(id);
        } catch (_) {
          files = const [];
        }
        if (files.isNotEmpty || info?.hasMetadata == true) break;
        if (info?.state == TorrentState.error) {
          await stop();
          throw info!.errorMsg.isNotEmpty
              ? info.errorMsg
              : 'Couldn’t start this stream. Try another result.';
        }
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      if (files.isEmpty) {
        try {
          files = engine.getFiles(id);
        } catch (_) {}
      }
      final meta = engine.torrents[id];
      if (meta == null || (files.isEmpty && !meta.hasMetadata)) {
        await stop();
        throw 'Couldn’t find enough peers to start this stream. Try another result.';
      }

      // Do not pause here — startStream() sets dont_download + head deadlines
      // then resume() atomically. An extra pause left the torrent "finished"
      // (wanted=0) and stalled peer connections for minutes on Linux.

      final chosen = fileIndex ?? _pickFile(files, season: season, episode: episode);
      if (chosen == null) {
        await stop();
        throw 'This source doesn’t contain a playable video file. Try another result.';
      }
      if (fileIndex != null && !files.any((f) => f.index == fileIndex)) {
        await stop();
        throw 'That file isn’t in this torrent anymore. Pick another file.';
      }

      // Do NOT call setFilePriorities() — async prioritize_files races and
      // wipes startStream() piece deadlines (head starvation / 0% buffer).

      final stream = engine.startStream(
        id,
        fileIndex: chosen,
        maxCacheBytes: 512 * 1024 * 1024,
      );
      _streamId = stream.id;
      // Cap per-torrent peers (TorrServer uses ~25). 200 fans requests across
      // slow peers and stalls the critical head pieces.
      engine.setCacheSettings(
        stream.id,
        capacity: 512 * 1024 * 1024,
        readAheadPct: 95,
        connectionsLimit: 25,
      );
      engine.preloadStream(stream.id, preloadBytes: 32 * 1024 * 1024);
      try {
        engine.resumeTorrent(id);
      } catch (_) {}

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

      // Wait for a real stream head — not mere mid-file download rate.
      // Opening on "any download" hid the peer HUD and played an empty pipe.
      final headDeadline = DateTime.now().add(const Duration(seconds: 120));
      while (DateTime.now().isBefore(headDeadline)) {
        final live = engine.torrents[id];
        if (live != null && live.isPaused) engine.resumeTorrent(id);
        final info = engine.getStreamInfo(stream.id);
        if (live != null) onStats?.call(_statsFrom(live, info));
        final bytes = live?.totalDone ?? 0;
        // progress=1.0 with wanted=0 (dont_download) is NOT complete.
        final complete = (live?.progress ?? 0) >= 0.99 &&
            (live?.totalWanted ?? 0) > 0 &&
            bytes >= (live?.totalWanted ?? 0) &&
            bytes > 8 * 1024 * 1024;
        final ready = info?.isReady == true || complete;
        // Stream window fill (head readahead), not whole-torrent progress.
        final headBuffered = (info?.bufferPct ?? 0) > 0.02 || bytes > 512 * 1024;
        if (ready || headBuffered || complete) break;
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
    // Head/tail "finished" auto-pauses the torrent and drops peers. Keep it
    // running while a stream is active so the player can pull the next window.
    if (t != null &&
        (t.isPaused ||
            t.state == TorrentState.finished ||
            t.state == TorrentState.seeding)) {
      try {
        engine.resumeTorrent(tid);
      } catch (_) {}
      t = engine.torrents[tid] ?? t;
    }
    if (t == null) return null;
    final s = sid == null ? null : engine.getStreamInfo(sid);
    return _statsFrom(t, s);
  }

  LocalStreamStats _statsFrom(TorrentInfo t, StreamInfo? s) {
    // Prefer torrent file progress for the HUD % (user-facing "downloaded").
    // Fall back to stream readahead window when metadata is thin — but never
    // let a full readahead window report as 100% of the torrent.
    final rawProgress = t.progress.isFinite ? t.progress : 0.0;
    final windowPct = ((s?.bufferPct ?? 0) * 100).clamp(0.0, 100.0);
    final fileSize = s?.fileSize ?? 0;
    // startStream() only "wants" head+tail. When those finish, libtorrent
    // reports progress=1.0 / state=finished even though ~98% of the movie
    // is still dont_download — that used to flash "100%" and auto-pause.
    final doneOfFile =
        fileSize > 0 ? (t.totalDone / fileSize).clamp(0.0, 1.0) : 0.0;
    final complete = fileSize > 0
        ? doneOfFile >= 0.98
        : (rawProgress >= 0.99 &&
            t.totalWanted > 64 * 1024 * 1024 &&
            t.totalDone >= t.totalWanted);
    double bufferPct;
    if (complete) {
      bufferPct = 100.0;
    } else if (fileSize > 0 && t.totalDone > 0) {
      // Whole-file % so head-only completion can't look finished.
      final filePct = (doneOfFile * 100).clamp(0.0, 99.0);
      bufferPct =
          windowPct > filePct ? windowPct.clamp(0.0, 95.0) : filePct;
    } else if (windowPct >= 1.0) {
      bufferPct = windowPct.clamp(0.0, 95.0);
    } else if (t.totalDone > 0) {
      bufferPct = ((t.totalDone / (32 * 1024 * 1024)) * 100).clamp(0.0, 40.0);
    } else {
      bufferPct = 0.0;
    }
    // libtorrent sometimes reports junk sizes (e.g. 16384). Treat as unknown.
    final rawPeers = t.numPeers;
    final rawSeeds = t.numSeeds;
    final streamPeers = s?.activePeers ?? 0;
    final peers = (rawPeers > 0 && rawPeers < 10000)
        ? rawPeers
        : (streamPeers > 0 && streamPeers < 10000 ? streamPeers : 0);
    final seeds = (rawSeeds <= 0 || rawSeeds >= 10000) ? 0 : rawSeeds;
    final torrentRate = t.downloadRate < 0 ? 0 : t.downloadRate;
    final streamRate = (s?.downloadRate ?? 0) < 0 ? 0 : (s?.downloadRate ?? 0);
    final rate = torrentRate > 0 ? torrentRate : streamRate;
    return LocalStreamStats(
      bufferPct: bufferPct,
      downloadMbps: rate / (1024 * 1024),
      seeders: seeds,
      peers: peers,
      ready: s?.isReady == true ||
          t.totalDone > 256 * 1024 ||
          (doneOfFile >= 0.002 && t.totalDone > 0),
      // Prefer libtorrent state while pieces are moving — isPaused can stick
      // true in FFI status even as piece_finished alerts keep firing.
      stateLabel: s?.streamState.name ??
          ((t.downloadRate > 0 || t.totalDone > 0) &&
                  t.state != TorrentState.error
              ? t.state.label
              : (t.isPaused ? 'Paused' : t.state.label)),
      torrentComplete: complete,
      // Connected if we have sane peer counts OR bytes are moving / FFI junk.
      swarmActive: peers > 0 ||
          seeds > 0 ||
          rate > 0 ||
          t.totalDone > 0 ||
          rawPeers >= 10000 ||
          rawSeeds >= 10000,
    );
  }

  Future<void> stop({bool deleteFiles = true}) async {
    if (!_ready) return;
    final engine = LibtorrentFlutter.instance;
    final sid = _streamId;
    final tid = _torrentId;
    _streamId = null;
    _torrentId = null;
    // Kill seek Range probes first — they hold the stream HTTP open.
    _pullGen++;
    try {
      _rangeClient?.close(force: true);
    } catch (_) {}
    _rangeClient = null;
    // Pause before stopStream so peers/readers quiet down.
    if (tid != null) {
      try {
        engine.pauseTorrent(tid);
      } catch (_) {}
    }
    if (sid != null) {
      try {
        engine.stopStream(sid);
      } catch (_) {}
    }
    // Let HTTP readers / libmpv drop the socket before we tear down the
    // torrent handle. Removing under an active reader aborts the process
    // ("terminate called without an active exception") on Linux/desktop.
    await Future<void>.delayed(const Duration(milliseconds: 500));
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
      if (info != null &&
          (info.isPaused ||
              info.state == TorrentState.finished ||
              info.state == TorrentState.seeding)) {
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
      engine.setCacheSettings(
        sid,
        capacity: 512 * 1024 * 1024,
        readAheadPct: 95,
        connectionsLimit: 25,
      );
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
    final gen = ++_pullGen;
    try {
      _rangeClient?.close(force: true);
    } catch (_) {}
    _rangeClient = null;
    HttpClient? client;
    try {
      client = HttpClient()..connectionTimeout = const Duration(seconds: 4);
      if (gen != _pullGen) return;
      _rangeClient = client;
      final end = (offset + (4 * 1024 * 1024) - 1).clamp(offset, fileSize - 1);
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set(HttpHeaders.rangeHeader, 'bytes=$offset-$end');
      final res = await req.close().timeout(const Duration(seconds: 8));
      if (gen != _pullGen) return;
      // Drain up to ~2 MB so the reader advances and peers send those pieces.
      var got = 0;
      await for (final chunk in res.timeout(const Duration(seconds: 12))) {
        if (gen != _pullGen) break;
        got += chunk.length;
        if (got >= 2 * 1024 * 1024) break;
      }
    } catch (_) {
    } finally {
      if (identical(_rangeClient, client)) _rangeClient = null;
      try {
        client?.close(force: true);
      } catch (_) {}
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
  'udp://tracker1.bt.moack.co.kr:80/announce',
  'udp://tracker.theoks.net:6969/announce',
  'udp://tracker.bittor.pw:1337/announce',
  'udp://tracker.filemail.com:6969/announce',
  'udp://tracker.bitsearch.to:1337/announce',
  'udp://bt1.archive.org:6969/announce',
  'udp://bt2.archive.org:6969/announce',
  'http://tracker.openbittorrent.com:80/announce',
  'http://tracker.opentrackr.org:1337/announce',
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

/// Thrown when a newer [LocalTorrentEngine.start] supersedes this one.
class LocalStreamCancelled implements Exception {}

class LocalStreamStats {
  const LocalStreamStats({
    required this.bufferPct,
    required this.downloadMbps,
    required this.seeders,
    required this.peers,
    required this.ready,
    this.stateLabel = '',
    this.torrentComplete = false,
    this.swarmActive = false,
  });

  final double bufferPct;
  final double downloadMbps;
  final int seeders;
  final int peers;
  final bool ready;
  final String stateLabel;
  final bool torrentComplete;
  final bool swarmActive;
}
