import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:media_kit_video/media_kit_video_controls/media_kit_video_controls.dart';
import 'package:video_player/video_player.dart';

import '../content_languages.dart';
import '../graphql/client.dart';
import '../graphql/queries.dart';
import '../local_torrent.dart';
import '../models.dart';
import '../providers/catalog.dart';
import '../providers/settings.dart';
import '../theme.dart';
import '../tv.dart';
import '../friendly_error.dart';
import '../player_cache.dart';
import '../widgets/subtitle_import.dart';
import '../widgets/tv_chrome.dart';
import '../youtube_stream.dart';

class PlayerScreen extends ConsumerStatefulWidget {
  const PlayerScreen({
    super.key,
    required this.fileId,
    required this.playbackUrl,
    required this.title,
    this.youtubeKey,
    this.titleId,
    this.episodeId,
    this.season,
    this.episode,
    this.startMs = 0,
    this.files = const [],
    this.isStream = false,
    this.sessionId,
    this.magnet,
    this.localTorrent = false,
    this.listedSeeders = 0,
    this.listedPeers = 0,
  });

  final String fileId;
  final String playbackUrl;
  final String? youtubeKey;
  final String? titleId;
  final String? episodeId;
  final int? season;
  final int? episode;
  final String title;
  final int startMs;
  final List<FileReference> files;
  final bool isStream;
  final String? sessionId;
  final String? magnet;
  final bool localTorrent;
  final int listedSeeders;
  final int listedPeers;

  @override
  ConsumerState<PlayerScreen> createState() => _PlayerScreenState();
}

class _SubtitleOption {
  const _SubtitleOption({
    required this.id,
    required this.language,
    required this.label,
    required this.content,
  });

  final String id;
  final String language;
  final String label;
  final String content;
}

class _PlayerScreenState extends ConsumerState<PlayerScreen> {
  Player? _player;
  VideoController? _controller;
  VideoPlayerController? _exo;
  late String _url;
  late String _fileId;
  List<_SubtitleOption> _subs = const [];
  String? _activeSubId;
  bool _subsLoading = false;
  List<AudioTrack> _audioTracks = const [];
  String? _activeAudioId;
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<bool>? _completedSub;
  StreamSubscription<Tracks>? _tracksSub;
  StreamSubscription<bool>? _bufferingSub;
  StreamSubscription<Duration>? _bufferSub;
  Timer? _streamPoll;
  DateTime _lastProgress = DateTime.fromMillisecondsSinceEpoch(0);
  bool _progressFlushed = false;
  bool _savedOnce = false;
  bool _closing = false;
  bool _confirmExitOpen = false;
  bool _inFullscreen = false;
  bool _buffering = false;
  bool _streamOpening = false;
  bool _streamOpened = false;
  String? _streamError;
  Duration _buffered = Duration.zero;
  StreamSession? _streamInfo;
  final GlobalKey _videoKey = GlobalKey();
  late final GraphQLClient _client;

  bool get _isTrailer => widget.fileId == 'trailer' || (widget.youtubeKey != null && widget.youtubeKey!.isNotEmpty && widget.fileId == 'trailer');
  /// ExoPlayer / video_player fails on progressive torrent HTTP streams (black
  /// frame while the download HUD keeps moving). Use media_kit (libmpv) everywhere,
  /// including Android TV — same stack as Linux desktop.
  bool get _useExo => false;

  static bool _isUuid(String? value) {
    if (value == null || value.length != 36) return false;
    return RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$').hasMatch(value);
  }

  @override
  void initState() {
    super.initState();
    _client = ref.read(graphQLClientProvider);
    _url = widget.playbackUrl;
    _fileId = widget.fileId;
    if (!_useExo) {
      MediaKit.ensureInitialized();
      _player = Player(
        configuration: PlayerConfiguration(
          bufferSize: widget.isStream ? 24 * 1024 * 1024 : 32 * 1024 * 1024,
          ready: _onPlayerReady,
        ),
      );
      _controller = VideoController(_player!);
      _posSub = _player!.stream.position.listen(_onPosition);
      _bufferingSub = _player!.stream.buffering.listen((value) {
        if (mounted) setState(() => _buffering = value);
      });
      _bufferSub = _player!.stream.buffer.listen((value) {
        if (mounted) setState(() => _buffered = value);
      });
      _tracksSub = _player!.stream.tracks.listen((tracks) {
        final audio = [
          for (final t in tracks.audio)
            if (t.id != 'auto' && t.id != 'no') t,
        ];
        if (!mounted) return;
        setState(() {
          _audioTracks = audio;
          _activeAudioId ??= _player?.state.track.audio.id;
        });
      });
      _completedSub = _player!.stream.completed.listen((done) {
        if (!done) return;
        unawaited(_saveProgress());
        _playNext();
      });
      // Rebuild when video dimensions appear (torrent streams often start with no duration).
      _player!.stream.width.listen((_) {
        if (mounted) setState(() {});
      });
    }
    if (widget.isStream) {
      _streamPoll = Timer.periodic(const Duration(seconds: 1), (_) => unawaited(_pollStream()));
    }
    if (_isTrailer) {
      _buffering = true;
      unawaited(_openTrailer());
    } else if (widget.isStream) {
      unawaited(_prepareStream());
    } else {
      _open(_url, fileId: _fileId);
    }
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    // Register hardware key handler AFTER everything is set up.
    HardwareKeyboard.instance.addHandler(_onHardwareKey);
  }

  /// Low-level hardware key handler — fires before the Focus tree so media_kit
  /// controls cannot swallow D-pad / media keys.
  bool _onHardwareKey(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;
    return _handlePlayerKey(event.logicalKey);
  }

  KeyEventResult _onFocusKey(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    return _handlePlayerKey(event.logicalKey) ? KeyEventResult.handled : KeyEventResult.ignored;
  }

  bool _handlePlayerKey(LogicalKeyboardKey key) {
    if (key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.gameButtonA ||
        key == LogicalKeyboardKey.mediaPlay ||
        key == LogicalKeyboardKey.mediaPause ||
        key == LogicalKeyboardKey.mediaPlayPause ||
        key == LogicalKeyboardKey.space) {
      _playOrPause();
      return true;
    }
    if (key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.mediaFastForward ||
        key == LogicalKeyboardKey.mediaSkipForward) {
      _seekRelative(10);
      return true;
    }
    if (key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.mediaRewind ||
        key == LogicalKeyboardKey.mediaSkipBackward) {
      _seekRelative(-10);
      return true;
    }
    if (key == LogicalKeyboardKey.arrowUp || key == LogicalKeyboardKey.arrowDown) {
      return true;
    }
    if (key == LogicalKeyboardKey.goBack || key == LogicalKeyboardKey.escape || key == LogicalKeyboardKey.browserBack) {
      unawaited(_onBackPressed());
      return true;
    }
    return false;
  }

  /// First back exits fullscreen; second back asks before leaving the player.
  Future<void> _onBackPressed() async {
    if (_closing) return;
    if (_confirmExitOpen) {
      if (mounted && Navigator.of(context).canPop()) {
        Navigator.of(context).pop(false);
      }
      return;
    }
    if (await _tryExitFullscreen()) return;
    await _confirmLeavePlayer();
  }

  Future<bool> _tryExitFullscreen() async {
    if (_useExo) return false;
    final videoCtx = _videoKey.currentContext;
    if (videoCtx != null && videoCtx.mounted) {
      try {
        if (isFullscreen(videoCtx)) {
          await exitFullscreen(videoCtx);
          _inFullscreen = false;
          return true;
        }
      } catch (_) {}
    }
    if (!_inFullscreen || !mounted) return false;
    // Fullscreen uses a separate route + native window size — pop restores both.
    await Navigator.of(context, rootNavigator: true).maybePop();
    try {
      await defaultExitNativeFullscreen();
    } catch (_) {}
    _inFullscreen = false;
    if (mounted) setState(() {});
    return true;
  }

  Future<void> _confirmLeavePlayer() async {
    if (!mounted || _closing || _confirmExitOpen) return;
    _confirmExitOpen = true;
    try {
      final leave = await showDialog<bool>(
        context: context,
        barrierDismissible: true,
        builder: (ctx) {
          return AlertDialog(
            backgroundColor: PtTheme.panel,
            title: const Text('Leave player?'),
            content: const Text('Stop playback and go back to the previous screen?'),
            actions: [
              TvFocus(
                allowHorizontal: false,
                child: TextButton(
                  autofocus: true,
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: const Text('Keep watching'),
                ),
              ),
              TvFocus(
                allowHorizontal: false,
                child: FilledButton(
                  onPressed: () => Navigator.of(ctx).pop(true),
                  child: const Text('Leave'),
                ),
              ),
            ],
          );
        },
      );
      if (leave == true && mounted) await _closePlayer();
    } finally {
      _confirmExitOpen = false;
    }
  }

  /// Called once libmpv is initialised — set codec/sync properties before playback starts.
  void _onPlayerReady() {
    final native = _player?.platform;
    if (native is! NativePlayer) return;
    // Hardware decode: try vaapi (Intel/AMD on Linux), fall back to auto, then software.
    // On Android TV use mediacodec for hardware decode.
    final bool isAndroid = !kIsWeb && Platform.isAndroid;
    native.setProperty('hwdec', isAndroid ? 'mediacodec' : 'vaapi,auto-safe');
    if (isAndroid) {
      // display-resample + interpolation desyncs audio on Android TV.
      native.setProperty('video-sync', 'audio');
      native.setProperty('interpolation', 'no');
      native.setProperty('audio-pitch-correction', 'yes');
    } else {
      native.setProperty('video-sync', 'display-resample');
      native.setProperty('interpolation', 'yes');
      native.setProperty('tscale', 'oversample');
      native.setProperty('audio-pitch-correction', 'no');
    }
    // For streams: don't demux too far ahead so seek is responsive.
    if (widget.isStream) {
      native.setProperty('demuxer-max-bytes', '150MiB');
      native.setProperty('demuxer-readahead-secs', '20');
    }
  }

  void _playOrPause() {
    if (_useExo) {
      final exo = _exo;
      if (exo == null || !exo.value.isInitialized) return;
      exo.value.isPlaying ? exo.pause() : exo.play();
      return;
    }
    _player?.playOrPause();
  }

  void _seekRelative(int seconds) {
    if (_useExo) {
      final exo = _exo;
      if (exo == null || !exo.value.isInitialized) return;
      final pos = exo.value.position;
      final dur = exo.value.duration;
      var target = pos + Duration(seconds: seconds);
      if (target < Duration.zero) target = Duration.zero;
      if (dur > Duration.zero && target > dur) target = dur;
      exo.seekTo(target);
      if (widget.isStream) unawaited(_pollStream());
      return;
    }
    final player = _player;
    if (player == null) return;
    final pos = player.state.position;
    final dur = player.state.duration;
    var target = pos + Duration(seconds: seconds);
    if (target < Duration.zero) target = Duration.zero;
    if (dur > Duration.zero && target > dur) target = dur;
    player.seek(target);
    if (widget.isStream) unawaited(_pollStream());
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onHardwareKey);
    _posSub?.cancel();
    _completedSub?.cancel();
    _tracksSub?.cancel();
    _bufferingSub?.cancel();
    _bufferSub?.cancel();
    _streamPoll?.cancel();
    final position = _useExo ? _exo?.value.position : _player?.state.position;
    final duration = _useExo ? _exo?.value.duration : _player?.state.duration;
    unawaited(_saveProgress(position: position, duration: duration, closing: true));
    _exo?.removeListener(_onExoTick);
    unawaited(_exo?.dispose());
    _player?.dispose();
    final sessionId = widget.sessionId;
    if (widget.isStream && sessionId != null && !widget.localTorrent && !sessionId.startsWith('local-')) {
      _client.mutate(
        MutationOptions(document: gql(STOP_STREAM), variables: {'sessionId': sessionId}),
      );
    }
    if (widget.localTorrent || (widget.isStream && (sessionId?.startsWith('local-') ?? false))) {
      unawaited(LocalTorrentEngine.instance.stop());
    }
    if (!kIsWeb && Platform.isAndroid) {
      unawaited(PlayerCache.clear());
    }
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  Future<void> _closePlayer() async {
    if (_closing) return;
    _closing = true;
    await _saveProgress(closing: true, invalidateHome: true);
    if (mounted) Navigator.of(context).pop();
  }

  void _onPosition(Duration position) {
    if (widget.titleId == null || _isTrailer || _progressFlushed) return;
    final now = DateTime.now();
    final due = !_savedOnce
        ? position.inMilliseconds >= 2000
        : now.difference(_lastProgress) >= const Duration(seconds: 8);
    if (!due) return;
    _savedOnce = true;
    _lastProgress = now;
    unawaited(_saveProgress(position: position));
  }

  Future<void> _saveProgress({
    Duration? position,
    Duration? duration,
    bool closing = false,
    bool invalidateHome = false,
  }) async {
    final titleId = widget.titleId;
    if (titleId == null || _isTrailer) return;
    if (_progressFlushed) return;
    final player = _player;
    final pos = position ??
        (_useExo ? _exo?.value.position : player?.state.position) ??
        Duration.zero;
    final dur = duration ?? (_useExo ? _exo?.value.duration : player?.state.duration);
    if (pos.inMilliseconds < 2000) {
      if (closing) _progressFlushed = true;
      return;
    }
    if (closing) _progressFlushed = true;
    final client = _client;
    final durationMs = (dur != null && dur.inMilliseconds > 0) ? dur.inMilliseconds : null;
    final fileId = widget.isStream || !_isUuid(_fileId) ? null : _fileId;
    final episodeId = _isUuid(widget.episodeId) ? widget.episodeId : null;
    try {
      await client.mutate(
        MutationOptions(
          document: gql(UPDATE_PROGRESS),
          variables: {
            'titleId': titleId,
            'fileId': fileId,
            'episodeId': episodeId,
            'positionMs': pos.inMilliseconds,
            'durationMs': durationMs,
          },
        ),
      );
      final sessionId = widget.sessionId;
      if (widget.isStream && sessionId != null) {
        await client.mutate(
          MutationOptions(
            document: gql(STREAM_RESUME),
            variables: {
              'sessionId': sessionId,
              'position': pos.inMilliseconds,
              'titleId': titleId,
              'title': widget.title,
              'magnet': widget.magnet,
            },
          ),
        );
      }
    } catch (_) {}
    if (invalidateHome && mounted) {
      invalidatePlaybackProgress(ref, titleId: titleId);
    }
  }

  Future<void> _playNext() async {
    if (_isTrailer || widget.isStream || !mounted) return;
    final client = ref.read(graphQLClientProvider);
    final result = await client.query(
      QueryOptions(
        document: gql(NEXT_PLAYBACK),
        variables: {'fileId': _fileId},
        fetchPolicy: FetchPolicy.networkOnly,
      ),
    );
    if (!mounted) return;
    final json = result.data?['nextPlayback'] as Map<String, dynamic>?;
    if (json == null) return;
    final next = FileReference.fromJson(json);
    setState(() {
      _url = next.playbackUrl;
      _fileId = next.id;
    });
    await _open(next.playbackUrl, fileId: next.id);
  }

  Future<void> _openTrailer() async {
    final key = widget.youtubeKey;
    if (key == null || key.isEmpty) return;
    setState(() => _buffering = true);
    try {
      final url = await youtubePlaybackUrl(key);
      if (!mounted) return;
      await _open(url);
    } catch (e) {
      if (!mounted) return;
      setState(() => _buffering = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Couldn’t load that trailer in the player. $e')),
      );
    }
  }

  Future<void> _prepareStream() async {
    if (!widget.isStream || _streamOpening) return;
    _streamOpening = true;
    if (mounted) setState(() => _buffering = true);

    // Device-side torrent: this device fetches pieces. Backend is not involved.
    if (widget.localTorrent) {
      final magnet = widget.magnet;
      if (magnet == null || magnet.isEmpty) {
        if (mounted) {
          setState(() {
            _streamError = 'Stream magnet missing.';
            _buffering = false;
          });
        }
        return;
      }
      if (mounted) {
        setState(() {
          _streamInfo = StreamSession(
            id: widget.sessionId ?? 'local',
            title: widget.title,
            progress: 0,
            bufferProgress: 0,
            downloadMbps: 0,
            seeders: widget.listedSeeders,
            peers: widget.listedPeers,
            resumePosition: widget.startMs,
            status: 'starting',
            streamUrl: '',
          );
        });
      }
      try {
        final handle = await LocalTorrentEngine.instance.start(
          magnet: magnet,
          season: widget.season,
          episode: widget.episode,
          onStats: (local) {
            if (!mounted) return;
            setState(() {
              _streamInfo = StreamSession(
                id: widget.sessionId ?? 'local',
                title: widget.title,
                progress: (local.bufferPct / 100).clamp(0, 1),
                bufferProgress: (local.bufferPct / 100).clamp(0, 1),
                downloadMbps: local.downloadMbps,
                seeders: local.seeders > 0 ? local.seeders : widget.listedSeeders,
                peers: local.peers > 0 ? local.peers : widget.listedPeers,
                resumePosition: widget.startMs,
                status: local.ready ? 'ready' : 'buffering',
                streamUrl: _url,
              );
            });
          },
        );
        if (!mounted) return;
        _url = handle.url;
        await _open(_url, fileId: _fileId);
        if (!mounted) return;
        setState(() {
          _streamOpened = true;
          _streamError = null;
        });
      } catch (e) {
        if (!mounted) return;
        setState(() {
          _streamError = friendlyRequestError(e);
          _buffering = false;
        });
      }
      return;
    }

    final sessionId = widget.sessionId;
    if (sessionId == null) {
      if (mounted) setState(() => _streamError = 'Stream session missing.');
      return;
    }
    if (mounted) {
      setState(() {
        _streamInfo = StreamSession(
          id: sessionId,
          title: widget.title,
          progress: 0,
          bufferProgress: 0,
          downloadMbps: 0,
          seeders: widget.listedSeeders,
          peers: widget.listedPeers,
          resumePosition: widget.startMs,
          status: 'starting',
          streamUrl: widget.playbackUrl,
        );
      });
    }

    final deadline = DateTime.now().add(const Duration(seconds: 150));
    var session = StreamSession(
      id: sessionId,
      title: widget.title,
      progress: 0,
      seeders: 0,
      peers: 0,
      resumePosition: widget.startMs,
      status: 'starting',
      streamUrl: widget.playbackUrl,
    );

    while (!session.isReady && !session.isError && DateTime.now().isBefore(deadline)) {
      await _pollStream();
      if (!mounted) return;
      session = _streamInfo ?? session;
      if (session.isReady && session.streamUrl.isNotEmpty) break;
      await Future<void>.delayed(const Duration(milliseconds: 800));
    }

    if (!mounted) return;
    if (session.isError) {
      setState(() {
        _streamError = friendlyRequestError(session.status);
        _buffering = false;
      });
      return;
    }
    if (!session.isReady || session.streamUrl.isEmpty) {
      setState(() {
        _streamError = 'Couldn’t find enough peers to start this stream. Try another result.';
        _buffering = false;
      });
      return;
    }

    _url = session.streamUrl;
    await _open(_url, fileId: _fileId);
    if (!mounted) return;
    setState(() {
      _streamOpened = true;
      _streamError = null;
    });
  }

  Future<void> _pollStream() async {
    if (!widget.isStream || !mounted) return;

    if (widget.localTorrent || LocalTorrentEngine.instance.isActive) {
      final local = LocalTorrentEngine.instance.currentStats();
      if (local == null || !mounted) return;
      setState(() {
        _streamInfo = StreamSession(
          id: widget.sessionId ?? 'local',
          title: widget.title,
          progress: (local.bufferPct / 100).clamp(0, 1),
          bufferProgress: (local.bufferPct / 100).clamp(0, 1),
          downloadMbps: local.downloadMbps,
          seeders: local.seeders > 0 ? local.seeders : widget.listedSeeders,
          peers: local.peers > 0 ? local.peers : widget.listedPeers,
          resumePosition: widget.startMs,
          status: local.ready ? 'ready' : 'buffering',
          streamUrl: _url,
        );
      });
      return;
    }

    final sessionId = widget.sessionId;
    if (sessionId == null) return;
    try {
      final status = await _client.query(
        QueryOptions(
          document: gql(STREAM_STATUS),
          fetchPolicy: FetchPolicy.networkOnly,
          variables: {'sessionId': sessionId},
        ),
      );
      final json = status.data?['streamStatus'] as Map<String, dynamic>?;
      if (json == null || !mounted) return;
      setState(() => _streamInfo = StreamSession.fromJson(json));
    } catch (_) {}
  }

  bool get _hasVideo {
    if (_useExo) {
      final exo = _exo;
      return exo != null && exo.value.isInitialized && exo.value.size.width > 0;
    }
    final player = _player;
    if (player == null) return false;
    if ((player.state.width ?? 0) > 0 && (player.state.height ?? 0) > 0) return true;
    return player.state.duration.inMilliseconds > 0 || _streamOpened;
  }

  bool get _showStreamHud {
    if (!widget.isStream || _streamError != null) return false;
    if (!_hasVideo) return true;
    return _buffering;
  }

  Future<void> _open(String url, {String? fileId}) async {
    if (fileId != null) _fileId = fileId;
    final local = url.contains('127.0.0.1') || url.contains('localhost') || url.contains('[::1]');
    final token = ref.read(settingsProvider).apiToken;
    final headers = local ? const <String, String>{} : mediaAuthHeaders(token);
    if (_useExo) {
      await _openExo(url, headers);
      _loadSubtitles();
      return;
    }
    await _player?.open(Media(url, httpHeaders: headers));
    if (widget.startMs > 0) {
      try {
        await _player!.stream.duration.firstWhere((d) => d.inMilliseconds > 0).timeout(const Duration(seconds: 20));
      } catch (_) {}
      await _player?.seek(Duration(milliseconds: widget.startMs));
    }
    _loadSubtitles();
  }

  Future<void> _openExo(String url, Map<String, String> headers) async {
    final previous = _exo;
    previous?.removeListener(_onExoTick);
    final next = VideoPlayerController.networkUrl(
      Uri.parse(url),
      httpHeaders: headers,
      videoPlayerOptions: VideoPlayerOptions(mixWithOthers: false),
    );
    next.addListener(_onExoTick);
    _exo = next;
    await previous?.dispose();
    if (mounted) setState(() => _buffering = true);
    await next.initialize();
    if (widget.startMs > 0) {
      await next.seekTo(Duration(milliseconds: widget.startMs));
    }
    await next.play();
    if (mounted) {
      setState(() {
        _buffering = false;
        _streamOpened = true;
      });
    }
  }

  void _onExoTick() {
    final exo = _exo;
    if (exo == null || !mounted) return;
    final v = exo.value;
    final buffered = v.buffered.isEmpty ? Duration.zero : v.buffered.last.end;
    setState(() {
      _buffering = v.isBuffering || !v.isInitialized;
      _buffered = buffered;
    });
    _onPosition(v.position);
    if (v.isCompleted) {
      unawaited(_saveProgress(position: v.position, duration: v.duration));
      _playNext();
    }
  }

  Future<void> _loadSubtitles({String? language, bool applyFirst = true}) async {
    final titleId = widget.titleId;
    if (_fileId == 'trailer' || titleId == null) return;
    final preferred = language ??
        preferredLanguageCodes(ref.read(settingsProvider).preferredLanguages).firstWhere(
          (c) => c.isNotEmpty,
          orElse: () => 'en',
        );
    final fileId = widget.isStream || !_isUuid(_fileId) ? null : _fileId;
    setState(() => _subsLoading = true);
    try {
      final client = ref.read(graphQLClientProvider);
      final result = await client.mutate(
        MutationOptions(
          document: gql(FETCH_SUBTITLES),
          variables: {
            'titleId': titleId,
            'language': preferred,
            'season': widget.season,
            'episode': widget.episode,
            'fileId': fileId,
          },
        ),
      );
      if (!mounted) return;
      if (result.hasException) {
        setState(() => _subsLoading = false);
        if (language != null && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(result.exception.toString().replaceAll('\n', ' '))),
          );
        }
        return;
      }
      final rows = (result.data?['fetchSubtitles'] as List?) ?? const [];
      final next = rows
          .whereType<Map<String, dynamic>>()
          .map(
            (e) => _SubtitleOption(
              id: e['id'] as String? ?? '',
              language: e['language'] as String? ?? preferred,
              label: e['label'] as String? ?? 'Subtitle',
              content: e['content'] as String? ?? '',
            ),
          )
          .where((e) => e.content.contains('-->'))
          .toList();
      setState(() {
        final byId = {for (final sub in _subs) sub.id: sub};
        for (final sub in next) {
          byId[sub.id] = sub;
        }
        _subs = byId.values.toList();
        _subsLoading = false;
      });
      if (applyFirst && next.isNotEmpty && (_activeSubId == null || language != null)) {
        final match = next.where((s) => s.language == preferred);
        await _applySubtitle(match.isNotEmpty ? match.first : next.first);
      }
    } catch (_) {
      if (mounted) setState(() => _subsLoading = false);
    }
  }

  Future<void> _pickSubtitleLanguage(String code) async {
    if (code == 'off') {
      await _disableSubtitles();
      return;
    }
    final existing = _subs.where((s) => s.id == code);
    if (existing.isNotEmpty) {
      await _applySubtitle(existing.first);
      return;
    }
    await _loadSubtitles(language: code);
  }

  Future<void> _addImported(List<ImportedSubtitle> imported) async {
    if (imported.isEmpty) return;
    final next = [
      ..._subs,
      for (final item in imported)
        _SubtitleOption(
          id: item.id,
          language: item.language,
          label: item.label,
          content: item.content,
        ),
    ];
    setState(() => _subs = next);
    await _applySubtitle(next.firstWhere((s) => s.id == imported.first.id));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(imported.length == 1 ? 'Subtitle added' : '${imported.length} subtitles added')),
    );
  }

  Future<void> _addSubtitleFromFile() async {
    try {
      final imported = await pickSubtitlesFromStorage();
      await _addImported(imported);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _addSubtitleFromUrl() async {
    final url = await promptSubtitleUrl(context);
    if (url == null || url.isEmpty || !mounted) return;
    setState(() => _subsLoading = true);
    try {
      final imported = await downloadSubtitlesFromUrl(url);
      await _addImported(imported);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _subsLoading = false);
    }
  }

  Future<void> _applySubtitle(_SubtitleOption sub) async {
    await _player?.setSubtitleTrack(
      SubtitleTrack.data(sub.content, title: sub.label, language: sub.language),
    );
    if (mounted) setState(() => _activeSubId = sub.id);
  }

  Future<void> _disableSubtitles() async {
    await _player?.setSubtitleTrack(SubtitleTrack.no());
    if (mounted) setState(() => _activeSubId = null);
  }

  String _audioLabel(AudioTrack track) {
    final lang = track.language?.trim();
    final title = track.title?.trim();
    if (lang != null && lang.isNotEmpty) {
      final name = languageDisplayName(lang);
      if (title != null && title.isNotEmpty && title.toLowerCase() != lang.toLowerCase()) {
        return '$name · $title';
      }
      return name;
    }
    if (title != null && title.isNotEmpty) return title;
    return 'Track ${track.id}';
  }

  Widget _bufferOverlay() {
    final info = _streamInfo;
    final local = LocalTorrentEngine.instance.currentStats();
    final pct = ((info?.bufferProgress ?? 0) * 100).clamp(0, 100);
    final speed = info?.downloadMbps ?? local?.downloadMbps ?? 0;
    var seeders = info?.seeders ?? local?.seeders ?? widget.listedSeeders;
    var peers = info?.peers ?? local?.peers ?? widget.listedPeers;
    if (seeders <= 0) seeders = widget.listedSeeders;
    if (peers <= 0) peers = widget.listedPeers;
    final line = _streamStatsLine(pct: pct, speed: speed, seeders: seeders, peers: peers);

    return Stack(children: [
      Positioned(
        right: 16,
        bottom: 72,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.68),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: IntrinsicWidth(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    line,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  LinearProgressIndicator(
                    value: (info?.bufferProgress ?? 0) > 0 ? info!.bufferProgress.clamp(0.0, 1.0) : null,
                    minHeight: 3,
                    backgroundColor: Colors.white24,
                    color: AppTheme.seed,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ]);
  }

  String _streamStatsLine({
    required num pct,
    required double speed,
    required int seeders,
    required int peers,
  }) {
    final speedStr = speed > 0 ? '${speed.toStringAsFixed(1)} MB/s' : 'finding peers…';
    final swarm = seeders > 0
        ? '  ·  $seeders seeds'
        : (peers > 0 ? '  ·  $peers peers' : '');
    return '${pct.round()}%  ·  $speedStr$swarm';
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        await _onBackPressed();
      },
      child: Focus(
        autofocus: true,
        descendantsAreFocusable: !isAndroidTv,
        onKeyEvent: _onFocusKey,
        child: Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Center(child: _videoSurface()),
          if (widget.isStream && _showStreamHud) Positioned.fill(child: _bufferOverlay()),
          if (_streamError != null)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  _streamError!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70, fontSize: 15),
                ),
              ),
            ),
          Positioned(
            top: 12,
            left: 8,
            child: IconButton(
              onPressed: _onBackPressed,
              icon: const Icon(Icons.arrow_back, color: Colors.white),
            ),
          ),
          Positioned(
            top: 12,
            right: 12,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!_isTrailer) ...[
                  if (_subsLoading)
                    const Padding(
                      padding: EdgeInsets.only(right: 8),
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white70),
                      ),
                    ),
                  PopupMenuButton<String>(
                    color: PtTheme.panel,
                    tooltip: 'Audio language',
                    icon: const Icon(Icons.language, color: Colors.white),
                    onSelected: (id) {
                      final match = _audioTracks.where((t) => t.id == id);
                      if (match.isEmpty) return;
                      _player?.setAudioTrack(match.first);
                      setState(() => _activeAudioId = id);
                    },
                    itemBuilder: (context) {
                      if (_audioTracks.isEmpty) {
                        return const [
                          PopupMenuItem<String>(
                            enabled: false,
                            value: 'none',
                            child: Text('Audio tracks appear after playback starts'),
                          ),
                        ];
                      }
                      return [
                        for (final track in _audioTracks)
                          CheckedPopupMenuItem<String>(
                            value: track.id,
                            checked: _activeAudioId == track.id,
                            child: Text(_audioLabel(track)),
                          ),
                      ];
                    },
                  ),
                  PopupMenuButton<String>(
                    color: PtTheme.panel,
                    tooltip: 'Subtitles',
                    icon: Icon(
                      _activeSubId == null ? Icons.closed_caption_off : Icons.closed_caption,
                      color: Colors.white,
                    ),
                    onSelected: (value) {
                      if (value == 'settings') {
                        context.push('/settings');
                        return;
                      }
                      if (value == 'add_file') {
                        unawaited(_addSubtitleFromFile());
                        return;
                      }
                      if (value == 'add_url') {
                        unawaited(_addSubtitleFromUrl());
                        return;
                      }
                      if (value.startsWith('download:')) {
                        unawaited(_pickSubtitleLanguage(value.substring('download:'.length)));
                        return;
                      }
                      unawaited(_pickSubtitleLanguage(value));
                    },
                    itemBuilder: (context) {
                      final osReady =
                          ref.read(serverInfoProvider).valueOrNull?.opensubtitlesConfigured ?? false;
                      return [
                        CheckedPopupMenuItem(
                          value: 'off',
                          checked: _activeSubId == null,
                          child: const Text('Off'),
                        ),
                        for (final sub in _subs)
                          CheckedPopupMenuItem(
                            value: sub.id,
                            checked: _activeSubId == sub.id,
                            child: Text(sub.label),
                          ),
                        const PopupMenuDivider(),
                        const PopupMenuItem(
                          value: 'add_file',
                          child: Text('From storage…'),
                        ),
                        const PopupMenuItem(
                          value: 'add_url',
                          child: Text('From link…'),
                        ),
                        if (osReady) ...[
                          const PopupMenuDivider(),
                          for (final lang in kContentLanguages)
                            PopupMenuItem(
                              value: 'download:${lang.code}',
                              child: Text('Download ${lang.label}'),
                            ),
                        ] else
                          const PopupMenuItem(
                            value: 'settings',
                            child: Text('Add OpenSubtitles API key'),
                          ),
                      ];
                    },
                  ),
                ],
                if (widget.files.length > 1)
                  PopupMenuButton<FileReference>(
                    color: PtTheme.panel,
                    icon: const Icon(Icons.high_quality_outlined, color: Colors.white),
                    onSelected: (f) {
                      setState(() => _url = f.playbackUrl);
                      _open(f.playbackUrl, fileId: f.id);
                    },
                    itemBuilder: (context) => [
                      for (final f in widget.files)
                        PopupMenuItem(value: f, child: Text(f.quality ?? f.container ?? 'file')),
                    ],
                  ),
              ],
            ),
          ),
        ],
      ),
        ),
      ),
    );
  }

  Widget _videoSurface() {
    if (_useExo) {
      final exo = _exo;
      if (exo == null || !exo.value.isInitialized) return const SizedBox.shrink();
      final video = FittedBox(
        fit: BoxFit.contain,
        child: SizedBox(
          width: exo.value.size.width,
          height: exo.value.size.height,
          child: VideoPlayer(exo),
        ),
      );
      return isAndroidTv ? IgnorePointer(child: video) : video;
    }
    final controller = _controller;
    if (controller == null) return const SizedBox.shrink();
    final video = Video(
      key: _videoKey,
      controller: controller,
      controls: AdaptiveVideoControls,
      wakelock: true,
      onEnterFullscreen: () async {
        _inFullscreen = true;
        await defaultEnterNativeFullscreen();
      },
      onExitFullscreen: () async {
        _inFullscreen = false;
        await defaultExitNativeFullscreen();
      },
    );
    return isAndroidTv ? IgnorePointer(child: video) : video;
  }
}
