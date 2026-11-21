/// Prevents a new stream from starting while old players still release shared
/// torrent handles or delete downloaded pieces.
class StreamCleanupBarrier {
  Future<void>? _pending;

  void add(Future<void> cleanup) {
    // Cleanup is best effort, but even a failed cleanup must finish before the
    // next stream starts. Observe errors immediately, including before wait().
    final settled =
        cleanup.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    final previous = _pending;
    _pending = previous == null
        ? settled
        : Future.wait<void>([previous, settled]).then<void>((_) {});
  }

  Future<void> wait() async {
    while (_pending != null) {
      final pending = _pending!;
      await pending;
      // Another player may have registered cleanup while we were waiting.
      if (identical(_pending, pending)) _pending = null;
    }
  }
}
