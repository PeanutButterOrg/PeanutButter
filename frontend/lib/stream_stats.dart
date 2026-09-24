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
  final String speedStr;
  if (speed >= 0.05) {
    speedStr = '${speed.toStringAsFixed(1)} MB/s';
  } else if (pct >= 2 && (hasVideo || playing)) {
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
