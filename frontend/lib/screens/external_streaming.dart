import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:graphql_flutter/graphql_flutter.dart';

import '../android_playback.dart';
import '../graphql/client.dart';
import '../graphql/queries.dart';
import '../local_torrent.dart';
import '../models.dart';
import '../providers/settings.dart';
import '../stream_stats.dart';
import '../theme.dart';
import '../tv.dart';
import '../widgets/cached_art.dart';
import '../widgets/tv_chrome.dart';

/// Host screen while an external Android player owns video.
///
/// Keeps the torrent/session alive, shows swarm stats, and can re-launch VLC.
class ExternalStreamingScreen extends ConsumerStatefulWidget {
  const ExternalStreamingScreen({
    super.key,
    required this.sessionId,
    required this.streamUrl,
    required this.title,
    this.titleId,
    this.posterUrl,
    this.backdropUrl,
    this.magnet,
    this.localTorrent = false,
    this.listedSeeders = 0,
    this.listedPeers = 0,
  });

  final String sessionId;
  final String streamUrl;
  final String title;
  final String? titleId;
  final String? posterUrl;
  final String? backdropUrl;
  final String? magnet;
  final bool localTorrent;
  final int listedSeeders;
  final int listedPeers;

  @override
  ConsumerState<ExternalStreamingScreen> createState() =>
      _ExternalStreamingScreenState();
}

class _ExternalStreamingScreenState extends ConsumerState<ExternalStreamingScreen> {
  late final GraphQLClient _client;
  late String _playUrl;
  Timer? _poll;
  StreamSession? _info;
  String? _error;
  bool _launching = false;
  final _reopenFocus = FocusNode(debugLabel: 'external-reopen');
  final _backFocus = FocusNode(debugLabel: 'external-back');

  @override
  void initState() {
    super.initState();
    playbackSessionActive = true;
    _client = ref.read(graphQLClientProvider);
    final token = ref.read(settingsProvider).apiToken;
    _playUrl = AndroidPlayback.urlWithAuth(
      resolveServerResourceUrl(widget.streamUrl, ref.read(settingsProvider).serverUrl),
      token,
    );
    _poll = Timer.periodic(const Duration(seconds: 1), (_) => unawaited(_tick()));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_prepareThenLaunch());
      if (isAndroidTv && _reopenFocus.canRequestFocus) {
        _reopenFocus.requestFocus();
      }
    });
  }

  Future<void> _prepareThenLaunch() async {
    setState(() => _launching = true);
    for (var i = 0; i < 90; i++) {
      await _tick();
      if (!mounted) return;
      final session = _info;
      final url = _playUrl.trim();
      final ready = url.isNotEmpty &&
          (widget.localTorrent ||
              widget.sessionId.startsWith('local-') ||
              (session != null && session.isReady));
      if (ready) {
        await _launch();
        return;
      }
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    if (mounted) {
      setState(() {
        _launching = false;
        _error = 'Stream never became ready. Try another source.';
      });
    }
  }

  @override
  void dispose() {
    playbackSessionActive = false;
    _poll?.cancel();
    _reopenFocus.dispose();
    _backFocus.dispose();
    unawaited(_stopSession());
    super.dispose();
  }

  Future<void> _stopSession() async {
    final id = widget.sessionId;
    if (widget.localTorrent || id.startsWith('local-')) {
      await LocalTorrentEngine.instance.stop();
      return;
    }
    try {
      await _client.mutate(
        MutationOptions(
          document: gql(STOP_STREAM),
          variables: {'sessionId': id},
        ),
      );
    } catch (_) {}
  }

  Future<void> _tick() async {
    if (!mounted) return;
    if (widget.localTorrent || widget.sessionId.startsWith('local-')) {
      final local = LocalTorrentEngine.instance.currentStats();
      if (local == null || !mounted) return;
      setState(() {
        _info = StreamSession(
          id: widget.sessionId,
          title: widget.title,
          progress: local.bufferPct,
          bufferProgress: local.bufferPct,
          downloadMbps: local.downloadMbps,
          seeders: local.seeders,
          peers: local.peers,
          status: local.ready ? 'ready' : 'buffering',
          streamUrl: _playUrl,
          resumePosition: 0,
        );
      });
      return;
    }
    try {
      final result = await _client.query(
        QueryOptions(
          document: gql(STREAM_STATUS),
          fetchPolicy: FetchPolicy.networkOnly,
          variables: {'sessionId': widget.sessionId},
        ),
      );
      if (!mounted || result.hasException) return;
      final raw = result.data?['streamStatus'];
      if (raw is! Map<String, dynamic>) return;
      final session = StreamSession.fromJson(raw);
      setState(() => _info = session);
      if (session.streamUrl.isNotEmpty) {
        final token = ref.read(settingsProvider).apiToken;
        _playUrl = AndroidPlayback.urlWithAuth(
          resolveServerResourceUrl(session.streamUrl, ref.read(settingsProvider).serverUrl),
          token,
        );
      }
    } catch (_) {}
  }

  Future<void> _launch() async {
    if (_launching) return;
    setState(() {
      _launching = true;
      _error = null;
    });
    final ok = await AndroidPlayback.openExternal(
      url: _playUrl,
      title: widget.title,
    );
    if (!mounted) return;
    setState(() {
      _launching = false;
      if (!ok) {
        _error =
            'No video player found. Install VLC or mpv, or switch to In-app playback in Settings.';
      }
    });
  }

  Future<void> _close() async {
    playbackSessionActive = false;
    await _stopSession();
    if (mounted) context.pop();
  }

  @override
  Widget build(BuildContext context) {
    final art = widget.backdropUrl ?? widget.posterUrl;
    final info = _info;
    final pct = ((info?.bufferProgress ?? 0) * 100).clamp(0, 100);
    final speed = info?.downloadMbps ?? 0;
    final seeders = info?.seeders ?? widget.listedSeeders;
    final peers = info?.peers ?? widget.listedPeers;
    final line = streamStatsLine(
      pct: pct.toDouble(),
      speed: speed,
      seeders: seeders,
      peers: peers,
      hasVideo: true,
      playing: true,
    );

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        await _close();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          fit: StackFit.expand,
          children: [
            if (art != null && art.isNotEmpty)
              CachedArt(url: art, fallbackUrl: widget.posterUrl, fit: BoxFit.cover),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.55),
                    Colors.black.withValues(alpha: 0.88),
                  ],
                ),
              ),
            ),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(28, 16, 28, 28),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TvFocus(
                      child: IconButton(
                        focusNode: _backFocus,
                        onPressed: _close,
                        icon: const Icon(Icons.arrow_back, color: Colors.white),
                      ),
                    ),
                    const Spacer(),
                    Text(
                      widget.title,
                      style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                            color: Colors.white,
                            fontWeight: FontWeight.w800,
                          ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      _launching
                          ? 'Opening external player…'
                          : 'Playing in your Android video player.\nTorrent keeps downloading in the background.',
                      style: const TextStyle(color: Colors.white70, height: 1.35),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Text(_error!, style: const TextStyle(color: Color(0xFFFF8A80))),
                    ],
                    const SizedBox(height: 18),
                    Text(line, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 8),
                    LinearProgressIndicator(
                      value: (info?.bufferProgress ?? 0) > 0
                          ? info!.bufferProgress.clamp(0.0, 1.0)
                          : null,
                      minHeight: 4,
                      backgroundColor: Colors.white24,
                      color: AppTheme.seed,
                    ),
                    const SizedBox(height: 28),
                    Row(
                      children: [
                        TvFocus(
                          child: FilledButton.icon(
                            focusNode: _reopenFocus,
                            autofocus: isAndroidTv,
                            onPressed: _launching ? null : _launch,
                            icon: const Icon(Icons.play_arrow_rounded),
                            label: Text(_launching ? 'Opening…' : 'Open player again'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        TvFocus(
                          child: OutlinedButton(
                            onPressed: _close,
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.white,
                              side: const BorderSide(color: Colors.white38),
                            ),
                            child: const Text('Stop'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
