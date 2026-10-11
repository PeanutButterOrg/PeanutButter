// Linux smoke: start a public-domain torrent, assert we buffer head bytes
// BEFORE returning a playable HTTP stream URL (player must not open on rate alone).
//
// Success: start() returns http(s) URL + head is readable via disk under the
// LocalTorrentEngine save dir and/or soft HTTP Range probes. Disk head alone
// is enough to PASS when HTTP is flaky (Linux skips pre-open HTTP probes).
//
// Run:
//   cd frontend && flutter run -d linux -t tool/torrent_head_smoke.dart --release
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:peanutbutter/local_torrent.dart';

/// Sintel (Blender Foundation, CC-BY) — widely seeded.
const _sintelMagnet =
    'magnet:?xt=urn:btih:08ada5a7a6183aae1e09d831df6748d566095a10'
    '&dn=Sintel'
    '&tr=udp%3A%2F%2Ftracker.opentrackr.org%3A1337%2Fannounce'
    '&tr=udp%3A%2F%2Fopen.stealth.si%3A80%2Fannounce'
    '&tr=udp%3A%2F%2Ftracker.torrent.eu.org%3A451%2Fannounce'
    '&tr=udp%3A%2F%2Fexplodie.org%3A6969%2Fannounce';

const _wantHead = 64 * 1024;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const _SmokeApp());
}

class _SmokeApp extends StatefulWidget {
  const _SmokeApp();

  @override
  State<_SmokeApp> createState() => _SmokeAppState();
}

class _SmokeAppState extends State<_SmokeApp> {
  final _lines = <String>[];

  void say(String m) {
    final line = '[smoke] $m';
    stdout.writeln(line);
    if (mounted) setState(() => _lines.add(line));
  }

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  /// Same root LocalTorrentEngine.ensureInit uses.
  Future<Directory> _saveDir() async {
    final tmp = await getTemporaryDirectory();
    return Directory('${tmp.path}/peanutbutter-streams');
  }

  /// Largest non-trivial file under save dir with a readable non-sparse head.
  Future<({int got, String path})> _probeDiskHead() async {
    final root = await _saveDir();
    if (!await root.exists()) {
      return (got: 0, path: root.path);
    }
    File? best;
    var bestLen = 0;
    await for (final ent in root.list(recursive: true, followLinks: false)) {
      if (ent is! File) continue;
      final name = ent.path.toLowerCase();
      if (!(name.endsWith('.mp4') ||
          name.endsWith('.mkv') ||
          name.endsWith('.webm') ||
          name.endsWith('.avi'))) {
        continue;
      }
      final len = await ent.length();
      if (len > bestLen) {
        bestLen = len;
        best = ent;
      }
    }
    if (best == null) {
      // Fall back: any file ≥ 64KB
      await for (final ent in root.list(recursive: true, followLinks: false)) {
        if (ent is! File) continue;
        final len = await ent.length();
        if (len > bestLen && len >= _wantHead) {
          bestLen = len;
          best = ent;
        }
      }
    }
    if (best == null) return (got: 0, path: root.path);

    final raf = await best.open();
    try {
      final buf = await raf.read(256 * 1024);
      final nz = buf.take(64).any((b) => b != 0);
      return (got: nz ? buf.length : 0, path: best.path);
    } finally {
      await raf.close();
    }
  }

  Future<int> _probeHttpHead(Uri playUri) async {
    var got = 0;
    for (var attempt = 1; attempt <= 4; attempt++) {
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
      try {
        final req = await client.getUrl(playUri);
        req.headers.set(
          HttpHeaders.rangeHeader,
          'bytes=0-${256 * 1024 - 1}',
        );
        final res = await req.close().timeout(const Duration(seconds: 20));
        got = 0;
        try {
          await for (final chunk in res.timeout(const Duration(seconds: 20))) {
            got += chunk.length;
            if (got >= 256 * 1024) break;
          }
        } on HttpException catch (e) {
          say('post-start HTTP attempt $attempt closed after ${got}B ($e)');
        }
      } catch (e) {
        say('post-start HTTP attempt $attempt error: $e');
      } finally {
        client.close(force: false);
      }
      say('post-start HTTP probe attempt=$attempt got=${got}B');
      if (got >= _wantHead) break;
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    return got;
  }

  Future<void> _run() async {
    var lastPct = -1.0;
    var sawClimbingHud = false;
    final sw = Stopwatch()..start();

    try {
      say('init LocalTorrentEngine…');
      await LocalTorrentEngine.instance.ensureInit();
      if (!LocalTorrentEngine.instance.supported) {
        say('FAIL: local torrent not supported on this build');
        exit(2);
      }

      say('start magnet (Sintel) — must buffer head before return…');
      final handle = await LocalTorrentEngine.instance.start(
        magnet: _sintelMagnet,
        onStats: (s) {
          if (s.bufferPct > lastPct + 0.5) {
            lastPct = s.bufferPct;
            say(
              'hud ${s.bufferPct.toStringAsFixed(0)}%  '
              '${s.downloadMbps.toStringAsFixed(2)} MB/s  '
              'peers=${s.peers} swarm=${s.swarmActive} ready=${s.ready}',
            );
          }
          if (s.bufferPct >= 5) sawClimbingHud = true;
        },
      );

      final stats = LocalTorrentEngine.instance.currentStats();
      say(
        'start() returned in ${sw.elapsedMilliseconds}ms '
        'url=${handle.url} '
        'statsPct=${stats?.bufferPct} ready=${stats?.ready} '
        'swarm=${stats?.swarmActive}',
      );

      if (handle.url.isEmpty) {
        say('FAIL: empty stream URL');
        exit(3);
      }

      final playUri = Uri.parse(handle.url);
      final isFile = playUri.scheme == 'file';
      final isHttp = playUri.scheme == 'http' || playUri.scheme == 'https';
      if (!isFile && !isHttp) {
        say('FAIL: expected file:// or http(s) URL, got ${playUri.scheme}');
        exit(5);
      }
      say('handoff OK: ${playUri.scheme} URL');

      final disk = await _probeDiskHead();
      say('post-start disk head got=${disk.got}B path=${disk.path}');

      var httpGot = 0;
      if (isHttp) {
        httpGot = await _probeHttpHead(playUri);
      } else if (isFile) {
        final f = File(playUri.toFilePath());
        if (await f.exists()) {
          final raf = await f.open();
          try {
            final buf = await raf.read(256 * 1024);
            httpGot = buf.take(64).any((b) => b != 0) ? buf.length : 0;
          } finally {
            await raf.close();
          }
          say('post-start file:// head got=${httpGot}B');
        }
      }

      final diskOk = disk.got >= _wantHead;
      final playOk = httpGot >= _wantHead;
      if (!diskOk && !playOk) {
        say(
          'FAIL: neither disk nor play URL can serve ≥${_wantHead}B '
          '(disk=${disk.got}B play=${httpGot}B)',
        );
        exit(4);
      }

      if (!sawClimbingHud) {
        say('WARN: HUD never climbed above 5% (ok if instant cache hit)');
      }

      say(
        'PASS — buffered before handoff '
        '(disk=${disk.got}B play=${httpGot}B scheme=${playUri.scheme} '
        '${sw.elapsedMilliseconds}ms)',
      );
      await LocalTorrentEngine.instance.stop(deleteFiles: true);
      exit(0);
    } catch (e, st) {
      say('FAIL: $e');
      stderr.writeln(st);
      try {
        await LocalTorrentEngine.instance.stop(deleteFiles: true);
      } catch (_) {}
      exit(1);
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        backgroundColor: Colors.black,
        body: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const Text(
              'Linux torrent head-buffer smoke',
              style: TextStyle(color: Colors.white, fontSize: 18),
            ),
            const SizedBox(height: 12),
            ..._lines.map(
              (l) => Text(l, style: const TextStyle(color: Colors.white70, fontSize: 12)),
            ),
          ],
        ),
      ),
    );
  }
}
