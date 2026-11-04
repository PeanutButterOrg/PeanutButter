/// One video at a time. Opening a player takes a while (fetching a trailer's
/// link, finding sources) and the screen stays usable meanwhile, so pressing
/// Trailer then Play used to open a second player on top of the first, both
/// playing. Play always wins; a trailer still loading is dropped.
abstract final class PlayerLaunch {
  static int _trailer = 0;
  static DateTime? _playSince;

  /// A play this old is treated as lost, so the buttons can't stay dead.
  static const Duration _playExpiry = Duration(minutes: 5);

  static bool _playing(DateTime now) {
    final since = _playSince;
    return since != null && now.difference(since) < _playExpiry;
  }

  /// A token for [trailerWanted], or null when a play is already starting.
  static int? beginTrailer({DateTime? now}) {
    if (_playing(now ?? DateTime.now())) return null;
    return ++_trailer;
  }

  static bool trailerWanted(int token) => token == _trailer;

  /// Drops any trailer still loading. False when a play is already starting.
  static bool beginPlay({DateTime? now}) {
    final at = now ?? DateTime.now();
    if (_playing(at)) return false;
    _playSince = at;
    _trailer++;
    return true;
  }

  static void endPlay() => _playSince = null;
}
