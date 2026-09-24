import 'dart:async';

import '../local_torrent.dart';

/// Debounces stream seeks so torrent readahead and the player settle together.
///
/// UI may update the scrubber immediately; [onCommit] runs only after [settle]
/// without further seek requests (default 3s).
class StreamSeekController {
  StreamSeekController({
    this.settle = const Duration(seconds: 3),
    required this.onCommit,
    this.onSettlingChanged,
    this.durationMs,
  });

  final Duration settle;
  final Future<void> Function(Duration target) onCommit;
  final void Function(bool settling)? onSettlingChanged;

  /// Optional live duration for torrent byte-offset estimation.
  int Function()? durationMs;

  Timer? _timer;
  Duration? _pending;
  int _token = 0;
  bool _settling = false;

  bool get isSettling => _settling;
  Duration? get pendingTarget => _pending;

  void request(Duration target) {
    _pending = target;
    _token++;
    final token = _token;
    if (!_settling) {
      _settling = true;
      onSettlingChanged?.call(true);
    }
    _timer?.cancel();
    _timer = Timer(settle, () {
      if (token != _token) return;
      final t = _pending;
      if (t == null) {
        _finishSettling();
        return;
      }
      unawaited(_runCommit(token, t));
    });
  }

  /// Commit immediately (Skip Intro / Play Next) — cancels pending debounce.
  Future<void> commitNow(Duration target) async {
    _timer?.cancel();
    _pending = target;
    final token = ++_token;
    if (!_settling) {
      _settling = true;
      onSettlingChanged?.call(true);
    }
    await _runCommit(token, target);
  }

  Future<void> _runCommit(int token, Duration target) async {
    try {
      LocalTorrentEngine.instance.seekTo(
        positionMs: target.inMilliseconds,
        durationMs: durationMs?.call(),
      );
      if (token != _token) return;
      await onCommit(target);
    } finally {
      if (token == _token) _finishSettling();
    }
  }

  void _finishSettling() {
    _settling = false;
    _pending = null;
    onSettlingChanged?.call(false);
  }

  void cancel() {
    _timer?.cancel();
    _timer = null;
    _token++;
    _finishSettling();
  }

  void dispose() {
    cancel();
  }
}
