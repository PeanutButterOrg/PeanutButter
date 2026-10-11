import 'dart:async';
import 'dart:io' show Directory, File, Platform;

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

import '../android_playback.dart';
import '../content_languages.dart';
import '../graphql/client.dart';
import '../graphql/queries.dart';
import '../local_torrent.dart';
import '../models.dart';
import '../platform/device_profile.dart';
import '../platform/input_policy.dart';
import '../platform/playback_backend.dart';
import '../platform/stream_seek_controller.dart';
import '../providers/catalog.dart';
import '../providers/settings.dart';
import '../theme.dart';
import '../tv.dart';
import '../tv_device.dart';
import '../tv_nav.dart';
import '../tv_remote.dart';
import '../friendly_error.dart';
import '../player_cache.dart';
import '../stream_stats.dart';
import '../widgets/cached_art.dart';
import '../widgets/streaming_picker.dart';
import '../widgets/subtitle_import.dart';
import '../widgets/tv_chrome.dart';
import '../youtube_stream.dart';

class _VlcTrack {
  const _VlcTrack({required this.id, required this.label});
  final int id;
  final String label;
}

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
    this.downloadUrl,
    this.source,
  });

  final String id;
  final String language;
  final String label;
  final String content;
  /// Wyzie (and similar) — body is fetched only after the user picks this row.
  final String? downloadUrl;
  final String? source;

  bool get needsDownload =>
      (content.isEmpty || !content.contains('-->')) &&
      (downloadUrl != null && downloadUrl!.isNotEmpty);
}

class _PlayerScreenState extends ConsumerState<PlayerScreen> with WidgetsBindingObserver {
  Player? _player;
  VideoController? _controller;
  VideoPlayerController? _exo;
  /// After Exo fails on this SoC, switch the rest of the session to MediaKit.
  bool _useExoFallbackMediaKit = false;
  Timer? _exoFrameWatch;
  String? _exoOpenUrl;
  Map<String, String>? _exoOpenHeaders;
  /// Native LibVLC (Flutter Texture) — Android TV decoder path.
  StreamSubscription<Map<String, dynamic>>? _vlcSub;
  bool _vlcStarted = false;
  bool _vlcReady = false;
  int? _vlcTextureId;
  int _vlcVideoW = 0;
  int _vlcVideoH = 0;
  Duration _vlcPosition = Duration.zero;
  Duration _vlcDuration = Duration.zero;
  List<_VlcTrack> _vlcAudio = const [];
  List<_VlcTrack> _vlcSpu = const [];
  late String _url;
  late String _fileId;
  List<_SubtitleOption> _subs = const [];
  /// Pending Wyzie search hits shown inline in the subtitle menu (same dropdown).
  List<_SubtitleOption> _wyzieHits = const [];
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
  Timer? _bufferStallTimer;
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
  /// Desktop/mouse + TV chrome: seek ±10s + audio/subs (auto-hide).
  bool _chromeVisible = true;
  Timer? _chromeHideTimer;
  static const int _chromeHideSecs = 8;
  static const Duration _chromeAnim = Duration(milliseconds: 280);
  final FocusNode _rootFocus = FocusNode(debugLabel: 'playerRoot');
  final FocusNode _backFocus = FocusNode(debugLabel: 'playerBack');
  final FocusNode _audioFocus = FocusNode(debugLabel: 'playerAudio');
  final FocusNode _subsFocus = FocusNode(debugLabel: 'playerSubs');
  final FocusNode _rewindFocus = FocusNode(debugLabel: 'playerRewind');
  final FocusNode _playFocus = FocusNode(debugLabel: 'playerPlay');
  final FocusNode _forwardFocus = FocusNode(debugLabel: 'playerForward');
  final FocusNode _skipFocus = FocusNode(debugLabel: 'playerSkip');
  final FocusNode _playNextFocus = FocusNode(debugLabel: 'playerPlayNext');
  late final StreamSeekController _seekCtl;
  bool _seekSettling = false;
  bool _episodeMarkedComplete = false;
  DateTime _lastProgress = DateTime.fromMillisecondsSinceEpoch(0);
  bool _progressFlushed = false;
  bool _savedOnce = false;
  bool _closing = false;
  bool _playerReleased = false;
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
  /// True once torrent session reports ready + a playable URL (may precede Player).
  bool _streamReady = false;
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

  /// Physical Android TV: LibVLC. Phone: Exo. Desktop: media_kit.
  bool get _useVlc {
    if (_isTrailer) return false;
    return PlaybackBackendFactory.usesVlc(
      DeviceProfile.current,
      ref.read(settingsProvider).androidPlaybackBackend,
    );
  }

  /// Android phone / emulator ExoPlayer (or settings force).
  bool get _useExo =>
      !_useExoFallbackMediaKit &&
      PlaybackBackendFactory.usesExo(
        DeviceProfile.current,
        ref.read(settingsProvider).androidPlaybackBackend,
      );

  static bool _isUuid(String? value) {
    if (value == null || value.length != 36) return false;
    return RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$').hasMatch(value);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Prefer the non-Riverpod flag — writing StateProviders from initState
    // races go_router rebuilds on Android TV (red "UI error" screen).
    playbackSessionActive = true;
    _client = ref.read(graphQLClientProvider);
    _url = _rewriteMediaUrl(widget.playbackUrl);
    _fileId = widget.fileId;
    _seekCtl = StreamSeekController(
      settle: const Duration(milliseconds: 800),
      durationMs: () => _currentDurationMs,
      onRetarget: (target) {
        // Move torrent piece window immediately — don't wait for settle.
        unawaited(_retargetStreamBuffer(target));
        if (mounted) {
          setState(() {
            _lastSeekTarget = target;
            _buffering = true;
            _seeking = true;
          });
        }
      },
      onSettlingChanged: (settling) {
        if (!mounted) return;
        setState(() {
          _seekSettling = settling;
          if (settling) {
            _buffering = true;
            _seeking = true;
          }
        });
      },
      onCommit: _commitSeekPlayback,
    );
    // Start torrent poll/bootstrap immediately — never wait on native player init.
    if (widget.isStream) {
      _ensureStreamPoll();
      unawaited(_prepareStream());
    }
    if (_useVlc) {
      _vlcSub = AndroidPlayback.vlcEvents.listen(_onVlcEvent);
      _kickOffPlayback();
    } else if (_useExo) {
      // Android Exo path: no MediaKit Player() — open as soon as the URL is ready.
      _kickOffPlayback();
    } else {
      // Linux / Windows / macOS: sync media_kit init (responsive buffering).
      _initMediaKitPlayer();
      _kickOffPlayback();
    }
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    // Register hardware key handler AFTER everything is set up.
    HardwareKeyboard.instance.addHandler(_onHardwareKey);
    WidgetsBinding.instance.addPostFrameCallback((_) => _bumpChrome());
  }

  String _rewriteMediaUrl(String url) {
    final server = ref.read(settingsProvider).serverUrl;
    return resolveServerResourceUrl(url, server);
  }

  void _ensureStreamPoll() {
    if (!widget.isStream || _streamPoll != null) return;
    _streamPoll = Timer.periodic(const Duration(seconds: 1), (_) => unawaited(_pollStream()));
  }

  void _attachMediaKitPlayer(Player player, VideoController controller) {
    if (_player != null) return;
    _player = player;
    _controller = controller;
    _bindMediaKitListeners();
  }

  void _initMediaKitPlayer() {
    if (_player != null) return;
    try {
      MediaKit.ensureInitialized();
      // Tiny demuxer RAM on Android — large sync alloc freezes TV emulators.
      // Desktop streams: keep modest to avoid Windows OOM crashes.
      final bufferBytes = (!kIsWeb && Platform.isAndroid)
          ? 4 * 1024 * 1024
          : (widget.isStream
              ? ((!kIsWeb && (Platform.isWindows || Platform.isMacOS))
                  ? 24 * 1024 * 1024
                  : 48 * 1024 * 1024)
              : 32 * 1024 * 1024);
      final player = Player(
        configuration: PlayerConfiguration(
          bufferSize: bufferBytes,
          ready: _onPlayerReady,
        ),
      );
      _attachMediaKitPlayer(player, VideoController(player));
    } catch (e, st) {
      debugPrint('PeanutButter player init failed: $e\n$st');
      _streamError = 'Couldn’t start the video player on this device.\n$e';
    }
  }

  void _bindMediaKitListeners() {
    final player = _player;
    if (player == null) return;
    _posSub?.cancel();
    _bufferingSub?.cancel();
    _bufferSub?.cancel();
    _tracksSub?.cancel();
    _completedSub?.cancel();
    _posSub = player.stream.position.listen(_onPosition);
    _bufferingSub = player.stream.buffering.listen((value) {
      if (!mounted) return;
      setState(() => _buffering = value);
      if (value) {
        _bumpChrome();
        _armBufferStallWatch();
      } else {
        _bufferStallTimer?.cancel();
      }
    });
    _bufferSub = player.stream.buffer.listen((value) {
      if (mounted) setState(() => _buffered = value);
    });
    _tracksSub = player.stream.tracks.listen((tracks) {
      final audio = [
        for (final t in tracks.audio)
          if (t.id != 'auto' && t.id != 'no') t,
      ];
      if (!mounted) return;
      setState(() {
        _audioTracks = audio;
        _activeAudioId ??= player.state.track.audio.id;
      });
      unawaited(_applyPreferredAudioLanguage(audio));
    });
    _completedSub = player.stream.completed.listen((done) {
      if (!done || _seeking) return;
      unawaited(_onPlaybackCompleted());
    });
    // While paused, keep demux/torrent prefetch warm for a smooth resume.
    player.stream.playing.listen((playing) {
      if (!mounted) return;
      setState(() => _playing = playing);
      if (!playing && (!widget.isStream || _streamOpened)) {
        _onPausedKeepBuffering();
      }
    });
    // Rebuild when video dimensions appear (torrent streams often start with no duration).
    player.stream.width.listen((_) {
      if (mounted) setState(() {});
    });
    player.stream.duration.listen((d) {
      if (d.inMilliseconds <= 0) return;
      if (!_segmentsFetched ||
          (_lastSegmentFetchDuration >= 0 &&
              (d.inMilliseconds - _lastSegmentFetchDuration).abs() > 5000)) {
        unawaited(_loadMediaSegments(durationMs: d.inMilliseconds));
      }
    });
  }

  void _kickOffPlayback() {
    _ensureStreamPoll();
    if (_player != null || _useExo || _useVlc) {
      if (_isTrailer) {
        _buffering = true;
        unawaited(_openTrailer());
      } else if (widget.isStream) {
        // Prepare may already be running from initState — just try to open.
        unawaited(_tryOpenPreparedStream());
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
    // Another route (Settings / dialogs) is on top — do not steal keys or
    // thrash chrome (causes full-screen blink on Back).
    if (!_playerRouteIsCurrent) return false;
    // While the leave-confirm dialog is up, don't steal Select/OK from its buttons.
    if (_confirmExitOpen) {
      if (tvIsBackKey(event.logicalKey)) {
        unawaited(_onBackPressed());
        return true;
      }
      return false;
    }

    final chromeFocused = _chromeControlFocused;
    // Prefer universal remote mapping (physical + logical aliases).
    final dir = tvNavDirFromKey(event);

    // When a chrome control already has focus, let FocusTraversal / buttons
    // handle D-pad and Select — do not steal for seek / play-pause.
    if (chromeFocused &&
        (dir != null ||
            tvIsActivateKey(event.logicalKey) ||
            event.logicalKey == LogicalKeyboardKey.select ||
            event.logicalKey == LogicalKeyboardKey.enter ||
            event.logicalKey == LogicalKeyboardKey.space)) {
      _bumpChrome();
      return false;
    }

    if (dir == TvNavDir.left) {
      final revealed = _revealChromeForTv();
      if (revealed) {
        _playFocus.requestFocus();
        return true;
      }
      if (_canSeek) _seekRelative(-10);
      _bumpChrome();
      return true;
    }
    if (dir == TvNavDir.right) {
      final revealed = _revealChromeForTv();
      if (revealed) {
        _playFocus.requestFocus();
        return true;
      }
      if (_canSeek) _seekRelative(10);
      _bumpChrome();
      return true;
    }
    if (dir == TvNavDir.up) {
      _bumpChrome();
      _audioFocus.requestFocus();
      return true;
    }
    if (dir == TvNavDir.down) {
      _bumpChrome();
      _playFocus.requestFocus();
      return true;
    }
    return _handlePlayerKey(event.logicalKey);
  }

  bool get _chromeControlFocused {
    final primary = FocusManager.instance.primaryFocus;
    if (primary == null) return false;
    return primary == _backFocus ||
        primary == _audioFocus ||
        primary == _subsFocus ||
        primary == _rewindFocus ||
        primary == _playFocus ||
        primary == _forwardFocus ||
        primary == _skipFocus ||
        primary == _playNextFocus ||
        _backFocus.hasFocus ||
        _audioFocus.hasFocus ||
        _subsFocus.hasFocus ||
        _rewindFocus.hasFocus ||
        _playFocus.hasFocus ||
        _forwardFocus.hasFocus ||
        _skipFocus.hasFocus ||
        _playNextFocus.hasFocus;
  }

  /// Returns true if chrome was hidden and is now shown (first D-pad press).
  bool _revealChromeForTv() {
    if (!isAndroidTv) return false;
    if (_chromeVisible) return false;
    _bumpChrome();
    return true;
  }

  KeyEventResult _onFocusKey(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    // Child chrome controls handle their own ActivateIntent / arrows.
    if (_chromeControlFocused) return KeyEventResult.ignored;
    return _handlePlayerKey(event.logicalKey) ? KeyEventResult.handled : KeyEventResult.ignored;
  }

  bool _handlePlayerKey(LogicalKeyboardKey key) {
    _bumpChrome();
    if (tvIsActivateKey(key) ||
        key == LogicalKeyboardKey.mediaPlay ||
        key == LogicalKeyboardKey.mediaPause ||
        key == LogicalKeyboardKey.mediaPlayPause) {
      if (isAndroidTv && !_chromeControlFocused) {
        _playFocus.requestFocus();
      }
      _playOrPause();
      return true;
    }
    if (key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.mediaFastForward ||
        key == LogicalKeyboardKey.mediaSkipForward ||
        key == LogicalKeyboardKey.channelDown) {
      if (_canSeek) _seekRelative(10);
      return true;
    }
    if (key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.mediaRewind ||
        key == LogicalKeyboardKey.mediaSkipBackward ||
        key == LogicalKeyboardKey.channelUp) {
      if (_canSeek) _seekRelative(-10);
      return true;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      if (_playbackStarted &&
          _activeSegment != null &&
          (_activeSegment!.kind == 'INTRO' || _activeSegment!.kind == 'RECAP') &&
          _skipFocus.canRequestFocus) {
        _skipFocus.requestFocus();
        return true;
      }
      if (_playbackStarted && _playNextVisible && _playNextFocus.canRequestFocus) {
        _playNextFocus.requestFocus();
        return true;
      }
      _audioFocus.requestFocus();
      return true;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      if (_skipFocus.hasFocus || _playNextFocus.hasFocus) {
        _playFocus.requestFocus();
        return true;
      }
      _playFocus.requestFocus();
      return true;
    }
    if (key == LogicalKeyboardKey.pageUp || key == LogicalKeyboardKey.pageDown) {
      return true;
    }
    if (tvIsBackKey(key)) {
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
    if (_useExo || _useVlc) return false;
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
    final bool isAndroid = !kIsWeb && Platform.isAndroid;
    final bool isWindows = !kIsWeb && Platform.isWindows;
    final bool isMacOS = !kIsWeb && Platform.isMacOS;
    // YouTube progressive streams often paint a solid blue frame with HW decode.
    final youtube = _isTrailer ||
        (widget.youtubeKey != null && widget.youtubeKey!.isNotEmpty);
    // Windows streams: software decode — d3d11va(+copy) still hard-crashes
    // libmpv after buffer fills when seeking. Local files keep copy-mode HW.
    final hwdec = youtube
        ? 'no'
        : isAndroid
            ? 'mediacodec'
            : isWindows
                ? (widget.isStream ? 'no' : 'd3d11va-copy,auto')
                : isMacOS
                    ? 'videotoolbox,auto'
                    : 'vaapi,auto-safe';
    native.setProperty('hwdec', hwdec);
    if (youtube) {
      native.setProperty('vd-lavc-dr', 'no');
      native.setProperty('hwdec-codecs', 'no');
    }
    if (isAndroid) {
      // display-resample + interpolation desyncs audio on Android TV.
      native.setProperty('video-sync', 'audio');
      native.setProperty('interpolation', 'no');
      native.setProperty('audio-pitch-correction', 'yes');
    } else {
      // Safer defaults on desktop — display-resample + heavy interpolation OOMs some GPUs.
      native.setProperty('video-sync', 'audio');
      native.setProperty('interpolation', 'no');
      native.setProperty('audio-pitch-correction', 'yes');
    }
    // Keep prefetching while paused so resume is smooth (mpv still demuxes into cache).
    native.setProperty('cache', 'yes');
    native.setProperty('demuxer-thread', 'yes');
    // Cap demuxer RAM — 512MiB was crashing Windows while streaming.
    final demuxCap = widget.isStream
        ? (isWindows || isMacOS ? '96MiB' : '192MiB')
        : (isWindows || isMacOS ? '64MiB' : '128MiB');
    native.setProperty('demuxer-max-bytes', demuxCap);
    native.setProperty('demuxer-max-back-bytes', '32MiB');
    // Keep readahead modest for streams so seeks don't wait for a huge demuxer fill.
    native.setProperty('demuxer-readahead-secs', widget.isStream ? '20' : '120');
    native.setProperty('cache-secs', widget.isStream ? '30' : '120');
    // Don't auto-pause on underrun for torrents — that looked like random
    // pause/resume and fought with our old stall-recovery loop.
    native.setProperty('cache-pause', widget.isStream ? 'no' : 'yes');
    if (!widget.isStream) {
      native.setProperty('cache-pause-wait', '3');
    }
    // Accurate seeks while paused are nice, but hr-seek=yes + D3D11VA hard-crashes
    // Windows on scrub. Keyframe seeks are stable; other desktops keep accurate seeks.
    native.setProperty('hr-seek', isWindows ? 'no' : 'yes');
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

  /// Linux/desktop streams: if buffering hangs with a known position, seek back
  /// to [_lastGoodPos] and resume instead of staying frozen until the user hits
  /// play (which often restarts at t=0 after keep-open EOF).
  void _armBufferStallWatch() {
    _bufferStallTimer?.cancel();
    if (!widget.isStream || _useVlc || _useExo) return;
    // Windows: automatic recover-seeks during buffer stalls crash libmpv.
    if (!kIsWeb && Platform.isWindows) return;
    _bufferStallTimer = Timer(const Duration(seconds: 12), () {
      if (!mounted || !_buffering) return;
      final player = _player;
      if (player == null || _seeking) return;
      final recover = _lastGoodPos;
      if (recover.inMilliseconds < 2000) return;
      unawaited(() async {
        try {
          _seekIgnoreUntil = DateTime.now().add(const Duration(milliseconds: 2500));
          await player.seek(recover);
          await player.play();
          if (mounted) {
            setState(() {
              _buffering = true;
              _playing = true;
            });
            _bumpChrome();
          }
        } catch (_) {}
      }());
    });
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
    if (_useVlc) {
      if (!_vlcStarted) return;
      if (_playing) {
        setState(() => _playing = false);
        unawaited(AndroidPlayback.nativeVlcPause());
        _onPausedKeepBuffering();
        _bumpChrome();
      } else {
        setState(() => _playing = true);
        unawaited(AndroidPlayback.nativeVlcPlay());
      }
      return;
    }
    if (_useExo) {
      final exo = _exo;
      if (exo == null || !exo.value.isInitialized) return;
      if (exo.value.isPlaying) {
        setState(() => _playing = false);
        exo.pause();
        _onPausedKeepBuffering();
        _bumpChrome();
      } else {
        setState(() => _playing = true);
        exo.play();
      }
      return;
    }
    final player = _player;
    if (player == null) return;
    // Never touch libmpv play/pause until media is open — Windows crashes when
    // play() runs against an empty playlist (custom chrome used to enable early).
    if (widget.isStream && !_streamOpened) return;
    if (player.state.playlist.medias.isEmpty &&
        player.state.duration <= Duration.zero) {
      return;
    }
    if (player.state.playing) {
      setState(() => _playing = false);
      unawaited(player.pause().then((_) {
        if (!mounted) return;
        _onPausedKeepBuffering();
        _bumpChrome();
      }));
      return;
    }
    setState(() => _playing = true);
    unawaited(player.play());
  }

  /// Keep filling the demuxer / torrent cache while the UI is paused.
  void _onPausedKeepBuffering() {
    // Skip until media is live — early playing:false events used to thrash mpv
    // properties (and OOM Windows stream demux caps).
    if (widget.isStream && !_streamOpened) return;
    final native = _player?.platform;
    if (!_pauseBufferBoosted && native is NativePlayer) {
      _pauseBufferBoosted = true;
      // Modest boost on Windows/macOS streams — 600s + small demux RAM OOMs.
      final secs = widget.isStream
          ? ((!kIsWeb && (Platform.isWindows || Platform.isMacOS)) ? '90' : '180')
          : '120';
      unawaited(native.setProperty('demuxer-readahead-secs', secs));
      unawaited(native.setProperty('cache-secs', secs));
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
    if (!_hasVideo && _player == null && _exo == null && !_vlcStarted) return false;
    // Desktop: don't start a new scrub while libmpv is still filling — that
    // races demuxer/HW and hard-crashes Windows after the first buffer settle.
    if (_useDesktopSafeSeekBar && _buffering && !_seeking) return false;
    if (_useVlc) return _vlcStarted && _vlcReady;
    if (_useExo) {
      final exo = _exo;
      return exo != null && exo.value.isInitialized;
    }
    final player = _player;
    if (player == null) return false;
    // Need a real duration before scrubbing progressive torrents.
    if (widget.isStream && player.state.duration.inMilliseconds < 1000) {
      return false;
    }
    return true;
  }

  bool get _showSeekControls {
    if (_isTrailer) return false;
    // Streams: wait until open so custom play/pause can't hit an empty player.
    if (widget.isStream) {
      return _streamOpened &&
          (_hasVideo || _playing || _vlcStarted || (_exo?.value.isInitialized ?? false));
    }
    return _hasVideo ||
        _player != null ||
        _exo != null ||
        _vlcStarted ||
        (_useVlc && (_streamReady || _streamOpened));
  }

  /// Desktop media_kit: use our onChangeEnd scrubber instead of its drag-seek.
  bool get _useDesktopSafeSeekBar {
    if (_useVlc || _useExo || kIsWeb) return false;
    return Platform.isWindows || Platform.isLinux || Platform.isMacOS;
  }

  int get _currentDurationMs {
    if (_useVlc) return _vlcDuration.inMilliseconds;
    if (_useExo) return _exo?.value.duration.inMilliseconds ?? 0;
    return _player?.state.duration.inMilliseconds ?? 0;
  }

  void _seekRelative(int seconds) {
    unawaited(_seekRelativeAsync(seconds));
  }

  Future<void> _seekRelativeAsync(int seconds) async {
    if (!_canSeek) return;
    Duration pos;
    Duration dur;
    if (_useVlc) {
      pos = _vlcPosition.inMilliseconds > 0 ? _vlcPosition : _lastGoodPos;
      dur = _vlcDuration;
    } else if (_useExo) {
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

  /// Queue a seek. Streams wait 3s to settle; local files seek immediately.
  Future<void> _seekPlayback(Duration target, {bool immediate = false}) async {
    if (target < Duration.zero) target = Duration.zero;
    _lastSeekTarget = target;
    _lastGoodPos = target;
    if (_useVlc) _vlcPosition = target;
    if (mounted) {
      setState(() {
        _buffering = true;
        _seeking = true;
      });
    }
    // Pause while settling so the old frame doesn't keep playing.
    if (widget.isStream) {
      try {
        if (_useVlc) {
          await AndroidPlayback.nativeVlcPause();
        } else if (_useExo) {
          await _exo?.pause();
        } else {
          await _player?.pause();
        }
      } catch (_) {}
    }
    if (widget.isStream && !immediate) {
      _seekCtl.request(target);
      return;
    }
    if (immediate) {
      await _seekCtl.commitNow(target);
    } else {
      await _commitSeekPlayback(target);
    }
  }

  /// Actually seek the player after settle / for non-stream media.
  Future<void> _commitSeekPlayback(Duration target) async {
    final token = ++_seekToken;
    _lastSeekTarget = target;
    _lastGoodPos = target;
    _seekIgnoreUntil = DateTime.now().add(const Duration(milliseconds: 2500));
    if (mounted) {
      setState(() {
        _buffering = true;
        _seeking = true;
      });
      _bumpChrome();
    }

    // Retarget again at commit (in case settle scrub moved further).
    await _retargetStreamBuffer(target);
    if (token != _seekToken) return;

    // Instant play from the new position — do not wait for a full file buffer.
    if (_useVlc) {
      try {
        await AndroidPlayback.nativeVlcSeek(target.inMilliseconds);
        await AndroidPlayback.nativeVlcPlay();
      } catch (_) {}
    } else if (_useExo) {
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
      // Don't flip hr-seek / demuxer props mid-seek — unlocked setProperty races
      // the seek command and hard-crashes libmpv on Windows.
      try {
        // Brief pause lets the demuxer drop in-flight reads before the seek.
        if (!kIsWeb && Platform.isWindows) {
          try {
            await player.pause();
          } catch (_) {}
          await Future<void>.delayed(const Duration(milliseconds: 80));
          if (token != _seekToken) return;
        }
        await player.seek(target);
        if (token != _seekToken) return;
        await Future<void>.delayed(
          Duration(milliseconds: (!kIsWeb && Platform.isWindows) ? 120 : 0),
        );
        if (token != _seekToken) return;
        await player.play();
      } catch (_) {}
    }

    Future<void>.delayed(const Duration(milliseconds: 2000), () {
      if (!mounted || token != _seekToken) return;
      if (_seeking) setState(() => _seeking = false);
    });
    if (widget.isStream) unawaited(_pollStream());
    if (mounted) setState(() {});
  }

  /// Move local torrent download window to [target].
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
      LocalTorrentEngine.instance.seekTo(
        positionMs: target.inMilliseconds,
        durationMs: _currentDurationMs > 0 ? _currentDurationMs : null,
      );
    }
  }

  @override
  void deactivate() {
    playbackSessionActive = false;
    ref.read(settingsProvider.notifier).flushPendingUnauthorized();
    super.deactivate();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Flush resume position on background / kill so Continue watching stays accurate.
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(_saveProgress(
        invalidateHome: state == AppLifecycleState.detached ||
            state == AppLifecycleState.paused,
      ));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    playbackSessionActive = false;
    ref.read(settingsProvider.notifier).flushPendingUnauthorized();
    HardwareKeyboard.instance.removeHandler(_onHardwareKey);
    _posSub?.cancel();
    _completedSub?.cancel();
    _tracksSub?.cancel();
    _bufferingSub?.cancel();
    _bufferSub?.cancel();
    _streamPoll?.cancel();
    _playNextTick?.cancel();
    _pauseBufferTimer?.cancel();
    _bufferStallTimer?.cancel();
    _chromeHideTimer?.cancel();
    _exoFrameWatch?.cancel();
    _overlayEpoch.dispose();
    _rootFocus.dispose();
    _backFocus.dispose();
    _audioFocus.dispose();
    _subsFocus.dispose();
    _rewindFocus.dispose();
    _playFocus.dispose();
    _forwardFocus.dispose();
    _skipFocus.dispose();
    _playNextFocus.dispose();
    _seekCtl.dispose();
    unawaited(_vlcSub?.cancel() ?? Future<void>.value());
    _vlcSub = null;
    if (!_playerReleased) {
      final position = _useVlc
          ? _vlcPosition
          : _useExo
              ? _exo?.value.position
              : _player?.state.position;
      final duration = _useVlc
          ? _vlcDuration
          : _useExo
              ? _exo?.value.duration
              : _player?.state.duration;
      unawaited(_saveProgress(
        position: position,
        duration: duration,
        closing: true,
        invalidateHome: true,
      ));
      _exo?.removeListener(_onExoTick);
      unawaited(_exo?.dispose());
      if (_vlcStarted) {
        unawaited(AndroidPlayback.stopNativeVlc());
        _vlcStarted = false;
      }
      try {
        _player?.dispose();
      } catch (_) {}
      _player = null;
      _controller = null;
      _exo = null;
      // Prefer the explicit stop in _closePlayer; keep dispose as a safety net.
      if (!_closing) {
        unawaited(_releaseStreamResources(wipeIfEnabled: true));
      }
    }
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  /// Stop torrent / stream; wipe pieces when Settings → Clear cache on exit is on.
  Future<void> _releaseStreamResources({required bool wipeIfEnabled}) async {
    final wipe = wipeIfEnabled && ref.read(settingsProvider).clearCacheOnExit;
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
    final localActive = widget.localTorrent ||
        (widget.isStream && (sessionId?.startsWith('local-') ?? false)) ||
        LocalTorrentEngine.instance.isActive;
    if (!localActive && !wipe) return;
    try {
      if (wipe) {
        await LocalTorrentEngine.instance.purgeDownloads();
        await PlayerCache.clear();
      } else if (localActive) {
        await LocalTorrentEngine.instance.stop(deleteFiles: false);
      }
    } catch (_) {}
  }

  Future<void> _disposePlaybackEngines() async {
    if (_playerReleased) return;
    _playerReleased = true;
    final player = _player;
    final exo = _exo;
    final vlc = _vlcStarted;
    _player = null;
    _controller = null;
    _exo = null;
    _vlcStarted = false;
    // Unmount Video/Texture before native dispose — avoids desktop leave crashes.
    if (mounted) {
      try {
        setState(() {});
      } catch (_) {}
      await Future<void>.delayed(Duration.zero);
    }
    try {
      await player?.pause();
    } catch (_) {}
    try {
      await player?.dispose();
    } catch (_) {}
    try {
      await exo?.pause();
    } catch (_) {}
    try {
      exo?.removeListener(_onExoTick);
    } catch (_) {}
    try {
      await exo?.dispose();
    } catch (_) {}
    if (vlc) {
      try {
        await AndroidPlayback.stopNativeVlc();
      } catch (_) {}
    }
  }

  Future<void> _closePlayer() async {
    if (_closing) return;
    _closing = true;
    _playNextTick?.cancel();
    _pauseBufferTimer?.cancel();
    try {
      await _saveProgress(closing: true, invalidateHome: true)
          .timeout(const Duration(seconds: 2), onTimeout: () {});
    } catch (_) {}
    await _disposePlaybackEngines();
    await _releaseStreamResources(wipeIfEnabled: true);
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
        : now.difference(_lastProgress) >= const Duration(seconds: 5);
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
        if (hit != null &&
            (hit.kind == 'INTRO' || hit.kind == 'RECAP') &&
            DeviceProfile.current.prefersDpad) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _skipFocus.canRequestFocus) {
              _skipFocus.requestFocus();
            }
          });
        }
      }
    }
  }

  int _playbackDurationMs() {
    if (_useVlc) return _vlcDuration.inMilliseconds;
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

  bool get _showChrome => _chromeVisible;

  /// True when this player route is the top route (no Settings / overlays).
  bool get _playerRouteIsCurrent {
    if (!mounted) return false;
    final route = ModalRoute.of(context);
    return route?.isCurrent ?? true;
  }

  /// Reveal seek / audio / subtitle chrome; restart the auto-hide timer.
  void _bumpChrome() {
    if (!_playerRouteIsCurrent) return;
    _chromeHideTimer?.cancel();
    if (!_chromeVisible) {
      if (mounted) setState(() => _chromeVisible = true);
    }
    _armChromeHideTimer();
  }

  void _armChromeHideTimer() {
    _chromeHideTimer?.cancel();
    _chromeHideTimer = Timer(const Duration(seconds: _chromeHideSecs), () {
      if (!mounted || !_playerRouteIsCurrent) return;
      // Keep chrome while a control is focused — reschedule silently (no setState).
      if (_chromeControlFocused) {
        _armChromeHideTimer();
        return;
      }
      setState(() => _chromeVisible = false);
      if (!_rootFocus.hasFocus) _rootFocus.requestFocus();
    });
  }

  void _pauseChromeForOverlay() {
    _chromeHideTimer?.cancel();
    _chromeHideTimer = null;
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
    if (DeviceProfile.current.prefersDpad) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _playNextFocus.canRequestFocus) {
          _playNextFocus.requestFocus();
        }
      });
    }
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

      // Clear the finished episode's pieces when the setting is on — before the next magnet.
      final wipe = ref.read(settingsProvider).clearCacheOnExit;
      try {
        if (wipe) {
          await LocalTorrentEngine.instance.stop(deleteFiles: true);
          await PlayerCache.clear();
        } else {
          await LocalTorrentEngine.instance.stop(deleteFiles: false);
        }
      } catch (_) {}

      final previousSession = widget.sessionId;
      var opened = false;
      // Next episode is a fresh play — always pick a torrent (don't reuse prior ep magnet).
      final started = await beginStreaming(
        context: context,
        client: ref.read(graphQLClientProvider),
        title: next.catalogTitle,
        kind: next.kind,
        titleId: widget.titleId,
        season: next.season,
        episode: next.episode,
        preferredLanguages: ref.read(serverInfoProvider).valueOrNull?.preferredLanguages ??
            ref.read(settingsProvider).preferredLanguages,
        preferResume: false,
        fromBeginning: true,
        resumePlayback: false,
        stopPreviousSessionId: previousSession,
        onReadyToPlay: (s) {
          if (!mounted) return;
          opened = true;
          setState(() => _playNextDismissed = true);
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
      final pos = _useVlc
          ? _vlcPosition.inMilliseconds
          : _useExo
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
    await _seekPlayback(target, immediate: true);
    // Keep playing after the skip — progressive streams can pause on seek.
    try {
      if (_useVlc) {
        await AndroidPlayback.nativeVlcPlay();
      } else if (_useExo) {
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
        (_useVlc
            ? _vlcPosition
            : _useExo
                ? _exo?.value.position
                : player?.state.position) ??
        Duration.zero;
    final dur = duration ??
        (_useVlc
            ? _vlcDuration
            : _useExo
                ? _exo?.value.duration
                : player?.state.duration);
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
              'season': widget.season,
              'episode': widget.episode,
              'fileIndex': widget.streamFileIndex,
            },
          ),
        );
      }
    } catch (_) {}
    if ((complete || invalidateHome) && mounted) {
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
    _wyzieHits = const [];
    if (mounted) setState(() => _buffering = true);

    // Device-side torrent: this device fetches pieces. Backend is not involved.
    // Also treat local-* session ids — route extras sometimes drop localTorrent.
    final isLocal = widget.localTorrent ||
        (widget.sessionId?.startsWith('local-') ?? false);
    if (isLocal) {
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
        // Refresh trackers from server before magnet announce (macOS/desktop).
        final trackers =
            ref.read(serverInfoProvider).valueOrNull?.streamTrackers ?? const [];
        if (trackers.isNotEmpty) {
          LocalTorrentEngine.instance.configureTrackers(trackers);
        }
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
                status: local.ready || local.torrentComplete ? 'ready' : 'buffering',
                streamUrl: _url,
              );
            });
            if (!_streamOpened &&
                _url.isNotEmpty &&
                (local.ready || local.torrentComplete)) {
              _streamReady = true;
              unawaited(_tryOpenPreparedStream());
            }
          },
        );
        if (!mounted) return;
        _url = handle.url;
        _streamReady = true;
        // Retry a few times — native player may still be attaching.
        for (var i = 0; i < 8 && mounted && !_streamOpened; i++) {
          await _tryOpenPreparedStream();
          if (_streamOpened) break;
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
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

    final deadline = DateTime.now().add(const Duration(seconds: 210));
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

    _url = _rewriteMediaUrl(session.streamUrl);
    _streamReady = true;
    await _tryOpenPreparedStream();
  }

  /// Open media once both the torrent URL and the native player exist.
  Future<void> _tryOpenPreparedStream() async {
    if (!widget.isStream || !_streamReady || _streamOpened || !mounted) return;
    if (_url.isEmpty) return;
    if (!_useExo && !_useVlc && _player == null) return;
    await _open(_url, fileId: _fileId);
    if (!mounted) return;
    if (!_useExo && !_useVlc) {
      await _player?.play();
    }
    if (!mounted) return;
    setState(() {
      _streamOpened = true;
      _streamError = null;
      _buffering = true;
    });
  }

  Future<void> _pollStream() async {
    if (!widget.isStream || !mounted) return;

    // Only treat as local when this screen owns a device-side torrent.
    // A leftover LocalTorrentEngine.isActive must not block remote streamStatus.
    if (widget.localTorrent || (widget.sessionId?.startsWith('local-') ?? false)) {
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
          status: local.ready || local.torrentComplete ? 'ready' : 'buffering',
          streamUrl: _url,
        );
      });
      // Fully buffered / ready but player never opened (common when the
      // download finishes before MediaKit/Exo attaches) — open now.
      if (!_streamOpened &&
          _url.isNotEmpty &&
          (local.ready ||
              local.torrentComplete ||
              local.bufferPct >= 99.0)) {
        _streamReady = true;
        unawaited(_tryOpenPreparedStream());
      }
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
      final session = StreamSession.fromJson(json);
      final rewritten = session.streamUrl.isEmpty
          ? session
          : StreamSession(
              id: session.id,
              title: session.title,
              progress: session.progress,
              bufferProgress: session.bufferProgress,
              downloadMbps: session.downloadMbps,
              seeders: session.seeders,
              peers: session.peers,
              resumePosition: session.resumePosition,
              status: session.status,
              streamUrl: _rewriteMediaUrl(session.streamUrl),
            );
      setState(() => _streamInfo = rewritten);
      if (!_streamReady && rewritten.isReady && rewritten.streamUrl.isNotEmpty) {
        _url = rewritten.streamUrl;
        _streamReady = true;
        unawaited(_tryOpenPreparedStream());
      }
      debugPrint(
        'PeanutButter streamStatus '
        'status=${rewritten.status} peers=${rewritten.peers} '
        'mbps=${rewritten.downloadMbps.toStringAsFixed(2)} '
        'buf=${(rewritten.bufferProgress * 100).toStringAsFixed(1)}%',
      );    } catch (_) {}
  }

  bool get _hasVideo {
    if (_useVlc) {
      return _vlcReady && (_playing || _vlcPosition > Duration.zero || _streamOpened);
    }
    if (_useExo) {
      final exo = _exo;
      if (exo == null || !exo.value.isInitialized || exo.value.hasError) return false;
      // Size OR active playback — PlatformView on Realtek sometimes reports 0×0
      // briefly while frames are already on the SurfaceView.
      return exo.value.size.width > 1 ||
          exo.value.isPlaying ||
          (exo.value.position > Duration.zero && _streamOpened);
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
    // Poster / peer HUD only before first open — mid-play rebuffers use the
    // corner chip so the torrent bar never stacks on media_kit's seekbar.
    if (!_streamOpened) return true;
    if (!_hasVideo && !_playing) return true;
    return false;
  }

  /// Compact seed/speed chip while streaming mid-play — never alongside the HUD.
  bool get _showStreamChip =>
      widget.isStream &&
      _streamError == null &&
      !_showStreamHud &&
      (_hasVideo || _streamOpened) &&
      (_buffering || _seeking || _seekSettling || !_playing);

  /// Movie / series name + episode line shown while paused.
  String get _pauseTitleMain {
    final catalog = widget.catalogTitle?.trim();
    if (catalog != null && catalog.isNotEmpty) return catalog;
    return widget.title;
  }

  String? get _pauseTitleEpisode {
    if (widget.season == null || widget.episode == null) return null;
    final code =
        'S${widget.season!.toString().padLeft(2, '0')}E${widget.episode!.toString().padLeft(2, '0')}';
    final raw = widget.title.trim();
    final main = _pauseTitleMain;
    if (raw.isNotEmpty && raw != main && !raw.startsWith(main)) {
      return '$code  ·  $raw';
    }
    return code;
  }

  /// Title sits to the right of Back — no gradient panel.
  Widget _playerTitleChrome() {
    final episode = _pauseTitleEpisode;
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.only(left: 4, right: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _pauseTitleMain,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w600,
                height: 1.15,
                shadows: [Shadow(blurRadius: 8, color: Colors.black87)],
              ),
            ),
            if (episode != null)
              Text(
                episode,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.85),
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  shadows: const [Shadow(blurRadius: 6, color: Colors.black87)],
                ),
              ),
          ],
        ),
      ),
    );
  }

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
    if (_useVlc) {
      await _openVlc(url, headers);
      return;
    }
    if (_useExo) {
      await _openExo(url, headers);
      return;
    }
    final native = _player?.platform;
    if (native is NativePlayer) {
      // Clear any leftover external-audio binding from older builds.
      await native.setProperty('audio-files', '');
      if (isYoutube) {
        // HW decode of progressive googlevideo often paints a solid blue frame.
        await native.setProperty('hwdec', 'no');
        await native.setProperty('vd-lavc-dr', 'no');
        await native.setProperty(
          'demuxer-lavf-o',
          'protocol_whitelist=file,http,https,tcp,tls,crypto,data',
        );
      }
    }
    await _player?.open(Media(url, httpHeaders: headers));
    if (widget.startMs > 0) {
      try {
        await _player!.stream.duration.firstWhere((d) => d.inMilliseconds > 0).timeout(const Duration(seconds: 20));
      } catch (_) {}
      await _seekPlayback(Duration(milliseconds: widget.startMs), immediate: true);
    }
  }

  Future<void> _openVlc(String url, Map<String, String> headers) async {
    if (mounted) {
      setState(() {
        _buffering = true;
        _streamError = null;
        _vlcReady = false;
        _vlcTextureId = null;
      });
    }
    final playUrl = AndroidPlayback.urlWithAuth(url, ref.read(settingsProvider).apiToken);
    final textureId = await AndroidPlayback.startNativeVlc(
      url: playUrl,
      startMs: widget.startMs,
      headers: headers,
    );
    _vlcStarted = textureId != null;
    _vlcTextureId = textureId;
    if (!mounted) return;
    if (textureId == null) {
      setState(() {
        _buffering = false;
        _streamError = 'Couldn’t start the in-app VLC player on this device.';
      });
      return;
    }
    setState(() {
      _streamOpened = true;
      _buffering = true;
      _vlcTextureId = textureId;
    });
  }

  void _onVlcEvent(Map<String, dynamic> event) {
    if (!mounted) return;
    final kind = event['event']?.toString() ?? '';
    final pos = event['position'];
    final dur = event['duration'];
    if (pos is num) {
      _vlcPosition = Duration(milliseconds: pos.toInt());
      _onPosition(_vlcPosition);
    }
    if (dur is num && dur.toInt() > 0) {
      _vlcDuration = Duration(milliseconds: dur.toInt());
    }
    switch (kind) {
      case 'opening':
        setState(() {
          _buffering = true;
          _streamError = null;
        });
      case 'layout':
        final lw = event['width'];
        final lh = event['height'];
        setState(() {
          if (lw is num) _vlcVideoW = lw.toInt();
          if (lh is num) _vlcVideoH = lh.toInt();
        });
      case 'playing':
      case 'vout':
        setState(() {
          _vlcReady = true;
          _playing = true;
          _buffering = false;
          _streamOpened = true;
          _streamError = null;
          _seeking = false;
          final w = event['width'];
          final h = event['height'];
          if (w is num && w.toInt() > 0) _vlcVideoW = w.toInt();
          if (h is num && h.toInt() > 0) _vlcVideoH = h.toInt();
        });
        final durMs = _vlcDuration.inMilliseconds;
        if (durMs > 30000 &&
            (!_segmentsFetched ||
                (_lastSegmentFetchDuration >= 0 &&
                    (durMs - _lastSegmentFetchDuration).abs() > 5000))) {
          unawaited(_loadMediaSegments(durationMs: durMs));
        }
      case 'paused':
        setState(() => _playing = false);
      case 'buffering':
        final b = event['buffering'];
        final pct = b is num ? b.toDouble() : 0.0;
        final vlcPlaying = event['playing'] == true;
        setState(() {
          if (vlcPlaying) _playing = true;
          if (event['playing'] == false) _playing = false;
          // libVLC often sits at ~99% forever on progressive torrents even
          // while frames are decoding — treat near-full / playing as ready.
          if (vlcPlaying || _playing || pct >= 99.0 || (_vlcReady && pct >= 90)) {
            _buffering = false;
            _vlcReady = true;
            if (pct >= 90 || vlcPlaying) _streamOpened = true;
          } else {
            _buffering = true;
          }
        });
        if (_buffering) _bumpChrome();
      case 'timeChanged':
        setState(() {
          // Prefer the native flag — `|| _playing` kept pause stuck as "playing"
          // so the title overlay never appeared.
          if (event.containsKey('playing')) {
            _playing = event['playing'] == true;
          }
          if (_playing) {
            _vlcReady = true;
            // Buffering flag is owned by Buffering events — clearing it here
            // hid the download stats HUD during mid-play rebuffers.
            _seeking = false;
          }
        });
      case 'tracks':
        _ingestVlcTracks(event);
      case 'ended':
        setState(() => _playing = false);
        unawaited(_saveProgress(
          position: _vlcPosition,
          duration: _vlcDuration,
          complete: true,
        ));
        if (widget.isStream && _nextEpisode != null && !_playNextDismissed) {
          _armPlayNextPrompt(force: true);
        } else {
          unawaited(_endPlaybackAndExit());
        }
      case 'error':
        setState(() {
          _streamError = event['message']?.toString() ?? 'libVLC playback error';
          _buffering = false;
          _playing = false;
        });
      case 'stopped':
        setState(() => _playing = false);
    }
  }

  void _ingestVlcTracks(Map<String, dynamic> event) {
    List<_VlcTrack> parse(dynamic raw) {
      if (raw is! List) return const [];
      return raw
          .whereType<Map>()
          .map((e) {
            final id = e['id'];
            final name = e['name']?.toString() ?? 'Track';
            final n = id is num ? id.toInt() : int.tryParse('$id') ?? -999;
            return _VlcTrack(id: n, label: name);
          })
          .where((t) => t.id != -999)
          .toList();
    }

    final audio = parse(event['audio']);
    final spu = parse(event['spu']).where((t) => t.id >= 0).toList();
    final audioId = event['audioId'];
    final spuId = event['spuId'];
    setState(() {
      _vlcAudio = audio;
      _vlcSpu = spu;
      if (audioId is num) _activeAudioId = '${audioId.toInt()}';
      if (spuId is num && spuId.toInt() >= 0) {
        _activeSubId = 'vlc:${spuId.toInt()}';
      }
    });
    if (!_audioLanguagePicked && audio.isNotEmpty) {
      unawaited(_applyPreferredVlcAudio(audio));
    }
  }

  Future<void> _applyPreferredVlcAudio(List<_VlcTrack> audio) async {
    if (_audioLanguagePicked || audio.isEmpty) return;
    final preferred = preferredLanguageCodes(
      ref.read(serverInfoProvider).valueOrNull?.preferredLanguages ??
          ref.read(settingsProvider).preferredLanguages,
    );
    if (preferred.isEmpty) return;
    _VlcTrack? match;
    for (final code in preferred) {
      for (final track in audio) {
        final label = track.label.toLowerCase();
        if (label.contains(code) ||
            label.contains(languageDisplayName(code).toLowerCase())) {
          match = track;
          break;
        }
      }
      if (match != null) break;
    }
    if (match == null) return;
    await AndroidPlayback.nativeVlcSetAudioTrack(match.id);
    if (!mounted) return;
    _audioLanguagePicked = true;
    setState(() => _activeAudioId = '${match!.id}');
  }

  Future<void> _openExo(String url, Map<String, String> headers) async {
    final previous = _exo;
    previous?.removeListener(_onExoTick);
    _exoFrameWatch?.cancel();
    _exoOpenUrl = url;
    _exoOpenHeaders = headers;
    // Popcorn/Butter TV attached VLC to Leanback's native SurfaceView.
    // On physical ARM TVs, Flutter TextureView often stays black for HEVC while
    // PlatformView (SurfaceView) actually paints. Emulator keeps TextureView —
    // PlatformView + Flutter embedding is flaky there, and D-pad is fine either way
    // now that we no longer swallow unhandled keys.
    final usePlatformSurface =
        isAndroidTv && TvDevice.ready && !TvDevice.isEmulator;
    final next = VideoPlayerController.networkUrl(
      Uri.parse(url),
      httpHeaders: headers,
      videoPlayerOptions: VideoPlayerOptions(mixWithOthers: false),
      viewType:
          usePlatformSurface ? VideoViewType.platformView : VideoViewType.textureView,
    );
    next.addListener(_onExoTick);
    _exo = next;
    await previous?.dispose();
    if (mounted) setState(() => _buffering = true);
    try {
      await next.initialize();
      if (next.value.hasError) {
        throw next.value.errorDescription ?? 'Video player error';
      }
      if (widget.startMs > 0) {
        await next.seekTo(Duration(milliseconds: widget.startMs));
      }
      await next.play();
      if (mounted) {
        setState(() {
          _buffering = false;
          _streamOpened = true;
          _streamError = null;
        });
      }
      _armExoFrameWatch();
    } catch (e) {
      debugPrint('PeanutButter Exo open failed: $e');
      if (!mounted) return;
      await _fallbackExoToMediaKit(url, headers, reason: e.toString());
    }
  }

  void _armExoFrameWatch() {
    _exoFrameWatch?.cancel();
    // Exo can "succeed" with a black TextureView on some SoCs. PlatformView may
    // paint without reporting size — only fall back to MediaKit when clearly dead
    // (MediaKit Player() SIGSEGVs on BeyondTV/rtd285o if forced too early).
    _exoFrameWatch = Timer(const Duration(seconds: 6), () {
      if (!mounted || !_useExo) return;
      final exo = _exo;
      if (exo == null || !exo.value.isInitialized) return;
      final size = exo.value.size;
      if (size.width > 1 && size.height > 1) return;
      if (exo.value.isPlaying && exo.value.position > const Duration(seconds: 2)) {
        return; // Surface likely painting without size metadata
      }
      final url = _exoOpenUrl;
      final headers = _exoOpenHeaders;
      if (url == null || headers == null) return;
      debugPrint(
        'PeanutButter Exo produced no frames (${size.width}x${size.height}) — MediaKit fallback',
      );
      unawaited(_fallbackExoToMediaKit(url, headers, reason: 'no video frames'));
    });
  }

  Future<void> _fallbackExoToMediaKit(
    String url,
    Map<String, String> headers, {
    String? reason,
  }) async {
    _exoFrameWatch?.cancel();
    final doomed = _exo;
    doomed?.removeListener(_onExoTick);
    try {
      await doomed?.dispose();
    } catch (_) {}
    if (identical(_exo, doomed)) _exo = null;
    _useExoFallbackMediaKit = true;
    // Soft-wait for libmpv; never block forever on Realtek load hangs.
    if (!kIsWeb && Platform.isAndroid) {
      try {
        await MediaKitAndroidVideo.preload()
            .timeout(const Duration(seconds: 12));
      } catch (_) {}
    }
    _initMediaKitPlayer();
    if (_player == null) {
      if (mounted) {
        setState(() {
          _buffering = false;
          _streamError =
              'Couldn’t play video on this TV.${reason != null ? '\n$reason' : ''}';
        });
      }
      return;
    }
    try {
      await _open(url, fileId: _fileId);
      if (mounted) {
        setState(() {
          _buffering = false;
          _streamOpened = true;
          _streamError = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _buffering = false;
          _streamError = 'Couldn’t play video on this TV.\n$e';
        });
      }
    }
  }

  void _onExoTick() {
    final exo = _exo;
    if (exo == null || !mounted) return;
    final v = exo.value;
    if (v.size.width > 1 && v.size.height > 1) {
      _exoFrameWatch?.cancel();
      _exoFrameWatch = null;
    }
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

  Future<void> _loadOpenSubtitles({required String language, bool applyFirst = true}) async {
    final titleId = widget.titleId;
    if (_fileId == 'trailer' || titleId == null) return;
    final fileId = widget.isStream || !_isUuid(_fileId) ? null : _fileId;
    setState(() => _subsLoading = true);
    try {
      final client = ref.read(graphQLClientProvider);
      final result = await client.mutate(
        MutationOptions(
          document: gql(FETCH_SUBTITLES),
          variables: {
            'titleId': titleId,
            'language': language,
            'season': widget.season,
            'episode': widget.episode,
            'fileId': fileId,
          },
        ),
      );
      if (!mounted) return;
      if (result.hasException) {
        setState(() => _subsLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(graphqlMessage(result))),
        );
        return;
      }
      final rows = (result.data?['fetchSubtitles'] as List?) ?? const [];
      final next = rows
          .whereType<Map<String, dynamic>>()
          .map(
            (e) => _SubtitleOption(
              id: e['id'] as String? ?? '',
              language: e['language'] as String? ?? language,
              label: e['label'] as String? ?? 'Subtitle',
              content: e['content'] as String? ?? '',
              source: 'opensubtitles',
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
      if (applyFirst && next.isNotEmpty) {
        final match = next.where((s) => s.language == language);
        await _applySubtitle(match.isNotEmpty ? match.first : next.first);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _subsLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  /// Wyzie: search by TMDB + language — results stay in the subtitle menu.
  Future<List<_SubtitleOption>> _searchWyzieSubtitles(String language) async {
    final titleId = widget.titleId;
    if (_fileId == 'trailer' || titleId == null) return const [];
    setState(() => _subsLoading = true);
    try {
      final client = ref.read(graphQLClientProvider);
      final result = await client.mutate(
        MutationOptions(
          document: gql(SEARCH_SUBTITLES),
          variables: {
            'titleId': titleId,
            'language': language,
            'season': widget.season,
            'episode': widget.episode,
          },
        ),
      );
      if (!mounted) return const [];
      if (result.hasException) {
        setState(() {
          _subsLoading = false;
          _wyzieHits = const [];
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(graphqlMessage(result))),
        );
        return const [];
      }
      final rows = (result.data?['searchSubtitles'] as List?) ?? const [];
      final hits = rows
          .whereType<Map<String, dynamic>>()
          .map(
            (e) => _SubtitleOption(
              id: e['id'] as String? ?? '',
              language: e['language'] as String? ?? language,
              label: e['label'] as String? ?? 'Subtitle',
              content: '',
              downloadUrl: e['downloadUrl'] as String?,
              source: e['source'] as String? ?? 'wyzie',
            ),
          )
          .where((e) => e.downloadUrl != null && e.downloadUrl!.isNotEmpty)
          .toList();
      setState(() {
        _wyzieHits = hits;
        _subsLoading = false;
      });
      if (hits.isEmpty && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No Wyzie captions for this title.')),
        );
      }
      return hits;
    } catch (e) {
      if (mounted) {
        setState(() {
          _subsLoading = false;
          _wyzieHits = const [];
        });
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
      return const [];
    }
  }

  Future<void> _downloadAndApplySubtitle(_SubtitleOption hit) async {
    final url = hit.downloadUrl;
    if (url == null || url.isEmpty) return;
    setState(() => _subsLoading = true);
    try {
      final client = ref.read(graphQLClientProvider);
      final result = await client.mutate(
        MutationOptions(
          document: gql(DOWNLOAD_SUBTITLE),
          variables: {
            'downloadUrl': url,
            'language': hit.language,
            'label': hit.label,
            'format': 'srt',
            'source': hit.source ?? 'wyzie',
          },
        ),
      );
      if (!mounted) return;
      if (result.hasException) {
        setState(() => _subsLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(graphqlMessage(result))),
        );
        return;
      }
      final row = result.data?['downloadSubtitle'] as Map<String, dynamic>?;
      final content = row?['content'] as String? ?? '';
      if (!content.contains('-->')) {
        setState(() => _subsLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('That subtitle file was empty.')),
        );
        return;
      }
      final loaded = _SubtitleOption(
        id: row?['id'] as String? ?? hit.id,
        language: row?['language'] as String? ?? hit.language,
        label: row?['label'] as String? ?? hit.label,
        content: content,
        source: hit.source ?? 'wyzie',
      );
      setState(() {
        _subs = [
          for (final s in _subs)
            if (s.id == hit.id) loaded else s,
        ];
        if (!_subs.any((s) => s.id == loaded.id)) _subs = [..._subs, loaded];
        _subsLoading = false;
      });
      await _applySubtitle(loaded);
    } catch (e) {
      if (mounted) {
        setState(() => _subsLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  Future<void> _pickSubtitleLanguage(String code) async {
    if (code == 'off') {
      await _disableSubtitles();
      return;
    }
    final existing = _subs.where((s) => s.id == code);
    if (existing.isNotEmpty) {
      final sub = existing.first;
      if (sub.needsDownload) {
        await _downloadAndApplySubtitle(sub);
      } else {
        await _applySubtitle(sub);
      }
      return;
    }
    await _loadOpenSubtitles(language: code);
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
    if (_useVlc) {
      try {
        final dir = await Directory.systemTemp.createTemp('pb_sub_');
        final file = File('${dir.path}/${sub.id}.srt');
        await file.writeAsString(sub.content);
        final ok = await AndroidPlayback.nativeVlcAddSubtitle(file.uri.toString());
        if (ok && mounted) setState(() => _activeSubId = sub.id);
      } catch (e) {
        debugPrint('PeanutButter VLC subtitle failed: $e');
      }
      return;
    }
    await _player?.setSubtitleTrack(
      SubtitleTrack.data(sub.content, title: sub.label, language: sub.language),
    );
    if (mounted) setState(() => _activeSubId = sub.id);
  }

  Future<void> _disableSubtitles() async {
    if (_useVlc) {
      await AndroidPlayback.nativeVlcSetSpuTrack(-1);
      if (mounted) setState(() => _activeSubId = null);
      return;
    }
    await _player?.setSubtitleTrack(SubtitleTrack.no());
    if (mounted) setState(() => _activeSubId = null);
  }

  /// Collect OpenSubtitles API key without leaving the player (avoids chrome blink).
  Future<void> _promptOpenSubtitlesKey() async {
    _pauseChromeForOverlay();
    String? key;
    try {
      if (DeviceProfile.current.usesSoftKeyboardOverlay) {
        key = await InputPolicy.forProfile(DeviceProfile.current).editText(
          context,
          title: 'OpenSubtitles API key',
          hint: 'Paste your API key',
          obscureText: true,
          keyboardType: TextInputType.visiblePassword,
          textInputAction: TextInputAction.done,
        );
      } else {
        final controller = TextEditingController();
        key = await showDialog<String>(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: PtTheme.panel,
            title: const Text('OpenSubtitles API key'),
            content: TextField(
              controller: controller,
              obscureText: true,
              autofocus: true,
              decoration: const InputDecoration(
                hintText: 'Paste your API key',
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
              ),
              onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cancel')),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
                child: const Text('Save'),
              ),
            ],
          ),
        );
        controller.dispose();
      }
      if (key == null || key.trim().isEmpty || !mounted) return;
      final client = ref.read(graphQLClientProvider);
      final result = await client.mutate(
        MutationOptions(
          document: gql(UPDATE_SETTINGS),
          variables: {
            'input': {
              'opensubtitlesEnabled': true,
              'opensubtitlesApiKey': key.trim(),
            },
          },
        ),
      );
      if (!mounted) return;
      if (result.hasException) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(graphqlMessage(result))),
        );
        return;
      }
      ref.invalidate(serverInfoProvider);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('OpenSubtitles enabled')),
      );
    } finally {
      if (mounted) _bumpChrome();
    }
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
    final speed = info?.downloadMbps ?? local?.downloadMbps ?? 0;
    final peers = info?.peers ?? local?.peers ?? 0;
    final seeders = info?.seeders ?? local?.seeders ?? 0;
    final rawFrac = () {
      final b = info?.bufferProgress ?? 0;
      final p = info?.progress ?? 0;
      // Stream readiness (readahead window) can hit ~1.0 long before the
      // whole torrent finishes — treat that as a full pre-roll bar.
      if (b >= 0.99) return 1.0;
      if (b > 0.001) return b;
      if (p >= 0.99) return 1.0;
      if (p > 0.001) return p;
      return 0.0;
    }();
    final rawPct = (rawFrac * 100).clamp(0.0, 100.0);
    final ready = (info?.status == 'ready') ||
        (local?.ready ?? false) ||
        (local?.torrentComplete ?? false) ||
        rawPct >= 99.5;
    // Don't pin the pre-roll bar at 99% once the stream is ready to open.
    final pct = ready
        ? 100.0
        : ((rawPct >= 99.5 && speed >= 0.05) ? 99.0 : rawPct);
    final barValue = pct > 0 ? (pct / 100).clamp(0.0, 1.0) : null;
    final art = widget.backdropUrl ?? widget.posterUrl;
    final showPoster = art != null && art.isNotEmpty;
    final status = ready
        ? 'Starting playback…'
        : (peers > 0 || seeders > 0
            ? 'Buffering ${pct.round()}%…'
            : 'Finding peers…');

    return Stack(fit: StackFit.expand, children: [
      // Always paint a pre-roll layer so we never sit on a bare black scaffold
      // while the Video surface is still hidden / empty.
      const ColoredBox(color: Color(0xFF0A0A0E)),
      if (showPoster)
        CachedArt(
          url: art,
          fallbackUrl: widget.posterUrl,
          fit: BoxFit.cover,
        ),
      Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              status,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 14),
            SizedBox(
              width: 220,
              child: LinearProgressIndicator(
                value: barValue,
                minHeight: 4,
                backgroundColor: Colors.white24,
                color: AppTheme.seed,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            if (peers > 0 || seeders > 0 || speed > 0.01) ...[
              const SizedBox(height: 10),
              Text(
                [
                  if (seeders > 0) '$seeders seeders',
                  if (peers > 0) '$peers peers',
                  if (speed > 0.01) '${speed.toStringAsFixed(1)} MB/s',
                ].join(' · '),
                style: const TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ],
          ],
        ),
      ),
    ]);
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
        focusNode: _rootFocus,
        autofocus: true,
        descendantsAreFocusable: true,
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
        fit: StackFit.expand,
        children: [
          // Full-bleed on every platform so media_kit's seekbar sits at the
          // window bottom (Center letterboxing stacked it on the torrent bar).
          Positioned.fill(child: _videoSurface()),
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
            top: 8,
            left: 4,
            right: 12,
            child: _chromeLayer(
              hiddenOffset: const Offset(0, -0.35),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  TvFocus(
                    child: IconButton(
                      focusNode: _backFocus,
                      onPressed: _onBackPressed,
                      icon: const Icon(Icons.arrow_back, color: Colors.white),
                    ),
                  ),
                  if (!_isTrailer) _playerTitleChrome(),
                ],
              ),
            ),
          ),
          // Custom scrubber for VLC/Exo, and for desktop media_kit streams
          // (media_kit seeks on every pointer-move and hard-crashes Windows).
          // Keep ±10/play only for VLC/Exo — media_kit already has its bottom bar.
          if (_showSeekControls && (_useVlc || _useExo || _useDesktopSafeSeekBar))
            Positioned(
              left: 24,
              right: 24,
              bottom: _useDesktopSafeSeekBar ? 72 : 28,
              child: _chromeLayer(
                hiddenOffset: const Offset(0, 0.45),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _playbackSeekBar(),
                    if (_useVlc || _useExo) ...[
                      const SizedBox(height: 10),
                      _seekSkipBar(),
                    ],
                  ],
                ),
              ),
            ),
          // Windowed: align with the seeding chip on the scaffold. Fullscreen
          // copies live inside media_kit controls (native fullscreen route).
          if (!_inFullscreen) ..._skipAndPlayNextOverlays(),
          // Stats + bar while buffering (chip when HUD is poster-less mid-play).
          if (_showStreamChip)
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
                  _audioTrackMenu(),
                  _subtitleTrackMenu(),
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

  Widget _audioTrackMenu() {
    return Builder(
      builder: (context) {
        return TvFocus(
          child: IconButton(
            focusNode: _audioFocus,
            tooltip: 'Audio language',
            icon: const Icon(Icons.language, color: Colors.white),
            onPressed: () async {
              _bumpChrome();
              final items = <PopupMenuEntry<String>>[];
              if (_useVlc) {
                if (_vlcAudio.isEmpty) {
                  items.add(
                    const PopupMenuItem<String>(
                      enabled: false,
                      value: 'none',
                      child: Text('Audio tracks appear after playback starts'),
                    ),
                  );
                } else {
                  for (final track in _vlcAudio) {
                    items.add(
                      CheckedPopupMenuItem<String>(
                        value: '${track.id}',
                        checked: _activeAudioId == '${track.id}',
                        child: Text(track.label),
                      ),
                    );
                  }
                }
              } else if (_audioTracks.isEmpty) {
                items.add(
                  const PopupMenuItem<String>(
                    enabled: false,
                    value: 'none',
                    child: Text('Audio tracks appear after playback starts'),
                  ),
                );
              } else {
                for (final track in _audioTracks) {
                  items.add(
                    CheckedPopupMenuItem<String>(
                      value: track.id,
                      checked: _activeAudioId == track.id,
                      child: Text(_audioLabel(track)),
                    ),
                  );
                }
              }
              final box = context.findRenderObject() as RenderBox?;
              if (box == null || !context.mounted) return;
              final origin = box.localToGlobal(Offset.zero);
              final id = await showMenu<String>(
                context: context,
                color: PtTheme.panel,
                position: RelativeRect.fromLTRB(
                  origin.dx,
                  origin.dy + box.size.height,
                  origin.dx + box.size.width,
                  origin.dy,
                ),
                items: items,
              );
              if (id == null || !mounted) return;
              _bumpChrome();
              if (_useVlc) {
                final trackId = int.tryParse(id);
                if (trackId == null) return;
                _audioLanguagePicked = true;
                unawaited(AndroidPlayback.nativeVlcSetAudioTrack(trackId));
                setState(() => _activeAudioId = id);
                return;
              }
              final match = _audioTracks.where((t) => t.id == id);
              if (match.isEmpty) return;
              _audioLanguagePicked = true;
              _player?.setAudioTrack(match.first);
              setState(() => _activeAudioId = id);
            },
          ),
        );
      },
    );
  }

  Widget _subtitleTrackMenu() {
    return Builder(
      builder: (context) {
        return TvFocus(
          child: IconButton(
            focusNode: _subsFocus,
            tooltip: 'Subtitles',
            icon: Icon(
              _activeSubId == null ? Icons.closed_caption_off : Icons.closed_caption,
              color: Colors.white,
            ),
            onPressed: () => unawaited(_openSubtitleMenu(context)),
          ),
        );
      },
    );
  }

  /// Desktop/mobile subtitle picker. OpenSubtitles rows are limited to server
  /// preferred languages; Wyzie results reopen this same menu (no second popup).
  Future<void> _openSubtitleMenu(BuildContext buttonContext) async {
    _bumpChrome();
    final box = buttonContext.findRenderObject() as RenderBox?;
    if (box == null || !buttonContext.mounted) return;
    final origin = box.localToGlobal(Offset.zero);
    final position = RelativeRect.fromLTRB(
      origin.dx,
      origin.dy + box.size.height,
      origin.dx + box.size.width,
      origin.dy,
    );

    // Loop so Wyzie search can refresh items in the same dropdown.
    while (mounted) {
      final info = ref.read(serverInfoProvider).valueOrNull;
      final osReady = info?.opensubtitlesConfigured ?? false;
      final wyzieReady = info?.wyzieConfigured ?? false;
      final subsReady = info?.subtitlesConfigured ?? (osReady || wyzieReady);
      final preferredCodes = preferredLanguageCodes(
        info?.preferredLanguages ??
            ref.read(settingsProvider).preferredLanguages,
      );
      final langs = preferredCodes.isNotEmpty ? preferredCodes : const ['en'];
      final preferred = langs.first;
      final osLangs = [
        for (final code in langs)
          kContentLanguages.firstWhere(
            (l) => l.code == code,
            orElse: () => ContentLanguage(code, languageDisplayName(code)),
          ),
      ];

      final items = <PopupMenuEntry<String>>[
        CheckedPopupMenuItem(
          value: 'off',
          checked: _activeSubId == null,
          child: const Text('Off'),
        ),
        if (_useVlc)
          for (final track in _vlcSpu)
            CheckedPopupMenuItem(
              value: 'vlc:${track.id}',
              checked: _activeSubId == 'vlc:${track.id}',
              child: Text(track.label),
            ),
        for (final sub in _subs)
          CheckedPopupMenuItem(
            value: sub.id,
            checked: _activeSubId == sub.id,
            child: Text(sub.label),
          ),
        if (_wyzieHits.isNotEmpty) ...[
          const PopupMenuDivider(),
          const PopupMenuItem(
            enabled: false,
            child: Text('Wyzie results', style: TextStyle(color: Colors.white54)),
          ),
          for (final hit in _wyzieHits)
            PopupMenuItem(
              value: 'wyzie_hit:${hit.id}',
              child: Text(hit.label),
            ),
        ],
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: 'add_file',
          child: Text('From storage…'),
        ),
        const PopupMenuItem(
          value: 'add_url',
          child: Text('From link…'),
        ),
        if (subsReady) ...[
          const PopupMenuDivider(),
          if (wyzieReady)
            PopupMenuItem(
              value: 'wyzie:$preferred',
              child: Text(
                _subsLoading ? 'Searching Wyzie…' : 'Search Wyzie ($preferred)',
              ),
            ),
          if (osReady)
            for (final lang in osLangs)
              PopupMenuItem(
                value: 'download:${lang.code}',
                child: Text('OpenSubtitles ${lang.label}'),
              ),
        ] else
          const PopupMenuItem(
            value: 'settings',
            child: Text('Add subtitle API key'),
          ),
      ];

      if (!buttonContext.mounted) return;
      final value = await showMenu<String>(
        context: buttonContext,
        color: PtTheme.panel,
        position: position,
        items: items,
      );
      if (value == null || !mounted) return;
      _bumpChrome();

      if (value == 'settings') {
        await _promptOpenSubtitlesKey();
        return;
      }
      if (value == 'add_file') {
        await _addSubtitleFromFile();
        return;
      }
      if (value == 'add_url') {
        await _addSubtitleFromUrl();
        return;
      }
      if (value == 'off') {
        await _disableSubtitles();
        return;
      }
      if (value.startsWith('vlc:')) {
        final id = int.tryParse(value.substring(4));
        if (id != null) {
          await AndroidPlayback.nativeVlcSetSpuTrack(id);
          if (mounted) setState(() => _activeSubId = value);
        }
        return;
      }
      if (value.startsWith('wyzie_hit:')) {
        final id = value.substring('wyzie_hit:'.length);
        _SubtitleOption? hit;
        for (final h in _wyzieHits) {
          if (h.id == id) {
            hit = h;
            break;
          }
        }
        if (hit != null) await _downloadAndApplySubtitle(hit);
        return;
      }
      if (value.startsWith('wyzie:')) {
        final lang = value.substring('wyzie:'.length);
        await _searchWyzieSubtitles(lang);
        if (!mounted) return;
        // Re-open the same dropdown with results inline.
        continue;
      }
      if (value.startsWith('download:')) {
        await _loadOpenSubtitles(language: value.substring('download:'.length));
        return;
      }
      await _pickSubtitleLanguage(value);
      return;
    }
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
        // ValueListenableBuilder keeps countdown / skip / scrubber state fresh.
        if (fullscreen)
          Positioned.fill(
            child: ValueListenableBuilder<int>(
              valueListenable: _overlayEpoch,
              builder: (context, _, __) {
                return Stack(
                  fit: StackFit.expand,
                  children: [
                    ..._skipAndPlayNextOverlays(),
                    if (_showSeekControls && _useDesktopSafeSeekBar)
                      Positioned(
                        left: 24,
                        right: 24,
                        bottom: 72,
                        child: _playbackSeekBar(),
                      ),
                  ],
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
    final speed = info?.downloadMbps ?? local?.downloadMbps ?? 0;
    final seeders = info?.seeders ?? local?.seeders ?? 0;
    final peers = info?.peers ?? local?.peers ?? 0;
    // StreamSession.bufferProgress is 0–1; LocalStreamStats.bufferPct is 0–100.
    final pct = info != null
        ? (info.bufferProgress * 100).clamp(0.0, 100.0)
        : (local?.bufferPct ?? 0).clamp(0.0, 100.0);
    final line = streamStatsLine(
      pct: pct,
      speed: speed,
      seeders: seeders,
      peers: peers,
      hasVideo: _hasVideo,
      playing: _playing,
    );
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
      child: _ActionChipFocus(
        focusNode: _playNextFocus,
        onTap: _playNextBusy ? null : _onPlayNextPressed,
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
    );
  }

  Widget _skipSegmentButton(MediaSegment segment) {
    // Match seed/speed chip chrome and insets (16 / 72).
    return SafeArea(
      child: _ActionChipFocus(
        focusNode: _skipFocus,
        onTap: _skipActiveSegment,
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
    );
  }

  Widget _seekSkipBar() {
    Widget skipButton({
      required IconData icon,
      required int seconds,
      required FocusNode focusNode,
    }) {
      final enabled = _canSeek;
      return Opacity(
        opacity: enabled ? 1 : 0.45,
        child: Material(
          color: Colors.black.withValues(alpha: 0.62),
          shape: const CircleBorder(),
          child: InkWell(
            focusNode: focusNode,
            customBorder: const CircleBorder(),
            onTap: enabled
                ? () {
                    _bumpChrome();
                    _seekRelative(seconds);
                  }
                : null,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Icon(icon, color: Colors.white, size: 26),
            ),
          ),
        ),
      );
    }

    return SafeArea(
      top: false,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          skipButton(icon: Icons.replay_10, seconds: -10, focusNode: _rewindFocus),
          const SizedBox(width: 18),
          Material(
            color: Colors.black.withValues(alpha: 0.62),
            shape: const CircleBorder(),
            child: InkWell(
              focusNode: _playFocus,
              customBorder: const CircleBorder(),
              onTap: () {
                _bumpChrome();
                _playOrPause();
              },
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Icon(
                  _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  color: Colors.white,
                  size: 32,
                ),
              ),
            ),
          ),
          const SizedBox(width: 18),
          skipButton(icon: Icons.forward_10, seconds: 10, focusNode: _forwardFocus),
        ],
      ),
    );
  }

  String _fmtClock(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  /// Scrubber that seeks only on release (safe for Windows libmpv).
  Widget _playbackSeekBar() {
    Duration mediaKitPos() {
      if (_seeking) return _lastGoodPos;
      final p = _player?.state.position ?? Duration.zero;
      return p.inMilliseconds > 0 ? p : _lastGoodPos;
    }

    final pos = _useVlc
        ? _vlcPosition
        : (_useExo ? (_exo?.value.position ?? Duration.zero) : mediaKitPos());
    final dur = _useVlc
        ? _vlcDuration
        : (_useExo
            ? (_exo?.value.duration ?? Duration.zero)
            : (_player?.state.duration ?? Duration.zero));
    final maxMs = dur.inMilliseconds > 0 ? dur.inMilliseconds.toDouble() : 1.0;
    final value = pos.inMilliseconds.clamp(0, maxMs.toInt()).toDouble();

    return SafeArea(
      top: false,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
          child: Row(
            children: [
              Text(
                _fmtClock(pos),
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 3,
                    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                    overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                    activeTrackColor: AppTheme.seed,
                    inactiveTrackColor: Colors.white24,
                    thumbColor: Colors.white,
                  ),
                  child: Slider(
                    value: value,
                    max: maxMs,
                    onChangeStart: (_) => _bumpChrome(),
                    onChanged: _canSeek
                        ? (v) {
                            setState(() {
                              if (_useVlc) {
                                _vlcPosition = Duration(milliseconds: v.round());
                              }
                              _lastGoodPos = Duration(milliseconds: v.round());
                            });
                          }
                        : null,
                    onChangeEnd: _canSeek
                        ? (v) => unawaited(_seekPlayback(Duration(milliseconds: v.round())))
                        : null,
                  ),
                ),
              ),
              Text(
                dur > Duration.zero ? _fmtClock(dur) : '--:--',
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _videoSurface() {
    if (_useVlc) {
      final id = _vlcTextureId;
      if (id == null) return const ColoredBox(color: Colors.black);
      return LayoutBuilder(
        builder: (context, constraints) {
          final cw = constraints.maxWidth.isFinite && constraints.maxWidth > 0
              ? constraints.maxWidth.round()
              : 1920;
          final ch = constraints.maxHeight.isFinite && constraints.maxHeight > 0
              ? constraints.maxHeight.round()
              : 1080;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            unawaited(AndroidPlayback.nativeVlcSetSurfaceSize(cw, ch));
          });
          // Texture has 0×0 intrinsic size — must be forced to fill.
          return ColoredBox(
            color: Colors.black,
            child: SizedBox.expand(
              child: Texture(textureId: id),
            ),
          );
        },
      );
    }
    if (_useExo) {
      final exo = _exo;
      if (exo == null || !exo.value.isInitialized) return const SizedBox.shrink();
      // Some TV SoCs report 0×0 until the first frame — don't collapse the surface.
      final raw = exo.value.size;
      final w = raw.width > 1 ? raw.width : 1920.0;
      final h = raw.height > 1 ? raw.height : 1080.0;
      final video = SizedBox.expand(
        child: FittedBox(
          fit: BoxFit.contain,
          child: SizedBox(
            width: w,
            height: h,
            child: VideoPlayer(exo),
          ),
        ),
      );
      return isAndroidTv ? IgnorePointer(child: video) : video;
    }
    final controller = _controller;
    if (controller == null) return const SizedBox.shrink();
    // Desktop: no swipe/double-tap seeks (bypass our safe scrubber and crash Windows).
    final seekOk =
        !_useDesktopSafeSeekBar && (_canSeek || _showSeekControls);
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
        // Hide media_kit's drag-seek bar on desktop — it calls seek() on every
        // pointer move and crashes Windows (hr-seek + d3d11va). We render our
        // own onChangeEnd scrubber above the bottom bar instead.
        normal: MaterialDesktopVideoControlsThemeData(
          displaySeekBar: !_useDesktopSafeSeekBar,
          seekBarContainerHeight: 36.0,
          seekBarHeight: 3.2,
          seekBarHoverHeight: 5.6,
          seekBarThumbSize: 12.0,
          bottomButtonBar: const [
            MaterialDesktopSkipPreviousButton(),
            MaterialDesktopPlayOrPauseButton(),
            MaterialDesktopSkipNextButton(),
            MaterialDesktopVolumeButton(),
            MaterialDesktopPositionIndicator(),
            Spacer(),
            MaterialDesktopFullscreenButton(),
          ],
        ),
        fullscreen: MaterialDesktopVideoControlsThemeData(
          displaySeekBar: !_useDesktopSafeSeekBar,
          seekBarContainerHeight: 36.0,
          seekBarHeight: 3.2,
          seekBarHoverHeight: 5.6,
          seekBarThumbSize: 12.0,
          bottomButtonBar: const [
            MaterialDesktopSkipPreviousButton(),
            MaterialDesktopPlayOrPauseButton(),
            MaterialDesktopSkipNextButton(),
            MaterialDesktopVolumeButton(),
            MaterialDesktopPositionIndicator(),
            Spacer(),
            MaterialDesktopFullscreenButton(),
          ],
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
    // Keep Video mounted for decode, but don't paint a black empty surface —
    // the pre-roll HUD covers the scaffold until the stream opens.
    final hideEmpty = !_streamOpened && widget.isStream;
    if (hideEmpty) {
      return Opacity(opacity: 0, child: IgnorePointer(child: video));
    }
    return video;
  }
}

/// Skip Intro / Play Next chip with TV focus ring + press scale feedback.
class _ActionChipFocus extends StatefulWidget {
  const _ActionChipFocus({
    required this.focusNode,
    required this.child,
    this.onTap,
  });

  final FocusNode focusNode;
  final Widget child;
  final VoidCallback? onTap;

  @override
  State<_ActionChipFocus> createState() => _ActionChipFocusState();
}

class _ActionChipFocusState extends State<_ActionChipFocus> {
  bool _focused = false;
  bool _pressed = false;

  @override
  void initState() {
    super.initState();
    _focused = widget.focusNode.hasFocus;
    widget.focusNode.addListener(_onFocus);
  }

  @override
  void didUpdateWidget(covariant _ActionChipFocus oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusNode != widget.focusNode) {
      oldWidget.focusNode.removeListener(_onFocus);
      widget.focusNode.addListener(_onFocus);
      _focused = widget.focusNode.hasFocus;
    }
  }

  @override
  void dispose() {
    widget.focusNode.removeListener(_onFocus);
    super.dispose();
  }

  void _onFocus() {
    if (!mounted) return;
    setState(() => _focused = widget.focusNode.hasFocus);
  }

  @override
  Widget build(BuildContext context) {
    final scale = _pressed ? 0.94 : (_focused ? 1.06 : 1.0);
    return AnimatedScale(
      scale: scale,
      duration: const Duration(milliseconds: 110),
      curve: Curves.easeOut,
      child: Material(
        color: Colors.black.withValues(alpha: _focused ? 0.88 : 0.72),
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          focusNode: widget.focusNode,
          borderRadius: BorderRadius.circular(20),
          onTap: widget.onTap == null
              ? null
              : () async {
                  setState(() => _pressed = true);
                  await Future<void>.delayed(const Duration(milliseconds: 70));
                  if (mounted) setState(() => _pressed = false);
                  widget.onTap?.call();
                },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: _focused ? Colors.white : Colors.white24,
                width: _focused ? 2 : 1,
              ),
            ),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}
