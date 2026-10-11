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

      // Keep downloading / printing for a few minutes so we can see swarm grow.
      final until = DateTime.now().add(const Duration(minutes: 3));
      while (DateTime.now().isBefore(until)) {
        final s = engine.currentStats() ?? last;
        if (s != null) {
          say(
            'tick ${s.bufferPct.toStringAsFixed(1)}%  '
            '${s.downloadMbps.toStringAsFixed(2)} MB/s  '
            'peers=${s.peers} seeds=${s.seeders} ready=${s.ready}',
          );
          if (s.downloadMbps >= 0.5 && s.peers >= 5) {
            say('PASS: healthy swarm');
            await engine.stop(deleteFiles: false);
            exit(0);
          }
        }
        // Also Range-read the HTTP URL so the piece window can grow.
        if (handle.url.startsWith('http')) {
          unawaited(_nudge(handle.url));
        }
        await Future<void>.delayed(const Duration(seconds: 2));
      }
      final s = engine.currentStats() ?? last;
      say(
        'DONE peers=${s?.peers} seeds=${s?.seeders} '
        'mbps=${s?.downloadMbps} pct=${s?.bufferPct}',
      );
      await engine.stop(deleteFiles: false);
      exit((s?.peers ?? 0) > 0 ? 0 : 4);
    } catch (e, st) {
      say('FAIL: $e');
      stderr.writeln(st);
      await engine.stop(deleteFiles: false);
      exit(5);
    }
  }

  Future<void> _nudge(String url) async {
    HttpClient? client;
    try {
      client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-${2 * 1024 * 1024 - 1}');
      final res = await req.close().timeout(const Duration(seconds: 8));
      var got = 0;
      await for (final chunk in res.timeout(const Duration(seconds: 8))) {
        got += chunk.length;
        if (got >= 512 * 1024) break;
      }
    } catch (_) {
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
