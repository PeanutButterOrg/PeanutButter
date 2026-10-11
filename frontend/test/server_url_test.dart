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
        'Finding peers…',
      );
    });

    test('shows Buffering like Android TV when peers exist but no bytes yet', () {
      expect(
        streamStatsLine(pct: 0, speed: 0, seeders: 0, peers: 12),
        'Buffering 1%  ·  12 peers',
      );
    });

    test('shows ready when progress is complete and video is playing', () {
      expect(
        streamStatsLine(pct: 100, speed: 0, seeders: 5, peers: 5, hasVideo: true, playing: true),
        '100%  ·  ready  ·  5 peers',
      );
    });

    test('shows true readiness once video is playing even while seeding', () {
      expect(
        streamStatsLine(pct: 100, speed: 1.2, seeders: 5, peers: 5, hasVideo: true, playing: true),
        '100%  ·  1.2 MB/s  ·  5 peers',
      );
    });

    test('does not claim complete pre-play while still downloading', () {
      expect(
        streamStatsLine(pct: 100, speed: 1.2, seeders: 5, peers: 5),
        'Buffering 99%  ·  1.2 MB/s  ·  5 peers',
      );
    });

    test('ignores fake 100% with empty swarm before playback', () {
      expect(
        streamStatsLine(pct: 100, speed: 0, seeders: 0, peers: 0),
        'Finding peers…',
      );
    });

    test('keeps real 100% when peers exist even before video', () {
      expect(
        streamStatsLine(pct: 100, speed: 0, seeders: 0, peers: 3),
        'Buffering 100%  ·  3 peers',
      );
    });

    test('shows Buffering with KB/s like TV-style progress', () {
      expect(
        streamStatsLine(pct: 12, speed: 0.02, seeders: 0, peers: 4),
        'Buffering 12%  ·  20 KB/s  ·  4 peers',
      );
    });

    test('labels seeders as peers like Android TV', () {
      expect(
        streamStatsLine(pct: 12, speed: 0.02, seeders: 7, peers: 0),
        'Buffering 12%  ·  20 KB/s  ·  7 peers',
      );
    });
  });
}
