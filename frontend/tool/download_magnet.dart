// Download a magnet via LocalTorrentEngine and print swarm stats.
//
//   cd frontend && flutter run -d linux -t tool/download_magnet.dart --release \
//     --dart-define=MAGNET_FILE=/tmp/pb-spiderman/magnet.txt
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:peanutbutter/local_torrent.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const _App());
}

class _App extends StatefulWidget {
  const _App();
  @override
  State<_App> createState() => _AppState();
}

class _AppState extends State<_App> {
  final _lines = <String>[];

  void say(String m) {
    final line = '[dl] $m';
    stdout.writeln(line);
    if (mounted) setState(() => _lines.add(line));
  }

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  Future<void> _run() async {
    final path = const String.fromEnvironment(
      'MAGNET_FILE',
      defaultValue: '/tmp/pb-spiderman/magnet.txt',
    );
    final magnet = await File(path).readAsString();
    final m = magnet.trim();
    if (!m.toLowerCase().startsWith('magnet:')) {
      say('FAIL: no magnet in $path');
      exit(2);
    }
    say('magnet=${m.substring(0, m.length.clamp(0, 80))}…');

    final engine = LocalTorrentEngine.instance;
    await engine.ensureInit();
    if (!engine.supported) {
      say('FAIL: LocalTorrentEngine unsupported');
      exit(3);
    }

    LocalStreamStats? last;
    try {
      final handle = await engine.start(
        magnet: m,
        onStats: (s) {
          last = s;
          stdout.writeln(
            '[stats] ${s.bufferPct.toStringAsFixed(1)}%  '
            '${s.downloadMbps.toStringAsFixed(2)} MB/s  '
            'peers=${s.peers} seeds=${s.seeders}  '
            'ready=${s.ready} swarm=${s.swarmActive}  ${s.stateLabel}',
          );
        },
      );
      say('start() returned url=${handle.url}');
      var peakMbps = 0.0;
      var peakPct = 0.0;
      var httpGot = 0;
      final httpSw = Stopwatch()..start();

      // Simulate a player: walk Range requests forward so the stream window
      // advances past the initial head/tail preload.
      if (handle.url.startsWith('http')) {
        unawaited(() async {
          var offset = 0;
          const chunk = 2 * 1024 * 1024;
          while (offset < 64 * 1024 * 1024) {
            final n = await _nudgeAt(handle.url, offset, chunk);
            if (n <= 0) {
              await Future<void>.delayed(const Duration(milliseconds: 500));
              continue;
            }
            httpGot += n;
            offset += n;
            final sec = httpSw.elapsedMilliseconds / 1000.0;
            if (sec > 0) {
              final mbps = (httpGot / (1024 * 1024)) / sec;
              if (mbps > peakMbps) peakMbps = mbps;
              say(
                'http +${(n / 1024).toStringAsFixed(0)}KB '
                'total=${(httpGot / (1024 * 1024)).toStringAsFixed(1)}MB '
                'avg=${mbps.toStringAsFixed(2)} MB/s off=$offset',
              );
            }
          }
        }());
      }

      // Keep downloading / printing for a few minutes so we can see swarm grow.
      final until = DateTime.now().add(const Duration(minutes: 3));
      while (DateTime.now().isBefore(until)) {
        final s = engine.currentStats() ?? last;
        if (s != null) {
          if (s.downloadMbps > peakMbps) peakMbps = s.downloadMbps;
          if (s.bufferPct > peakPct) peakPct = s.bufferPct;
          say(
            'tick ${s.bufferPct.toStringAsFixed(1)}%  '
            '${s.downloadMbps.toStringAsFixed(2)} MB/s  '
            'peers=${s.peers} seeds=${s.seeders} ready=${s.ready} '
            'httpMB=${(httpGot / (1024 * 1024)).toStringAsFixed(1)}',
          );
          // Healthy stream: real HTTP throughput from the local stream server.
          if (httpGot >= 8 * 1024 * 1024 && peakMbps >= 0.15) {
            say(
              'PASS: streaming '
              'peak=${peakMbps.toStringAsFixed(2)} MB/s '
              'httpMB=${(httpGot / (1024 * 1024)).toStringAsFixed(1)} '
              'pct=${peakPct.toStringAsFixed(1)}',
            );
            await engine.stop(deleteFiles: false);
            exit(0);
          }
        }
        await Future<void>.delayed(const Duration(seconds: 2));
      }
      final s = engine.currentStats() ?? last;
      say(
        'DONE peers=${s?.peers} seeds=${s?.seeders} '
        'mbps=${s?.downloadMbps} pct=${s?.bufferPct} '
        'peakMbps=${peakMbps.toStringAsFixed(2)} peakPct=${peakPct.toStringAsFixed(1)} '
        'httpMB=${(httpGot / (1024 * 1024)).toStringAsFixed(1)}',
      );
      await engine.stop(deleteFiles: false);
      exit(httpGot >= 2 * 1024 * 1024 || peakMbps >= 0.05 ? 0 : 4);
    } catch (e, st) {
      say('FAIL: $e');
      stderr.writeln(st);
      await engine.stop(deleteFiles: false);
      exit(5);
    }
  }

  Future<int> _nudgeAt(String url, int offset, int length) async {
    HttpClient? client;
    try {
      client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
      final req = await client.getUrl(Uri.parse(url));
      final end = offset + length - 1;
      req.headers.set(HttpHeaders.rangeHeader, 'bytes=$offset-$end');
      final res = await req.close().timeout(const Duration(seconds: 45));
      var got = 0;
      await for (final chunk in res.timeout(const Duration(seconds: 45))) {
        got += chunk.length;
        if (got >= length) break;
      }
      return got;
    } catch (_) {
      return 0;
    } finally {
      client?.close(force: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        backgroundColor: Colors.black,
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            for (final l in _lines)
              Text(l, style: const TextStyle(color: Colors.white70, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}
