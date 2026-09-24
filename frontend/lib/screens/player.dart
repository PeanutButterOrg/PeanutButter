import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_libs_android_video/media_kit_libs_android_video.dart';
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
import '../widgets/cached_art.dart';
import '../widgets/streaming_picker.dart';
import '../widgets/subtitle_import.dart';
import '../widgets/tv_chrome.dart';
import '../youtube_stream.dart';

class _NextEpisodeTarget {
  const _NextEpisodeTarget({
    required this.season,
    required this.episode,
    required this.episodeId,
    required this.label,
    required this.catalogTitle,
    required this.kind,
    this.isNextSeason = false,
  });

  final int season;
  final int episode;
  final String episodeId;
  final String label;
  final String catalogTitle;
  final String kind;
  final bool isNextSeason;
}

class PlayerScreen extends ConsumerStatefulWidget {
  const PlayerScreen({
    super.key,
    required this.fileId,
    required this.playbackUrl,
    required this.title,
    this.youtubeKey,
    this.trailerPreferredQuality,
    this.trailerInitialHeight,
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
    this.streamFileIndex,
    this.listedSeeders = 0,
    this.listedPeers = 0,
    this.catalogTitle,
    this.kind,
    this.posterUrl,
    this.backdropUrl,
  });

  final String fileId;
  final String playbackUrl;
  final String? youtubeKey;
  final String? trailerPreferredQuality;
  final int? trailerInitialHeight;
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
  /// Explicit file inside a multi-file torrent / season pack.
  final int? streamFileIndex;
  final int listedSeeders;
  final int listedPeers;
  /// Clean series/movie name for Jackett / play-next (not the SxxExx label).
  final String? catalogTitle;
  final String? kind;
  final String? posterUrl;
  final String? backdropUrl;

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
  Timer? _pauseBufferTimer;
  bool _pauseBufferBoosted = false;
  bool _seeking = false;
  int _seekToken = 0;
  Duration _lastGoodPos = Duration.zero;
  Duration _lastSeekTarget = Duration.zero;
  DateTime? _seekIgnoreUntil;
  DateTime? _lastFalseEofAt;
  int _falseEofCount = 0;
  _NextEpisodeTarget? _nextEpisode;
  bool _playNextVisible = false;
  bool _playNextDismissed = false;
  bool _playNextBusy = false;
  int _playNextSecondsLeft = 30;
  DateTime? _playNextArmedAt;
  Timer? _playNextTick;
  static const int _playNextAutoHideSecs = 30;
  /// Desktop/mouse chrome: seek ±10s + audio/subs (auto-hide).
  bool _chromeVisible = true;
  Timer? _chromeHideTimer;
  static const int _chromeHideSecs = 15;
  static const Duration _chromeAnim = Duration(milliseconds: 280);
  bool _episodeMarkedComplete = false;
  DateTime _lastProgress = DateTime.fromMillisecondsSinceEpoch(0);
  bool _progressFlushed = false;
  bool _savedOnce = false;
  bool _closing = false;
  bool _allowLeave = false;
  bool _confirmExitOpen = false;
  DateTime? _confirmOpenedAt;
  DateTime? _lastBackHandledAt;
  bool _inFullscreen = false;
  /// Bumps fullscreen Skip / Play Next overlays (native fullscreen route).
  final ValueNotifier<int> _overlayEpoch = ValueNotifier(0);
  bool _buffering = false;
  bool _playing = false;
  bool _streamOpening = false;
  bool _streamOpened = false;
  String? _streamError;
  Duration _buffered = Duration.zero;
  StreamSession? _streamInfo;
  Duration? _lastTrackedPos;
  DateTime _lastStreamRetarget = DateTime.fromMillisecondsSinceEpoch(0);
  List<YoutubeQualityOption> _trailerQualities = const [];
  int? _trailerHeight;
  final GlobalKey _videoKey = GlobalKey();
  late final GraphQLClient _client;

  /// TheIntroDB skip segments (intro / recap / credits / preview).
  List<MediaSegment> _segments = const [];
  MediaSegment? _activeSegment;
  int _durationMs = 0;
  int _lastSegmentFetchDuration = -1;
  bool _segmentsLoading = false;
  bool _segmentsFetched = false;
  int? _pendingSegmentDurationMs;

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
    // Prefer the non-Riverpod flag — writing StateProviders from initState
    // races go_router rebuilds on Android TV (red "UI error" screen).
    playbackSessionActive = true;
    _client = ref.read(graphQLClientProvider);
    _url = widget.playbackUrl;
    _fileId = widget.fileId;
    if (!_useExo) {
      // Android: paint chrome first, await background libmpv load, then create
      // Player. Sync System.loadLibrary / DynamicLibrary.open ANRs TV emulators.
      // Linux/desktop keep sync init so buffering stays responsive.
      if (!kIsWeb && Platform.isAndroid) {
        // First paint player chrome / poster; delay native Player() until after
        // the stream-picker route has popped (otherwise UI sticks on Starting…).
        WidgetsBinding.instance.addPostFrameCallback((_) {
          unawaited(() async {
            // Long delay: Player() FFI still blocks the UI isolate for seconds on
            // the x86 TV emulator even after libmpv is loaded. Wait until the
            // select KeyEvent is fully done and chrome has painted.
            await Future<void>.delayed(const Duration(milliseconds: 1200));
            if (!mounted) return;
            await _initMediaKitPlayerAndroid();
          }());
        });
      } else {
        _initMediaKitPlayer();
        _kickOffPlayback();
      }
    } else {
      _kickOffPlayback();
    }
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    // Register hardware key handler AFTER everything is set up.
    HardwareKeyboard.instance.addHandler(_onHardwareKey);
    // Desktop: show controls briefly, then auto-hide.
    if (!isAndroidTv) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _bumpChrome());
    }
  }

  Future<void> _initMediaKitPlayerAndroid() async {
    if (!mounted || _player != null) return;
    setState(() => _buffering = true);
    await MediaKitAndroidVideo.preload();
    if (!mounted) return;
    // Yield so input/vsync can run between native steps.
    await Future<void>.delayed(Duration.zero);
    if (!mounted) return;
    try {
      MediaKit.ensureInitialized();
    } catch (e, st) {
      debugPrint('PeanutButter MediaKit.ensureInitialized failed: $e\n$st');
    }
    await Future<void>.delayed(Duration.zero);
    if (!mounted) return;
    _initMediaKitPlayer();
    if (mounted) setState(() {});
    _kickOffPlayback();
  }

  void _initMediaKitPlayer() {
    if (_player != null) return;
    try {
      if (kIsWeb || !Platform.isAndroid) {
        MediaKit.ensureInitialized();
      }
      // Tiny demuxer RAM on Android — large sync alloc freezes TV emulators.
      final bufferBytes = (!kIsWeb && Platform.isAndroid)
          ? 4 * 1024 * 1024
          : (widget.isStream ? 64 * 1024 * 1024 : 48 * 1024 * 1024);
      _player = Player(
        configuration: PlayerConfiguration(
          bufferSize: bufferBytes,
          ready: _onPlayerReady,
        ),
      );
      _controller = VideoController(_player!);
      _posSub = _player!.stream.position.listen(_onPosition);
      _bufferingSub = _player!.stream.buffering.listen((value) {
        if (!mounted) return;
        setState(() => _buffering = value);
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
        unawaited(_applyPreferredAudioLanguage(audio));
      });
      _completedSub = _player!.stream.completed.listen((done) {
        if (!done || _seeking) return;
        unawaited(_onPlaybackCompleted());
      });
      // While paused, keep demux/torrent prefetch warm for a smooth resume.
      _player!.stream.playing.listen((playing) {
        if (!mounted) return;
        setState(() => _playing = playing);
        if (!playing) {
          _onPausedKeepBuffering();
        }
      });
      // Rebuild when video dimensions appear (torrent streams often start with no duration).
      _player!.stream.width.listen((_) {
        if (mounted) setState(() {});
      });
      _player!.stream.duration.listen((d) {
        if (d.inMilliseconds <= 0) return;
        if (!_segmentsFetched ||
            (_lastSegmentFetchDuration >= 0 &&
                (d.inMilliseconds - _lastSegmentFetchDuration).abs() > 5000)) {
          unawaited(_loadMediaSegments(durationMs: d.inMilliseconds));
        }
      });
    } catch (e, st) {
      debugPrint('PeanutButter player init failed: $e\n$st');
      _streamError = 'Couldn’t start the video player on this device.\n$e';
    }
  }

  void _kickOffPlayback() {
    if (widget.isStream && _streamPoll == null) {
      _streamPoll = Timer.periodic(const Duration(seconds: 1), (_) => unawaited(_pollStream()));
    }
    if (_player != null || _useExo) {
      if (_isTrailer) {
        _buffering = true;
        unawaited(_openTrailer());
      } else if (widget.isStream) {
        unawaited(_prepareStream());
      } else {
        unawaited(_open(_url, fileId: _fileId));
      }
      if (!_isTrailer) {
        unawaited(_loadMediaSegments());
        if (widget.titleId != null) {
          unawaited(_resolveNextEpisode());
        }
      }
    }
  }

  /// Low-level hardware key handler — fires before the Focus tree so media_kit
  /// controls cannot swallow D-pad / media keys.
  bool _onHardwareKey(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;
    // While the leave-confirm dialog is up, don't steal Select/OK from its buttons.
    if (_confirmExitOpen) {
      if (event.logicalKey == LogicalKeyboardKey.goBack ||
          event.logicalKey == LogicalKeyboardKey.escape ||
          event.logicalKey == LogicalKeyboardKey.browserBack) {
        unawaited(_onBackPressed());
        return true;
      }
      return false;
    }
    return _handlePlayerKey(event.logicalKey);
  }

  KeyEventResult _onFocusKey(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    return _handlePlayerKey(event.logicalKey) ? KeyEventResult.handled : KeyEventResult.ignored;
  }

  bool _handlePlayerKey(LogicalKeyboardKey key) {
    _bumpChrome();
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
      if (_canSeek) _seekRelative(10);
      return true;
    }
    if (key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.mediaRewind ||
        key == LogicalKeyboardKey.mediaSkipBackward) {
      if (_canSeek) _seekRelative(-10);
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

  /// First back exits fullscreen; next back opens leave confirm.
  /// While the dialog is open, Back never leaves — only the Leave button does.
  Future<void> _onBackPressed() async {
    if (_closing) return;

    final now = DateTime.now();
    if (_confirmExitOpen) {
      final opened = _confirmOpenedAt;
      // Swallow the duplicate Back that opened this dialog.
      if (opened != null && now.difference(opened) < const Duration(milliseconds: 700)) {
        return;
      }
      // Back while the dialog is open = stay in the player (same as Keep watching).
      if (mounted) {
        final nav = Navigator.of(context, rootNavigator: true);
        if (nav.canPop()) nav.pop(false);
      }
      return;
    }

    if (_lastBackHandledAt != null &&
        now.difference(_lastBackHandledAt!) < const Duration(milliseconds: 450)) {
      return;
    }
    _lastBackHandledAt = now;

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
    _confirmOpenedAt = DateTime.now();
    try {
      final leave = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        useRootNavigator: true,
        builder: (ctx) {
          return PopScope(
            // Keep dialog open on Back — only Leave button exits playback.
            canPop: false,
            onPopInvokedWithResult: (didPop, _) {
              if (didPop) return;
              final opened = _confirmOpenedAt;
              if (opened != null &&
                  DateTime.now().difference(opened) < const Duration(milliseconds: 700)) {
                return;
              }
              // Back = Keep watching (never Leave).
              Navigator.of(ctx).pop(false);
            },
            child: AlertDialog(
              backgroundColor: PtTheme.panel,
              title: const Text('Leave player?'),
              content: const Text('Stop playback and go back to the previous screen?'),
              actions: [
                TvFocus(
                  allowHorizontal: true,
                  child: TextButton(
                    autofocus: true,
                    onPressed: () => Navigator.of(ctx).pop(false),
                    child: const Text('Keep watching'),
                  ),
                ),
                TvFocus(
                  allowHorizontal: true,
                  child: FilledButton(
                    onPressed: () => Navigator.of(ctx).pop(true),
                    child: const Text('Leave'),
                  ),
                ),
              ],
            ),
          );
        },
      );
      if (leave == true && mounted) await _closePlayer();
    } finally {
      _confirmExitOpen = false;
      _confirmOpenedAt = null;
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
    // Keep prefetching while paused so resume is smooth (mpv still demuxes into cache).
    native.setProperty('cache', 'yes');
    native.setProperty('demuxer-thread', 'yes');
    native.setProperty('demuxer-max-bytes', widget.isStream ? '512MiB' : '256MiB');
    native.setProperty('demuxer-max-back-bytes', '64MiB');
    // Large readahead: while paused the demuxer fills toward this window.
    native.setProperty('demuxer-readahead-secs', widget.isStream ? '300' : '120');
    native.setProperty('cache-secs', widget.isStream ? '300' : '120');
    // Don't auto-pause on underrun for torrents — that looked like random
    // pause/resume and fought with our old stall-recovery loop.
    native.setProperty('cache-pause', widget.isStream ? 'no' : 'yes');
    if (!widget.isStream) {
      native.setProperty('cache-pause-wait', '3');
    }
    // Make scrubbing / ±10s seeks work while paused.
    native.setProperty('hr-seek', 'yes');
    native.setProperty('force-seekable', 'yes');
    // Progressive HTTP/torrent streams hit EOF when the next piece isn't ready.
    // Keep the file open so we can resume instead of restarting at 0.
    // Do NOT pause at EOF — that left torrents stuck on "connected" with a
    // black frame after a premature underrun before pieces arrived.
    if (widget.isStream) {
      native.setProperty('keep-open', 'yes');
      native.setProperty('keep-open-pause', 'no');
      native.setProperty('stream-lavf-o', 'reconnect_streamed=1,reconnect_delay_max=5');
    }
  }

  /// False EOF on progressive torrents used to call bare [play], which restarts
  /// at t=0 in a loop and also prevents Skip Intro from ever appearing.
  Future<void> _onPlaybackCompleted() async {
    final player = _player;
    if (player == null || _seeking) return;
    final pos = player.state.position;
    final dur = player.state.duration;
    final last = _lastGoodPos;
    // Don't trust "end of file" until we have a real runtime — progressive
    // torrents often report a tiny duration while still downloading.
    final reliableDuration = dur >= const Duration(minutes: 2);
    final nearEnd = reliableDuration &&
        pos >= dur * 0.92 &&
        last >= dur * 0.85;
    final progressed = last.inMilliseconds > 2000 || pos.inMilliseconds > 2000;

    if (widget.isStream && !nearEnd) {
      final now = DateTime.now();
      if (_lastFalseEofAt != null &&
          now.difference(_lastFalseEofAt!) < const Duration(seconds: 3)) {
        return;
      }
      _lastFalseEofAt = now;
      _falseEofCount += 1;
      // Give up after repeated false EOFs near the start — don't thrash.
      if (_falseEofCount > 8 && !progressed) {
        return;
      }
      final recoverMs = last.inMilliseconds > pos.inMilliseconds
          ? last.inMilliseconds
          : pos.inMilliseconds;
      try {
        if (recoverMs > 500) {
          final target = Duration(milliseconds: recoverMs);
          _seekIgnoreUntil = DateTime.now().add(const Duration(milliseconds: 2500));
          _lastGoodPos = target;
          await player.seek(target);
        }
        await player.play();
      } catch (_) {}
      return;
    }

    unawaited(_saveProgress(complete: true));
    // Streams with a next episode: show Play Next for 30s, then exit if unused.
    if (widget.isStream && _nextEpisode != null && !_playNextDismissed) {
      _armPlayNextPrompt(force: true);
      return;
    }
    // Movie / last episode / no next: leave and tear down the torrent/stream.
    unawaited(_endPlaybackAndExit());
  }

  void _playOrPause() {
    if (_useExo) {
      final exo = _exo;
      if (exo == null || !exo.value.isInitialized) return;
      if (exo.value.isPlaying) {
        exo.pause();
        _onPausedKeepBuffering();
      } else {
        exo.play();
      }
      return;
    }
    final player = _player;
    if (player == null) return;
    if (player.state.playing) {
      unawaited(player.playOrPause().then((_) => _onPausedKeepBuffering()));
      return;
    }
    unawaited(player.play());
  }

  /// Keep filling the demuxer / torrent cache while the UI is paused.
  void _onPausedKeepBuffering() {
    final native = _player?.platform;
    if (!_pauseBufferBoosted && native is NativePlayer) {
      _pauseBufferBoosted = true;
      // Expand forward window once; mpv continues demuxing while paused.
      unawaited(native.setProperty('demuxer-readahead-secs', widget.isStream ? '600' : '180'));
      unawaited(native.setProperty('cache-secs', widget.isStream ? '600' : '180'));
    }
    if (widget.localTorrent || (widget.isStream && (widget.sessionId?.startsWith('local-') ?? false))) {
      LocalTorrentEngine.instance.keepDownloading();
    }
    _pauseBufferTimer?.cancel();
    _pauseBufferTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (!mounted) return;
      if (_player?.state.playing == true) {
        _pauseBufferTimer?.cancel();
        _pauseBufferTimer = null;
        _pauseBufferBoosted = false;
        return;
      }
      if (widget.localTorrent || LocalTorrentEngine.instance.isActive) {
        LocalTorrentEngine.instance.keepDownloading();
      }
    });
  }

  /// Seek for movies/series once media is ready — allowed while paused or buffering.
  bool get _canSeek {
    if (_isTrailer) return false;
    if (!_hasVideo && _player == null && _exo == null) return false;
    if (_useExo) {
      final exo = _exo;
      return exo != null && exo.value.isInitialized;
    }
    return _player != null;
  }

  bool get _showSeekControls => !_isTrailer && (_hasVideo || _player != null || _exo != null);

  void _seekRelative(int seconds) {
    unawaited(_seekRelativeAsync(seconds));
  }

  Future<void> _seekRelativeAsync(int seconds) async {
    if (!_canSeek) return;
    Duration pos;
    Duration dur;
    if (_useExo) {
      final exo = _exo;
      if (exo == null || !exo.value.isInitialized) return;
      pos = exo.value.position;
      dur = exo.value.duration;
    } else {
      final player = _player;
      if (player == null) return;
      pos = player.state.position.inMilliseconds > 0 ? player.state.position : _lastGoodPos;
      dur = player.state.duration;
    }
    var target = pos + Duration(seconds: seconds);
    if (target < Duration.zero) target = Duration.zero;
    if (dur > Duration.zero && target > dur) target = dur;
    await _seekPlayback(target);
  }

  /// Seek once: retarget local torrent window, seek player, play.
  /// Remote streams retarget via HTTP Range from the player itself.
  Future<void> _seekPlayback(Duration target) async {
    if (target < Duration.zero) target = Duration.zero;
    final token = ++_seekToken;
    _lastSeekTarget = target;
    _lastGoodPos = target;
    _seekIgnoreUntil = DateTime.now().add(const Duration(milliseconds: 2000));
    if (mounted) {
      setState(() {
        _buffering = true;
        _seeking = true;
      });
    }

    // Local torrents need an explicit piece-window move. Remote HTTP Range
    // seeks are handled by the backend when the player issues a new Range.
    await _retargetStreamBuffer(target);
    if (token != _seekToken) return;

    if (_useExo) {
      final exo = _exo;
      if (exo == null || !exo.value.isInitialized) return;
      try {
        await exo.seekTo(target);
        if (token != _seekToken) return;
        await exo.play();
      } catch (_) {}
    } else {
      final player = _player;
      if (player == null) return;
      try {
        await player.seek(target);
        if (token != _seekToken) return;
        await player.play();
      } catch (_) {}
    }

    // Don't leave the spinner stuck if position callbacks are noisy.
    Future<void>.delayed(const Duration(milliseconds: 2000), () {
      if (!mounted || token != _seekToken) return;
      if (_seeking) setState(() => _seeking = false);
    });
    if (widget.isStream) unawaited(_pollStream());
    if (mounted) setState(() {});
  }

  /// Move local torrent download window to [target]. Remote sessions rely on
  /// HTTP Range (serve_stream) — do not poke streamResume on every seek.
  Future<void> _retargetStreamBuffer(Duration target) async {
    if (!widget.isStream) return;
    final now = DateTime.now();
    if (now.difference(_lastStreamRetarget) < const Duration(milliseconds: 200)) {
      return;
    }
    _lastStreamRetarget = now;

    if (widget.localTorrent ||
        (widget.sessionId?.startsWith('local-') ?? false) ||
        LocalTorrentEngine.instance.isActive) {
      LocalTorrentEngine.instance.seekTo(positionMs: target.inMilliseconds);
    }
  }

  @override
  void deactivate() {
    playbackSessionActive = false;
    super.deactivate();
  }

  @override
  void dispose() {
    playbackSessionActive = false;
    HardwareKeyboard.instance.removeHandler(_onHardwareKey);
    _posSub?.cancel();
    _completedSub?.cancel();
    _tracksSub?.cancel();
    _bufferingSub?.cancel();
    _bufferSub?.cancel();
    _streamPoll?.cancel();
    _playNextTick?.cancel();
    _pauseBufferTimer?.cancel();
    _chromeHideTimer?.cancel();
    _overlayEpoch.dispose();
    final position = _useExo ? _exo?.value.position : _player?.state.position;
    final duration = _useExo ? _exo?.value.duration : _player?.state.duration;
    unawaited(_saveProgress(position: position, duration: duration, closing: true));
    _exo?.removeListener(_onExoTick);
    unawaited(_exo?.dispose());
    _player?.dispose();
    final sessionId = widget.sessionId;
    // Prefer the explicit stop in _closePlayer; keep dispose as a safety net.
    if (!_closing) {
      if (widget.isStream && sessionId != null && !widget.localTorrent && !sessionId.startsWith('local-')) {
        _client.mutate(
          MutationOptions(document: gql(STOP_STREAM), variables: {'sessionId': sessionId}),
        );
      }
      if (widget.localTorrent || (widget.isStream && (sessionId?.startsWith('local-') ?? false))) {
        unawaited(LocalTorrentEngine.instance.stop());
      }
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
    _playNextTick?.cancel();
    _pauseBufferTimer?.cancel();
    try {
      await _player?.pause();
    } catch (_) {}
    try {
      await _exo?.pause();
    } catch (_) {}
    // Stop torrent / remote stream before leaving so downloads & uploads die.
    await _stopStreamingSession();
    try {
      await _saveProgress(closing: true, invalidateHome: true)
          .timeout(const Duration(seconds: 2), onTimeout: () {});
    } catch (_) {}
    if (!mounted) return;
    // PopScope keeps canPop=false while playing, so context.canPop() stays false
    // unless we flip this flag — otherwise Leave appears to do nothing.
    setState(() => _allowLeave = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (context.canPop()) {
        context.pop();
        return;
      }
      final nav = Navigator.of(context);
      if (nav.canPop()) {
        nav.pop();
        return;
      }
      Navigator.of(context, rootNavigator: true).maybePop();
    });
  }

  /// End playback: hide prompts, stop torrent/stream, leave the player.
  Future<void> _endPlaybackAndExit() async {
    if (_closing) return;
    _playNextTick?.cancel();
    if (mounted) {
      setState(() {
        _playNextVisible = false;
        _playNextDismissed = true;
      });
      _notifyOverlays();
    }
    await _closePlayer();
  }

  /// Stop remote Jackett stream session and/or local libtorrent download/upload.
  Future<void> _stopStreamingSession() async {
    final sessionId = widget.sessionId;
    if (widget.isStream &&
        sessionId != null &&
        !widget.localTorrent &&
        !sessionId.startsWith('local-')) {
      try {
        await _client
            .mutate(
              MutationOptions(
                document: gql(STOP_STREAM),
                variables: {'sessionId': sessionId},
              ),
            )
            .timeout(const Duration(seconds: 3));
      } catch (_) {}
    }
    if (widget.localTorrent ||
        (widget.isStream && (sessionId?.startsWith('local-') ?? false)) ||
        LocalTorrentEngine.instance.isActive) {
      try {
        await LocalTorrentEngine.instance.stop();
      } catch (_) {}
    }
  }

  void _onPosition(Duration position) {
    final prev = _lastTrackedPos;
    _lastTrackedPos = position;
    final ignoring = _seekIgnoreUntil != null &&
        DateTime.now().isBefore(_seekIgnoreUntil!);

    // Ignore transient resets to ~0 after a seek (common with progressive HTTP).
    final bogusReset = position.inMilliseconds < 1500 &&
        _lastGoodPos.inMilliseconds > 5000 &&
        (ignoring || _seeking);

    if (!bogusReset && position.inMilliseconds > 0) {
      if (!ignoring) {
        _lastGoodPos = position;
      }
      if (position.inMilliseconds > 5000) {
        _falseEofCount = 0;
      }
      if (_seeking &&
          (_lastSeekTarget - position).abs() < const Duration(seconds: 2)) {
        _seeking = false;
      }
    }

    // Scrubber / native seeks: retarget local download window only.
    // Never auto-play or force another seek — that caused restart loops.
    if (!ignoring &&
        !bogusReset &&
        widget.isStream &&
        prev != null &&
        !_seeking &&
        (position - prev).abs() > const Duration(seconds: 4) &&
        position.inMilliseconds >= 1500) {
      unawaited(_retargetStreamBuffer(position));
      _lastGoodPos = position;
    }

    // Don't clear Skip Intro when the demuxer briefly reports t=0.
    final segmentPos =
        bogusReset ? _lastGoodPos.inMilliseconds : position.inMilliseconds;
    _updateActiveSegment(segmentPos);
    _updatePlayNextPrompt(bogusReset ? _lastGoodPos : position);
    if (ignoring || bogusReset) return;
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

  void _updateActiveSegment(int positionMs) {
    if (_isTrailer || _segments.isEmpty) {
      if (_activeSegment != null && mounted) {
        setState(() => _activeSegment = null);
        _notifyOverlays();
      }
      return;
    }
    final duration = _playbackDurationMs();
    if (duration > 0 && duration != _durationMs) {
      _durationMs = duration;
      // Re-query once we know a real runtime so TheIntroDB can match the cut.
      if (!_segmentsLoading &&
          (_lastSegmentFetchDuration < 0 ||
              (duration - _lastSegmentFetchDuration).abs() > 5000)) {
        unawaited(_loadMediaSegments(durationMs: duration));
      }
    }
    MediaSegment? hit;
    // Only opening skips (intro / recap). Credits are handled by Play Next.
    const order = ['INTRO', 'RECAP'];
    for (final kind in order) {
      for (final s in _segments) {
        if (s.kind != kind) continue;
        if (s.contains(positionMs, durationMs: duration > 0 ? duration : _durationMs)) {
          hit = s;
          break;
        }
      }
      if (hit != null) break;
    }
    if (hit?.kind != _activeSegment?.kind ||
        hit?.startMs != _activeSegment?.startMs ||
        hit?.endMs != _activeSegment?.endMs) {
      if (mounted) {
        setState(() => _activeSegment = hit);
        _notifyOverlays();
      }
    }
  }

  int _playbackDurationMs() {
    if (_useExo) {
      return _exo?.value.duration.inMilliseconds ?? 0;
    }
    return _player?.state.duration.inMilliseconds ?? 0;
  }

  Future<void> _resolveNextEpisode() async {
    final titleId = widget.titleId;
    if (titleId == null) return;
    try {
      var season = widget.season;
      var episode = widget.episode;
      if (season == null || episode == null || season < 1 || episode < 1) {
        final resolved = await _resolveSeasonEpisode();
        season = resolved?.$1 ?? season;
        episode = resolved?.$2 ?? episode;
      }
      if (season == null || episode == null || season < 1 || episode < 1) return;

      final result = await _client.query(
        QueryOptions(
          document: gql(EPISODE_MAP),
          variables: {'id': titleId},
          fetchPolicy: FetchPolicy.networkOnly,
        ),
      );
      final json = result.data?['title'] as Map<String, dynamic>?;
      if (json == null) return;
      final catalogTitle = (json['title'] as String?)?.trim().isNotEmpty == true
          ? json['title'] as String
          : (widget.catalogTitle ?? widget.title);
      final kind = (json['kind'] as String?) ?? widget.kind ?? 'SERIES';
      final seasons = ((json['seasons'] as List?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(Season.fromJson)
          .where((s) => s.seasonNumber > 0)
          .toList()
        ..sort((a, b) => a.seasonNumber.compareTo(b.seasonNumber));
      Season? curSeason;
      for (final s in seasons) {
        if (s.seasonNumber == season) {
          curSeason = s;
          break;
        }
      }
      Episode? nextEp;
      var nextSeasonNum = season;
      var isNextSeason = false;
      if (curSeason != null) {
        final eps = List<Episode>.from(curSeason.episodes.where((e) => e.isReleased))
          ..sort((a, b) => a.episodeNumber.compareTo(b.episodeNumber));
        for (final e in eps) {
          if (e.episodeNumber > episode) {
            nextEp = e;
            break;
          }
        }
      }
      if (nextEp == null) {
        for (final s in seasons) {
          if (s.seasonNumber <= season) continue;
          final eps = List<Episode>.from(s.episodes.where((e) => e.isReleased))
            ..sort((a, b) => a.episodeNumber.compareTo(b.episodeNumber));
          if (eps.isNotEmpty) {
            nextEp = eps.first;
            nextSeasonNum = s.seasonNumber;
            isNextSeason = true;
            break;
          }
        }
      }
      if (nextEp == null || !mounted) return;
      final label =
          '$catalogTitle · S${nextSeasonNum.toString().padLeft(2, '0')}E${nextEp.episodeNumber.toString().padLeft(2, '0')}';
      setState(() {
        _nextEpisode = _NextEpisodeTarget(
          season: nextSeasonNum,
          episode: nextEp!.episodeNumber,
          episodeId: nextEp.id,
          label: label,
          catalogTitle: catalogTitle,
          kind: kind,
          isNextSeason: isNextSeason,
        );
      });
    } catch (_) {}
  }

  void _notifyOverlays() {
    _overlayEpoch.value++;
  }

  bool get _showChrome => isAndroidTv || _chromeVisible;

  /// Reveal seek / audio / subtitle chrome; restart the 15s auto-hide timer.
  void _bumpChrome() {
    if (isAndroidTv) return;
    _chromeHideTimer?.cancel();
    if (!_chromeVisible) {
      if (mounted) setState(() => _chromeVisible = true);
    }
    _chromeHideTimer = Timer(const Duration(seconds: _chromeHideSecs), () {
      if (!mounted || isAndroidTv) return;
      setState(() => _chromeVisible = false);
    });
  }

  Widget _chromeLayer({
    required Widget child,
    required Offset hiddenOffset,
  }) {
    final show = _showChrome;
    return IgnorePointer(
      ignoring: !show,
      child: AnimatedOpacity(
        opacity: show ? 1 : 0,
        duration: _chromeAnim,
        curve: Curves.easeOutCubic,
        child: AnimatedSlide(
          offset: show ? Offset.zero : hiddenOffset,
          duration: _chromeAnim,
          curve: Curves.easeOutCubic,
          child: child,
        ),
      ),
    );
  }

  void _armPlayNextPrompt({bool force = false}) {
    if (_nextEpisode == null || _playNextDismissed || _isTrailer) return;
    // Don't surface Play Next while still connecting / buffering the first pieces.
    if (!force && !_playbackStarted) return;
    if (!force && _playNextVisible) return;
    _playNextArmedAt ??= DateTime.now();
    _playNextTick?.cancel();
    _playNextTick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || _playNextDismissed) {
        _playNextTick?.cancel();
        return;
      }
      final armed = _playNextArmedAt;
      if (armed == null) return;
      final left = _playNextAutoHideSecs - DateTime.now().difference(armed).inSeconds;
      if (left <= 0) {
        _playNextTick?.cancel();
        // Timed out without picking next — leave and stop the torrent/stream.
        unawaited(_endPlaybackAndExit());
        return;
      }
      setState(() {
        _playNextVisible = true;
        _playNextSecondsLeft = left.clamp(1, _playNextAutoHideSecs);
      });
      _notifyOverlays();
    });
    if (!mounted) return;
    setState(() {
      _playNextVisible = true;
      _playNextSecondsLeft = _playNextAutoHideSecs;
    });
    _notifyOverlays();
  }

  void _updatePlayNextPrompt(Duration position) {
    final next = _nextEpisode;
    if (next == null || _playNextDismissed || _isTrailer) {
      if (_playNextVisible && mounted) {
        setState(() => _playNextVisible = false);
        _notifyOverlays();
      }
      return;
    }
    // Hide (and don't arm) until the stream is actually playing.
    if (!_playbackStarted) {
      if (_playNextVisible && mounted) {
        setState(() => _playNextVisible = false);
        _notifyOverlays();
      }
      return;
    }
    final durMs = _playbackDurationMs();
    final posMs = position.inMilliseconds;
    // Credits markers still drive completion / Play Next timing, but we never
    // show a Skip Credits button (_activeSegment is intro/recap only).
    final inCredits = _segments.any(
      (s) =>
          s.kind == 'CREDITS' &&
          s.contains(posMs, durationMs: durMs > 0 ? durMs : _durationMs),
    );

    // Mark the episode done once we're clearly past the meat of it —
    // without showing Play Next yet (that was firing too early at 85%).
    final mostlyDone = durMs >= 5 * 60 * 1000 &&
        posMs > 0 &&
        posMs >= (durMs * 0.85).round();
    if ((mostlyDone || inCredits) && !_episodeMarkedComplete) {
      _episodeMarkedComplete = true;
      unawaited(_saveProgress(
        position: position,
        duration: Duration(milliseconds: durMs > 0 ? durMs : posMs),
        complete: true,
      ));
    }

    // Play Next only in real credits, or in the last ~45s / final 3%.
    final nearEnd = durMs > 0 &&
        posMs > 0 &&
        (posMs >= durMs - 45 * 1000 ||
            (durMs >= 5 * 60 * 1000 && posMs >= (durMs * 0.97).round()));
    final shouldShow = inCredits || nearEnd;
    if (!shouldShow) {
      if (_playNextVisible && _playNextArmedAt == null && mounted) {
        setState(() => _playNextVisible = false);
        _notifyOverlays();
      }
      return;
    }
    _armPlayNextPrompt();
  }

  Future<void> _onPlayNextPressed() async {
    final next = _nextEpisode;
    if (next == null || _playNextBusy || !mounted) return;
    setState(() {
      _playNextBusy = true;
      _playNextVisible = false;
    });
    _notifyOverlays();
    try {
      await _saveProgress(complete: true, closing: true);
      if (!mounted) return;
      try {
        await _player?.pause();
      } catch (_) {}

      final previousSession = widget.sessionId;
      var opened = false;
      final started = await showStreamingPicker(
        context: context,
        client: ref.read(graphQLClientProvider),
        title: next.catalogTitle,
        kind: next.kind,
        titleId: widget.titleId,
        season: next.season,
        episode: next.episode,
        preferredLanguages: ref.read(serverInfoProvider).valueOrNull?.preferredLanguages ??
            ref.read(settingsProvider).preferredLanguages,
        resumePlayback: false,
        stopPreviousSessionId: previousSession,
        onReadyToPlay: (s) {
          if (!mounted) return;
          opened = true;
          setState(() => _playNextDismissed = true);
          if (widget.localTorrent || LocalTorrentEngine.instance.isActive) {
            unawaited(LocalTorrentEngine.instance.stop());
          }
          context.pushReplacement(
            '/player/${s.session.id}',
            extra: {
              'url': s.session.streamUrl,
              'title': next.label,
              'catalogTitle': next.catalogTitle,
              'kind': next.kind,
              'titleId': widget.titleId,
              'episodeId': next.episodeId,
              'season': next.season,
              'episode': next.episode,
              'startMs': 0,
              'isStream': true,
              'sessionId': s.session.id,
              'magnet': s.magnet,
              'localTorrent': s.localTorrent,
              'listedSeeders': s.session.seeders,
              'listedPeers': s.session.peers,
              'streamFileIndex': s.fileIndex,
              'posterUrl': widget.posterUrl,
              'backdropUrl': widget.backdropUrl,
            },
          );
        },
      );
      if (started == null || !mounted) {
        if (mounted && !opened) {
          setState(() {
            _playNextBusy = false;
            // Keep the prompt available if the user cancelled the picker.
            if (!_playNextDismissed) _playNextVisible = true;
          });
          _notifyOverlays();
        }
        return;
      }
      if (opened) return;

      setState(() => _playNextDismissed = true);
      if (widget.localTorrent || LocalTorrentEngine.instance.isActive) {
        unawaited(LocalTorrentEngine.instance.stop());
      }

      if (!mounted) return;
      context.pushReplacement(
        '/player/${started.session.id}',
        extra: {
          'url': started.session.streamUrl,
          'title': next.label,
          'catalogTitle': next.catalogTitle,
          'kind': next.kind,
          'titleId': widget.titleId,
          'episodeId': next.episodeId,
          'season': next.season,
          'episode': next.episode,
          'startMs': 0,
          'isStream': true,
          'sessionId': started.session.id,
          'magnet': started.magnet,
          'localTorrent': started.localTorrent,
          'listedSeeders': started.session.seeders,
          'listedPeers': started.session.peers,
          'streamFileIndex': started.fileIndex,
          'posterUrl': widget.posterUrl,
          'backdropUrl': widget.backdropUrl,
        },
      );
    } finally {
      if (mounted) setState(() => _playNextBusy = false);
    }
  }

  Future<void> _loadMediaSegments({int? durationMs}) async {
    final titleId = widget.titleId;
    if (_isTrailer || titleId == null || !_isUuid(titleId)) return;
    if (_segmentsLoading) {
      if (durationMs != null && durationMs > 30000) {
        _pendingSegmentDurationMs = durationMs;
      }
      return;
    }
    _segmentsLoading = true;
    try {
      var season = widget.season;
      var episode = widget.episode;
      final isSeries = (widget.kind ?? '').toUpperCase() == 'SERIES' ||
          (widget.kind ?? '').toUpperCase() == 'ANIME' ||
          season != null ||
          episode != null ||
          widget.episodeId != null;
      // Series need S/E for TheIntroDB. Resolve from episode map when missing.
      if (isSeries && (season == null || episode == null || season < 1 || episode < 1)) {
        final resolved = await _resolveSeasonEpisode();
        season = resolved?.$1 ?? season;
        episode = resolved?.$2 ?? episode;
        if (season == null || episode == null || season < 1 || episode < 1) {
          return;
        }
      }
      final dur = durationMs ?? _playbackDurationMs();
      final result = await _client.query(
        QueryOptions(
          document: gql(MEDIA_SEGMENTS),
          fetchPolicy: FetchPolicy.networkOnly,
          variables: {
            'titleId': titleId,
            'season': season,
            'episode': episode,
            if (dur > 30000) 'durationMs': dur,
          },
        ),
      );
      if (result.hasException) return;
      final raw = result.data?['mediaSegments'] as Map<String, dynamic>?;
      final list = (raw?['segments'] as List?) ?? const [];
      final segments = list
          .whereType<Map<String, dynamic>>()
          .map(MediaSegment.fromJson)
          .where((s) => s.startMs >= 0)
          .toList();
      if (!mounted) return;
      setState(() {
        _segments = segments;
        _segmentsFetched = true;
        _lastSegmentFetchDuration = dur > 0 ? dur : _lastSegmentFetchDuration;
      });
      final pos = _useExo
          ? (_exo?.value.position.inMilliseconds ?? 0)
          : (_player?.state.position.inMilliseconds ?? 0);
      final stablePos =
          pos < 1500 && _lastGoodPos.inMilliseconds > 5000 ? _lastGoodPos.inMilliseconds : pos;
      _updateActiveSegment(stablePos);
    } catch (_) {
      // Skip markers are best-effort — never block playback.
    } finally {
      _segmentsLoading = false;
      final pending = _pendingSegmentDurationMs;
      _pendingSegmentDurationMs = null;
      if (pending != null &&
          pending > 30000 &&
          (pending - _lastSegmentFetchDuration).abs() > 5000) {
        unawaited(_loadMediaSegments(durationMs: pending));
      }
    }
  }

  /// Look up S/E from the catalog when the player was opened without them.
  Future<(int, int)?> _resolveSeasonEpisode() async {
    final titleId = widget.titleId;
    final episodeId = widget.episodeId;
    if (titleId == null || episodeId == null || !_isUuid(episodeId)) {
      // Default to S01E01 so Skip Intro still has a chance.
      if ((widget.kind ?? '').toUpperCase() == 'SERIES' ||
          (widget.kind ?? '').toUpperCase() == 'ANIME') {
        return (1, 1);
      }
      return null;
    }
    try {
      final result = await _client.query(
        QueryOptions(
          document: gql(EPISODE_MAP),
          variables: {'id': titleId},
          fetchPolicy: FetchPolicy.cacheFirst,
        ),
      );
      final json = result.data?['title'] as Map<String, dynamic>?;
      final seasons = (json?['seasons'] as List?) ?? const [];
      for (final s in seasons.whereType<Map<String, dynamic>>()) {
        final seasonNum = (s['seasonNumber'] as num?)?.toInt() ?? 0;
        final episodes = (s['episodes'] as List?) ?? const [];
        for (final e in episodes.whereType<Map<String, dynamic>>()) {
          if (e['id'] == episodeId) {
            final epNum = (e['episodeNumber'] as num?)?.toInt() ?? 0;
            if (seasonNum > 0 && epNum > 0) return (seasonNum, epNum);
          }
        }
      }
    } catch (_) {}
    return (1, 1);
  }

  Future<void> _skipActiveSegment() async {
    final seg = _activeSegment;
    if (seg == null) return;
    // Only skip opening segments — never credits (that ended the episode).
    if (seg.kind != 'INTRO' && seg.kind != 'RECAP') {
      if (mounted) {
        setState(() => _activeSegment = null);
        _notifyOverlays();
      }
      return;
    }
    final duration = _playbackDurationMs();
    final targetMs = seg.skipTargetMs(durationMs: duration);
    final target = Duration(milliseconds: targetMs < 0 ? 0 : targetMs);
    if (mounted) {
      setState(() => _activeSegment = null);
      _notifyOverlays();
    }
    await _seekPlayback(target);
    // Keep playing after the skip — progressive streams can pause on seek.
    try {
      if (_useExo) {
        await _exo?.play();
      } else {
        await _player?.play();
      }
    } catch (_) {}
  }

  Future<void> _saveProgress({
    Duration? position,
    Duration? duration,
    bool closing = false,
    bool invalidateHome = false,
    bool complete = false,
  }) async {
    final titleId = widget.titleId;
    if (titleId == null || _isTrailer) return;
    if (_progressFlushed) return;
    final player = _player;
    final pos = position ??
        (_useExo ? _exo?.value.position : player?.state.position) ??
        Duration.zero;
    final dur = duration ?? (_useExo ? _exo?.value.duration : player?.state.duration);
    if (!complete && pos.inMilliseconds < 2000) {
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
            'positionMs': complete && durationMs != null
                ? durationMs
                : pos.inMilliseconds,
            'durationMs': durationMs,
            if (complete) 'complete': true,
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
              'position': complete ? 0 : pos.inMilliseconds,
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

  Future<void> _openTrailer({int? preferHeight}) async {
    final key = widget.youtubeKey;
    if (key == null || key.isEmpty) return;
    setState(() => _buffering = true);
    try {
      final quality = widget.trailerPreferredQuality ?? '720p';
      final height = preferHeight ??
          widget.trailerInitialHeight ??
          youtubeHeightForQuality(quality);

      // Prefer a URL already resolved on the detail screen for instant start.
      var url = widget.playbackUrl.trim();
      if (url.isEmpty) {
        final pick = await youtubeFastMuxed(key, preferHeight: height);
        if (!mounted) return;
        if (pick == null) {
          throw StateError('No playable trailer streams found');
        }
        url = pick.url;
        _trailerHeight = pick.height;
      } else {
        _trailerHeight = height;
      }

      await _open(url, youtube: true);
      await _player?.play();
      if (mounted) setState(() => _buffering = false);

      // Quality menu can populate after playback has already started.
      unawaited(_loadTrailerQualities(key, preferHeight: height));
    } catch (e) {
      if (!mounted) return;
      setState(() => _buffering = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Couldn’t load that trailer in the player. $e')),
      );
    }
  }

  Future<void> _loadTrailerQualities(String key, {required int preferHeight}) async {
    try {
      final options = await youtubeQualityOptions(key);
      if (!mounted || options.isEmpty) return;
      setState(() {
        _trailerQualities = options;
        _trailerHeight ??= youtubePickQuality(options, preferHeight: preferHeight)?.height;
      });
    } catch (_) {}
  }

  Future<void> _switchTrailerQuality(YoutubeQualityOption option) async {
    if (!_isTrailer || option.height == _trailerHeight) return;
    final pos = _player?.state.position ?? Duration.zero;
    setState(() {
      _buffering = true;
      _trailerHeight = option.height;
    });
    await _open(option.url, youtube: true);
    if (pos.inMilliseconds > 500) {
      try {
        await _player?.seek(pos);
      } catch (_) {}
    }
    await _player?.play();
    if (mounted) setState(() => _buffering = false);
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
            seeders: 0,
            peers: 0,
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
          fileIndex: widget.streamFileIndex,
          onStats: (local) {
            if (!mounted) return;
            setState(() {
              _streamInfo = StreamSession(
                id: widget.sessionId ?? 'local',
                title: widget.title,
                progress: (local.bufferPct / 100).clamp(0, 1),
                bufferProgress: (local.bufferPct / 100).clamp(0, 1),
                downloadMbps: local.downloadMbps,
                seeders: local.seeders,
                peers: local.peers,
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
        await _player?.play();
        setState(() {
          _streamOpened = true;
          _streamError = null;
          _buffering = true;
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
          seeders: 0,
          peers: 0,
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
      await Future<void>.delayed(const Duration(milliseconds: 350));
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
    await _player?.play();
    setState(() {
      _streamOpened = true;
      _streamError = null;
      _buffering = true;
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
          seeders: local.seeders,
          peers: local.peers,
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
    // Don't treat "_streamOpened" alone as video — that hid the HUD while the
    // demuxer was still waiting on the first torrent pieces.
    return player.state.duration.inMilliseconds > 0 &&
        (player.state.position.inMilliseconds > 0 || _buffered.inMilliseconds > 0 || _playing);
  }

  /// Skip Intro / Play Next once real video is on screen.
  /// Do NOT require `!_showStreamHud` — torrent intros often rebuffer, and that
  /// used to hide Skip Intro for the whole opening.
  bool get _playbackStarted {
    if (!_hasVideo) return false;
    // Still on the poster / peer-find phase (no frames yet counted as opened play).
    if (widget.isStream && !_streamOpened && !_playing) return false;
    return _playing || _lastGoodPos.inMilliseconds >= 400;
  }

  bool get _showStreamHud {
    if (!widget.isStream || _streamError != null) return false;
    if (!_hasVideo) return true;
    return _buffering || _seeking;
  }

  /// Compact seed/speed chip — always visible while streaming (matches skip height).
  bool get _showStreamChip =>
      widget.isStream && _streamError == null && (_hasVideo || _streamOpened);

  Future<void> _open(String url, {String? fileId, bool youtube = false}) async {
    if (fileId != null) _fileId = fileId;
    final isYoutube = youtube ||
        url.contains('googlevideo.com') ||
        url.contains('youtube.com');
    final local = url.contains('127.0.0.1') || url.contains('localhost') || url.contains('[::1]');
    final token = ref.read(settingsProvider).apiToken;
    final headers = isYoutube
        ? youtubeStreamHeaders
        : (local ? const <String, String>{} : mediaAuthHeaders(token));
    if (_useExo) {
      await _openExo(url, headers);
      _loadSubtitles();
      return;
    }
    final native = _player?.platform;
    if (native is NativePlayer) {
      // Clear any leftover external-audio binding from older builds.
      await native.setProperty('audio-files', '');
    }
    await _player?.open(Media(url, httpHeaders: headers));
    if (widget.startMs > 0) {
      try {
        await _player!.stream.duration.firstWhere((d) => d.inMilliseconds > 0).timeout(const Duration(seconds: 20));
      } catch (_) {}
      await _seekPlayback(Duration(milliseconds: widget.startMs));
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
      _playing = v.isPlaying;
      _buffered = buffered;
    });
    _onPosition(v.position);
    if (v.isCompleted) {
      unawaited(_saveProgress(position: v.position, duration: v.duration, complete: true));
      if (widget.isStream && _nextEpisode != null && !_playNextDismissed) {
        _armPlayNextPrompt(force: true);
      } else {
        unawaited(_endPlaybackAndExit());
      }
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

  bool _audioLanguagePicked = false;

  /// Pick the first audio track matching server/device preferred languages.
  Future<void> _applyPreferredAudioLanguage(List<AudioTrack> audio) async {
    if (_audioLanguagePicked || audio.isEmpty || _player == null) return;
    final preferred = preferredLanguageCodes(
      ref.read(serverInfoProvider).valueOrNull?.preferredLanguages ??
          ref.read(settingsProvider).preferredLanguages,
    );
    if (preferred.isEmpty) return;

    AudioTrack? match;
    for (final code in preferred) {
      for (final track in audio) {
        final lang = (track.language ?? '').trim().toLowerCase();
        final title = (track.title ?? '').trim().toLowerCase();
        if (lang == code ||
            lang.startsWith('$code-') ||
            lang.startsWith('${code}_') ||
            title.contains(languageDisplayName(code).toLowerCase()) ||
            title.contains(code)) {
          match = track;
          break;
        }
      }
      if (match != null) break;
    }
    if (match == null) return;
    if (match.id == _activeAudioId) {
      _audioLanguagePicked = true;
      return;
    }
    try {
      await _player!.setAudioTrack(match);
      if (!mounted) return;
      _audioLanguagePicked = true;
      setState(() => _activeAudioId = match!.id);
    } catch (_) {}
  }

  Widget _bufferOverlay() {
    final info = _streamInfo;
    final local = LocalTorrentEngine.instance.currentStats();
    final pct = ((info?.bufferProgress ?? 0) * 100).clamp(0, 100);
    final speed = info?.downloadMbps ?? local?.downloadMbps ?? 0;
    // Live swarm only — never Jackett listed counts.
    final seeders = info?.seeders ?? local?.seeders ?? 0;
    final peers = info?.peers ?? local?.peers ?? 0;
    final line = _streamStatsLine(pct: pct, speed: speed, seeders: seeders, peers: peers);
    final art = widget.backdropUrl ?? widget.posterUrl;
    // Poster only while waiting for first start — never over mid-playback rebuffers.
    final showPoster = !_streamOpened && art != null && art.isNotEmpty;

    return Stack(fit: StackFit.expand, children: [
      if (showPoster) ...[
        const ColoredBox(color: Colors.black),
        CachedArt(
          url: art,
          fallbackUrl: widget.posterUrl,
          // FIT_XY: stretch to the exact player viewport (no letterbox / crop).
          fit: BoxFit.fill,
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.black.withValues(alpha: 0.35),
                Colors.black.withValues(alpha: 0.72),
                Colors.black.withValues(alpha: 0.88),
              ],
            ),
          ),
        ),
      ],
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
    final String speedStr;
    if (speed >= 0.05) {
      speedStr = '${speed.toStringAsFixed(1)} MB/s';
    } else if (pct >= 2 && (_hasVideo || _playing)) {
      speedStr = 'ready';
    } else if (seeders > 0 || peers > 0) {
      // Peers alone ≠ playable data yet.
      speedStr = pct > 0 ? 'buffering…' : 'connected · waiting for data…';
    } else {
      speedStr = 'finding peers…';
    }
    final swarm = seeders > 0
        ? '  ·  $seeders seeds'
        : (peers > 0 ? '  ·  $peers peers' : '');
    return '${pct.round()}%  ·  $speedStr$swarm';
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _allowLeave,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        await _onBackPressed();
      },
      child: Focus(
        autofocus: true,
        descendantsAreFocusable: !isAndroidTv,
        onKeyEvent: _onFocusKey,
        child: MouseRegion(
          onHover: (_) => _bumpChrome(),
          child: Listener(
            onPointerHover: (_) => _bumpChrome(),
            onPointerMove: (_) => _bumpChrome(),
            onPointerDown: (_) => _bumpChrome(),
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
            child: _chromeLayer(
              hiddenOffset: const Offset(0, -0.35),
              child: IconButton(
                onPressed: _onBackPressed,
                icon: const Icon(Icons.arrow_back, color: Colors.white),
              ),
            ),
          ),
          if (_showSeekControls)
            Positioned(
              left: 0,
              right: 0,
              bottom: widget.isStream ? 96 : 28,
              child: _chromeLayer(
                hiddenOffset: const Offset(0, 0.45),
                child: _seekSkipBar(),
              ),
            ),
          // Windowed: align with the seeding chip on the scaffold. Fullscreen
          // copies live inside media_kit controls (native fullscreen route).
          if (!_inFullscreen) ..._skipAndPlayNextOverlays(),
          if (_showStreamChip && !_showStreamHud)
            Positioned(
              right: _actionChipInset,
              bottom: _actionChipBottom,
              child: _streamStatsChip(),
            ),
          Positioned(
            top: 12,
            right: 12,
            child: _chromeLayer(
              hiddenOffset: const Offset(0, -0.35),
              child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_isTrailer && _trailerQualities.length > 1)
                  PopupMenuButton<YoutubeQualityOption>(
                    color: PtTheme.panel,
                    tooltip: 'Trailer quality',
                    icon: const Icon(Icons.high_quality_outlined, color: Colors.white),
                    onOpened: _bumpChrome,
                    onSelected: (q) {
                      _bumpChrome();
                      _switchTrailerQuality(q);
                    },
                    itemBuilder: (context) => [
                      for (final q in _trailerQualities)
                        CheckedPopupMenuItem(
                          value: q,
                          checked: q.height == _trailerHeight,
                          child: Text(q.label),
                        ),
                    ],
                  ),
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
                    onOpened: _bumpChrome,
                    onSelected: (id) {
                      _bumpChrome();
                      final match = _audioTracks.where((t) => t.id == id);
                      if (match.isEmpty) return;
                      _audioLanguagePicked = true;
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
                    onOpened: _bumpChrome,
                    onSelected: (value) {
                      _bumpChrome();
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
                            CheckedPopupMenuItem(
                              value: 'download:${lang.code}',
                              checked: preferredLanguageCodes(
                                ref.read(settingsProvider).preferredLanguages,
                              ).contains(lang.code),
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
                    onOpened: _bumpChrome,
                    onSelected: (f) {
                      _bumpChrome();
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
          ),
        ],
      ),
            ),
          ),
        ),
      ),
    );
  }

  // Match the seeding chip: 16px from the side, 72px from the bottom.
  static const double _actionChipInset = 16;
  static const double _actionChipBottom = 72;
  // When the seed chip is visible, lift Skip / Play Next one chip row above it.
  static const double _actionChipStackLift = 52;

  double get _skipPlayNextBottom {
    final seedVisible = _showStreamChip && !_showStreamHud && widget.isStream;
    return seedVisible ? _actionChipBottom + _actionChipStackLift : _actionChipBottom;
  }

  List<Widget> _skipAndPlayNextOverlays() {
    final bottom = _skipPlayNextBottom;
    // Skip Intro / Play Next only after playback has actually started.
    final showSkip = _playbackStarted &&
        _activeSegment != null &&
        (_activeSegment!.kind == 'INTRO' || _activeSegment!.kind == 'RECAP') &&
        !_isTrailer;
    final showPlayNext = _playbackStarted && _playNextVisible && _nextEpisode != null;
    // Same bottom-left spot for both — they never show at the same time.
    return [
      if (showSkip)
        Positioned(
          left: _actionChipInset,
          bottom: bottom,
          child: _skipSegmentButton(_activeSegment!),
        ),
      if (showPlayNext)
        Positioned(
          left: _actionChipInset,
          bottom: bottom,
          child: _playNextButton(_nextEpisode!),
        ),
    ];
  }

  Widget _mediaKitControls(VideoState state) {
    final fullscreen = isFullscreen(state.context);
    return Stack(
      fit: StackFit.expand,
      children: [
        IgnorePointer(
          ignoring: isAndroidTv,
          child: AdaptiveVideoControls(state),
        ),
        // Native fullscreen uses a separate route; scaffold chips won't show.
        // ValueListenableBuilder keeps countdown / skip state fresh there.
        if (fullscreen)
          Positioned.fill(
            child: ValueListenableBuilder<int>(
              valueListenable: _overlayEpoch,
              builder: (context, _, __) {
                return Stack(
                  fit: StackFit.expand,
                  children: _skipAndPlayNextOverlays(),
                );
              },
            ),
          ),
      ],
    );
  }

  Widget _streamStatsChip() {
    final info = _streamInfo;
    final local = LocalTorrentEngine.instance.currentStats();
    final pct = ((info?.bufferProgress ?? 0) * 100).clamp(0, 100);
    final speed = info?.downloadMbps ?? local?.downloadMbps ?? 0;
    final seeders = info?.seeders ?? local?.seeders ?? 0;
    final peers = info?.peers ?? local?.peers ?? 0;
    final line = _streamStatsLine(pct: pct, speed: speed, seeders: seeders, peers: peers);
    return SafeArea(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.68),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Text(
            line,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }

  Widget _playNextButton(_NextEpisodeTarget next) {
    final title = _playNextBusy
        ? 'Starting next…'
        : next.isNextSeason
            ? 'Next Season  ·  ${_playNextSecondsLeft}s'
            : 'Play Next  ·  ${_playNextSecondsLeft}s';
    return SafeArea(
      child: Material(
        color: Colors.black.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: _playNextBusy ? null : _onPlayNextPressed,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                if (_playNextBusy)
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                else
                  const Icon(Icons.skip_next_rounded, color: Colors.white, size: 22),
                const SizedBox(width: 8),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 260),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                        ),
                      ),
                      if (!_playNextBusy) ...[
                        const SizedBox(height: 2),
                        Text(
                          next.label,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.75),
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _skipSegmentButton(MediaSegment segment) {
    // Match seed/speed chip chrome and insets (16 / 72).
    return SafeArea(
      child: Material(
        color: Colors.black.withValues(alpha: 0.68),
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: _skipActiveSegment,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  segment.label,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(width: 6),
                const Icon(Icons.skip_next_rounded, color: Colors.white, size: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _seekSkipBar() {
    Widget skipButton({
      required IconData icon,
      required int seconds,
    }) {
      final enabled = _canSeek;
      return Opacity(
        opacity: enabled ? 1 : 0.45,
        child: Material(
          color: Colors.black.withValues(alpha: 0.62),
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: enabled ? () => _seekRelative(seconds) : null,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Icon(icon, color: Colors.white, size: 26),
            ),
          ),
        ),
      );
    }

    return SafeArea(
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          skipButton(icon: Icons.replay_10, seconds: -10),
          const SizedBox(width: 18),
          skipButton(icon: Icons.forward_10, seconds: 10),
        ],
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
    // Scrubber / ±10s stay available whenever seek is allowed (including paused).
    final seekOk = _canSeek || _showSeekControls;
    final video = MaterialVideoControlsTheme(
      normal: MaterialVideoControlsThemeData(
        seekGesture: seekOk,
        seekOnDoubleTap: seekOk,
        seekBarContainerHeight: 36.0,
        seekBarHeight: 2.4,
        seekBarThumbSize: 12.8,
      ),
      fullscreen: MaterialVideoControlsThemeData(
        seekGesture: seekOk,
        seekOnDoubleTap: seekOk,
        seekBarContainerHeight: 36.0,
        seekBarHeight: 2.4,
        seekBarThumbSize: 12.8,
      ),
      child: MaterialDesktopVideoControlsTheme(
        normal: MaterialDesktopVideoControlsThemeData(
          seekBarContainerHeight: 36.0,
          seekBarHeight: 3.2,
          seekBarHoverHeight: 5.6,
          seekBarThumbSize: 12.0,
        ),
        fullscreen: MaterialDesktopVideoControlsThemeData(
          seekBarContainerHeight: 36.0,
          seekBarHeight: 3.2,
          seekBarHoverHeight: 5.6,
          seekBarThumbSize: 12.0,
        ),
        child: Video(
          key: _videoKey,
          controller: controller,
          controls: _mediaKitControls,
          wakelock: true,
          onEnterFullscreen: () async {
            if (mounted) setState(() => _inFullscreen = true);
            await defaultEnterNativeFullscreen();
          },
          onExitFullscreen: () async {
            if (mounted) setState(() => _inFullscreen = false);
            await defaultExitNativeFullscreen();
          },
        ),
      ),
    );
    return video;
  }
}
