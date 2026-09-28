import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../android_playback.dart';
import '../providers/catalog.dart';
import '../theme.dart';
import '../tv.dart';
import '../widgets/cached_art.dart';
import '../widgets/tv_chrome.dart';

/// Phase‑0 Android TV playback lab.
///
/// Lists trending titles (for visual context) plus fixed HTTPS probe clips.
/// Play opens the native [TvLabPlayerActivity] (LibVLC → real SurfaceView).
class TvLabScreen extends ConsumerWidget {
  const TvLabScreen({super.key});

  static const _probes = <({String title, String url, String codec})>[
    (
      title: 'Big Buck Bunny · H.264',
      url:
          'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4',
      codec: 'H.264 / AAC',
    ),
    (
      title: 'Elephants Dream · H.264',
      url:
          'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ElephantsDream.mp4',
      codec: 'H.264 / AAC',
    ),
    (
      title: 'Sintel · H.264',
      url:
          'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/Sintel.mp4',
      codec: 'H.264 / AAC',
    ),
  ];

  Future<void> _openLab(BuildContext context, String url, String title) async {
    if (kIsWeb || !Platform.isAndroid) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('TV Lab is Android-only (native SurfaceView).')),
        );
      }
      return;
    }
    final ok = await AndroidPlayback.openTvLab(url: url, title: title);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open TV Lab player.')),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final feed = ref.watch(homeFeedProvider('MOVIE'));

    return Scaffold(
      backgroundColor: AppTheme.canvas,
      body: ListView(
        padding: const EdgeInsets.fromLTRB(28, 20, 28, 120),
        children: [
          Row(
            children: [
              TvFocus(
                child: IconButton(
                  tooltip: 'Back',
                  onPressed: () => Navigator.of(context).maybePop(),
                  icon: const Icon(Icons.arrow_back_rounded),
                ),
              ),
              Text(
                'TV Playback Lab',
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Phase 0 — native LibVLC SurfaceView (no Flutter Texture). '
            'D-pad: OK play/pause · ←/→ ±10s · Back exit.',
            style: TextStyle(color: Colors.white.withValues(alpha: 0.65), height: 1.35),
          ),
          const SizedBox(height: 28),
          Text(
            'Codec probes',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 12),
          for (final p in _probes) ...[
            TvFocus(
              child: ListTile(
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                tileColor: const Color(0xFF121218),
                title: Text(p.title, style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: Text(p.codec, style: const TextStyle(color: Colors.white54)),
                trailing: const Icon(Icons.play_circle_outline_rounded),
                onTap: () => _openLab(context, p.url, p.title),
              ),
            ),
            const SizedBox(height: 8),
          ],
          const SizedBox(height: 24),
          Text(
            'Trending (catalog)',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Text(
            'Opens the same SurfaceView lab with a trailer YouTube progressive URL when available, '
            'otherwise the first H.264 probe. Use this only to confirm UI → native hand-off.',
            style: TextStyle(color: Colors.white.withValues(alpha: 0.55), fontSize: 13, height: 1.35),
          ),
          const SizedBox(height: 12),
          feed.when(
            loading: () => const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (e, _) => Text('Could not load trending: $e', style: const TextStyle(color: Colors.redAccent)),
            data: (data) {
              final items = data.trending.take(16).toList();
              if (items.isEmpty) {
                return const Text('No trending titles — pair to a server first.', style: TextStyle(color: Colors.white54));
              }
              return SizedBox(
                height: isAndroidTv ? 220 : 200,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: items.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 12),
                  itemBuilder: (context, i) {
                    final t = items[i];
                    return TvFocus(
                      child: InkWell(
                        borderRadius: BorderRadius.circular(10),
                        onTap: () => _openLab(
                          context,
                          _probes.first.url,
                          '${t.title} · probe',
                        ),
                        child: SizedBox(
                          width: 120,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(10),
                                  child: CachedArt(
                                    url: t.posterUrl,
                                    fit: BoxFit.cover,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                t.title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}
