import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// Desktop seek bar with hover timestamp + frame thumbnail preview.
///
/// Uses a muted secondary [Player] to grab JPEG screenshots at the hover
/// position (debounced). Falls back to timestamp-only when a frame can't be
/// decoded (common for undownloaded torrent ranges).
class DesktopSeekPreviewBar extends StatefulWidget {
  const DesktopSeekPreviewBar({
    super.key,
    required this.player,
    this.mediaUrl,
  });

  final Player player;
  /// Same URL the main player is using — needed for secondary preview seeks.
  final String? mediaUrl;

  @override
  State<DesktopSeekPreviewBar> createState() => _DesktopSeekPreviewBarState();
}

class _DesktopSeekPreviewBarState extends State<DesktopSeekPreviewBar> {
  bool _hover = false;
  bool _click = false;
  double _slider = 0;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  Duration _buffer = Duration.zero;

  final _subs = <StreamSubscription>[];
  Timer? _thumbDebounce;
  Player? _preview;
  String? _previewUrl;
  Uint8List? _thumb;
  int? _thumbSecond;
  bool _thumbBusy = false;
  final _thumbCache = <int, Uint8List>{};

  @override
  void initState() {
    super.initState();
    final p = widget.player;
    _position = p.state.position;
    _duration = p.state.duration;
    _buffer = p.state.buffer;
    _subs.addAll([
      p.stream.position.listen((e) {
        if (!_click && mounted) setState(() => _position = e);
      }),
      p.stream.duration.listen((e) {
        if (mounted) setState(() => _duration = e);
      }),
      p.stream.buffer.listen((e) {
        if (mounted) setState(() => _buffer = e);
      }),
      p.stream.completed.listen((_) {
        if (!_click && mounted) setState(() => _position = Duration.zero);
      }),
    ]);
  }

  @override
  void dispose() {
    _thumbDebounce?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    final preview = _preview;
    _preview = null;
    unawaited(() async {
      try {
        await preview?.dispose();
      } catch (_) {}
    }());
    super.dispose();
  }

  double get _posPct {
    if (_duration.inMilliseconds <= 0) return 0;
    return (_position.inMilliseconds / _duration.inMilliseconds).clamp(0.0, 1.0);
  }

  double get _bufPct {
    if (_duration.inMilliseconds <= 0) return 0;
    return (_buffer.inMilliseconds / _duration.inMilliseconds).clamp(0.0, 1.0);
  }

  Duration get _hoverAt {
    if (_duration.inMilliseconds <= 0) return Duration.zero;
    return Duration(milliseconds: (_duration.inMilliseconds * _slider).round());
  }

  String _label(Duration d) {
    final total = d.inSeconds.clamp(0, 359999);
    final h = total ~/ 3600;
    final m = (total % 3600) ~/ 60;
    final s = total % 60;
    if (h > 0) {
      return '${h.toString().padLeft(2, '0')}:'
          '${m.toString().padLeft(2, '0')}:'
          '${s.toString().padLeft(2, '0')}';
    }
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  void _scheduleThumb() {
    _thumbDebounce?.cancel();
    if (!_hover || _duration.inMilliseconds <= 0) return;
    final at = _hoverAt;
    final sec = at.inSeconds;
    final cached = _thumbCache[sec];
    if (cached != null) {
      setState(() {
        _thumb = cached;
        _thumbSecond = sec;
      });
      return;
    }
    _thumbDebounce = Timer(const Duration(milliseconds: 220), () {
      unawaited(_captureThumb(at));
    });
  }

  Future<void> _captureThumb(Duration at) async {
    final url = widget.mediaUrl?.trim();
    if (url == null || url.isEmpty || _thumbBusy) return;
    final sec = at.inSeconds;
    if (_thumbCache.containsKey(sec)) {
      if (mounted) {
        setState(() {
          _thumb = _thumbCache[sec];
          _thumbSecond = sec;
        });
      }
      return;
    }
    _thumbBusy = true;
    try {
      final preview = await _ensurePreview(url);
      if (preview == null) return;
      await preview.seek(at);
      // Give demuxer a beat to present the frame.
      await Future<void>.delayed(const Duration(milliseconds: 140));
      final bytes = await preview.screenshot(format: 'image/jpeg');
      if (bytes == null || bytes.isEmpty) return;
      if (_thumbCache.length > 48) {
        _thumbCache.remove(_thumbCache.keys.first);
      }
      _thumbCache[sec] = bytes;
      if (mounted && _hover && _hoverAt.inSeconds == sec) {
        setState(() {
          _thumb = bytes;
          _thumbSecond = sec;
        });
      }
    } catch (_) {
      // Outside buffer / unsupported — timestamp-only is fine.
    } finally {
      _thumbBusy = false;
    }
  }

  Future<Player?> _ensurePreview(String url) async {
    if (_preview != null && _previewUrl == url) return _preview;
    try {
      await _preview?.dispose();
    } catch (_) {}
    _preview = null;
    _previewUrl = null;
    try {
      final p = Player(
        configuration: const PlayerConfiguration(
          bufferSize: 2 * 1024 * 1024,
          muted: true,
        ),
      );
      // Tiny offscreen controller so libmpv can decode screenshots.
      VideoController(p, configuration: const VideoControllerConfiguration(
        enableHardwareAcceleration: false,
      ));
      await p.setVolume(0);
      await p.open(Media(url), play: false);
      _preview = p;
      _previewUrl = url;
      return p;
    } catch (_) {
      return null;
    }
  }

  void _onHover(PointerHoverEvent e, BoxConstraints c) {
    final pct = (e.localPosition.dx / c.maxWidth).clamp(0.0, 1.0);
    setState(() {
      _hover = true;
      _slider = pct;
    });
    _scheduleThumb();
  }

  void _onExit() {
    _thumbDebounce?.cancel();
    setState(() {
      _hover = false;
      _slider = 0;
      _thumb = null;
      _thumbSecond = null;
    });
  }

  Future<void> _seekToSlider() async {
    if (_duration.inMilliseconds <= 0) return;
    final target = _hoverAt;
    setState(() {
      _click = false;
      _position = target;
    });
    try {
      await widget.player.seek(target);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    const barH = 3.2;
    const hoverH = 5.6;
    const thumbSize = 12.0;
    const containerH = 36.0;

    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final bubbleLeft = (w * _slider - 80).clamp(0.0, (w - 160).clamp(0.0, w));
        return MouseRegion(
          cursor: SystemMouseCursors.click,
          onHover: (e) => _onHover(e, constraints),
          onExit: (_) => _onExit(),
          child: Listener(
            onPointerDown: (_) => setState(() => _click = true),
            onPointerUp: (_) => unawaited(_seekToSlider()),
            onPointerMove: (e) {
              final pct = (e.localPosition.dx / w).clamp(0.0, 1.0);
              setState(() {
                _hover = true;
                _click = true;
                _slider = pct;
              });
              _scheduleThumb();
            },
            child: SizedBox(
              width: w,
              height: containerH + (_hover ? 110 : 0),
              child: Stack(
                clipBehavior: Clip.none,
                alignment: Alignment.bottomCenter,
                children: [
                  if (_hover)
                    Positioned(
                      left: bubbleLeft,
                      bottom: containerH + 8,
                      child: _PreviewBubble(
                        label: _label(_hoverAt),
                        image: (_thumbSecond == _hoverAt.inSeconds) ? _thumb : null,
                      ),
                    ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    height: containerH,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 150),
                        width: w,
                        height: _hover ? hoverH : barH,
                        color: const Color(0x3DFFFFFF),
                        child: Stack(
                          children: [
                            Container(
                              width: w * _slider,
                              color: const Color(0x3DFFFFFF),
                            ),
                            Container(
                              width: w * _bufPct,
                              color: const Color(0x3DFFFFFF),
                            ),
                            Container(
                              width: w * (_click ? _slider : _posPct),
                              color: const Color(0xFFFF0000),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  if (_hover || _click)
                    Positioned(
                      left: (w - thumbSize / 2) * (_click ? _slider : _posPct),
                      bottom: (containerH - thumbSize) / 2,
                      child: Container(
                        width: thumbSize,
                        height: thumbSize,
                        decoration: const BoxDecoration(
                          color: Color(0xFFFF0000),
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _PreviewBubble extends StatelessWidget {
  const _PreviewBubble({required this.label, this.image});

  final String label;
  final Uint8List? image;

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 6,
      color: Colors.black.withValues(alpha: 0.88),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (image != null) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: Image.memory(
                  image!,
                  width: 148,
                  height: 84,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                ),
              ),
              const SizedBox(height: 6),
            ],
            Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w600,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
