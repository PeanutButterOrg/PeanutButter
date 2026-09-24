import 'package:flutter_test/flutter_test.dart';
import 'package:peanutbutter/graphql/client.dart';
import 'package:peanutbutter/stream_stats.dart';

void main() {
  group('normalizeServerBase', () {
    test('keeps explicit :3001', () {
      expect(
        normalizeServerBase('http://10.0.0.110:3001/'),
        'http://10.0.0.110:3001',
      );
    });

    test('strips trailing slash without inventing a port', () {
      expect(
        normalizeServerBase('http://10.0.0.110/'),
        'http://10.0.0.110',
      );
    });
  });

  group('resolveServerResourceUrl', () {
    test('rewrites loopback stream URL to paired LAN host', () {
      expect(
        resolveServerResourceUrl(
          'http://127.0.0.1:8080/stream/abc',
          'http://10.0.0.110:3001/',
        ),
        'http://10.0.0.110:3001/stream/abc',
      );
    });

    test('rewrites stale LAN host on /stream/ paths', () {
      expect(
        resolveServerResourceUrl(
          'http://10.0.0.28:3001/stream/xyz',
          'http://10.0.0.110:3001',
        ),
        'http://10.0.0.110:3001/stream/xyz',
      );
    });

    test('leaves external CDN URLs alone', () {
      const tmdb = 'https://image.tmdb.org/t/p/w500/poster.jpg';
      expect(
        resolveServerResourceUrl(tmdb, 'http://10.0.0.110:3001'),
        tmdb,
      );
    });

    test('resolves relative media paths against paired server', () {
      expect(
        resolveServerResourceUrl('/media/foo.mkv', 'http://10.0.0.110:3001'),
        'http://10.0.0.110:3001/media/foo.mkv',
      );
    });
  });

  group('streamStatsLine', () {
    test('shows finding peers when swarm is empty', () {
      expect(
        streamStatsLine(pct: 0, speed: 0, seeders: 0, peers: 0),
        '0%  ·  finding peers…',
      );
    });

    test('shows connected when peers exist but no bytes yet', () {
      expect(
        streamStatsLine(pct: 0, speed: 0, seeders: 0, peers: 12),
        '0%  ·  connected · waiting for data…  ·  12 peers',
      );
    });

    test('shows download speed when transferring', () {
      expect(
        streamStatsLine(pct: 7.4, speed: 3.1, seeders: 12, peers: 12),
        '7%  ·  3.1 MB/s  ·  12 seeds',
      );
    });
  });
}
