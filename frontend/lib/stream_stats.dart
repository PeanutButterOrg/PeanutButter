/// Compact HUD / chip line for torrent stream progress.
///
/// Kept free of Flutter widgets so unit tests can cover the copy without a
/// player / MediaKit harness.
String streamStatsLine({
  required num pct,
  required double speed,
  required int seeders,
  required int peers,
  bool hasVideo = false,
  bool playing = false,
}) {
  final raw = pct.toDouble();
  // Fake 100% only when nothing is connected and no video has started —
  // a real completed download (0 MB/s after finish) must still show 100%.
  final likelyFakeComplete = raw >= 99.5 &&
      speed < 0.05 &&
      !hasVideo &&
      !playing &&
      seeders == 0 &&
      peers == 0;
  final sane = likelyFakeComplete ? 0.0 : raw;
  // While bytes are still arriving, never present the transfer as finished.
  final shown = (sane >= 99.5 && speed >= 0.05) ? 99.0 : sane.clamp(0, 100);
  final String speedStr;
  if (shown >= 99.5 && speed < 0.05) {
    speedStr = 'downloaded';
  } else if (speed >= 0.05) {
    speedStr = '${speed.toStringAsFixed(1)} MB/s';
  } else if (shown >= 2 && (hasVideo || playing)) {
    speedStr = 'ready';
  } else if (seeders > 0 || peers > 0) {
    // Peers alone ≠ playable data yet.
    speedStr = shown > 0 ? 'buffering…' : 'connected · waiting for data…';
  } else {
    speedStr = 'finding peers…';
  }
  final swarm = seeders > 0
      ? '  ·  $seeders seeds'
      : (peers > 0 ? '  ·  $peers peers' : '');
  return '${shown.round()}%  ·  $speedStr$swarm';
}
