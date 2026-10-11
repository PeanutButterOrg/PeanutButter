/// Compact HUD / chip line for torrent stream progress.
///
/// Kept free of Flutter widgets so unit tests can cover the copy without a
/// player / MediaKit harness.
///
/// Pre-play matches Android TV: `Buffering 12% · 20 KB/s · 4 peers`
String streamStatsLine({
  required num pct,
  required double speed,
  required int seeders,
  required int peers,
  bool hasVideo = false,
  bool playing = false,
  /// True when metadata is in / trackers answered / bytes are moving — even if
  /// the peer *count* is junk (libtorrent_flutter often reports 16384).
  bool swarmActive = false,
}) {
  // Drop junk swarm sizes (e.g. 16384) from the displayed count — but treat
  // those junk values as evidence the session is connected.
  final seeds = seeders <= 0 || seeders >= 10000 ? 0 : seeders;
  final peerN = peers <= 0 || peers >= 10000 ? 0 : peers;
  final junkSwarmHint = peers >= 10000 || seeders >= 10000;
  final connected = swarmActive || seeds > 0 || peerN > 0 || junkSwarmHint;
  final raw = pct.toDouble();
  // Fake 100% only when nothing is connected and no video has started —
  // a real completed download (0 MB/s after finish) must still show 100%.
  final likelyFakeComplete = raw >= 99.5 &&
      speed < 0.05 &&
      !hasVideo &&
      !playing &&
      !connected;
  final sane = likelyFakeComplete ? 0.0 : raw;
  // Once video is on screen, show true readiness (don't pin at 99% forever
  // while the swarm keeps seeding). Pre-play still avoids a fake "100% done".
  final shown = (sane >= 99.5 && speed >= 0.05 && !hasVideo && !playing)
      ? 99.0
      : sane.clamp(0, 100);
  final shownInt = shown.round().clamp(0, 100);

  String formatSpeed(double mbps) {
    if (mbps >= 0.05) return '${mbps.toStringAsFixed(1)} MB/s';
    if (mbps >= 0.001) {
      final kb = mbps * 1024;
      return kb >= 10
          ? '${kb.toStringAsFixed(0)} KB/s'
          : '${kb.toStringAsFixed(1)} KB/s';
    }
    return '';
  }

  final speedLabel = formatSpeed(speed);
  // Match Android TV: always label the swarm as "N peers" (seeds ⊆ peers).
  final swarmN = peerN > 0 ? peerN : seeds;
  final swarm = swarmN > 0 ? '  ·  $swarmN peers' : '';

  // Mid-play chip — keep the compact "12% · 1.2 MB/s · peers" form.
  if (hasVideo || playing) {
    final String mid;
    if (shown >= 99.5 && speed < 0.05) {
      mid = 'ready';
    } else if (speedLabel.isNotEmpty) {
      mid = speedLabel;
    } else {
      mid = 'ready';
    }
    return '$shownInt%  ·  $mid$swarm';
  }

  // Pre-play — match Android TV wording.
  if (!connected && shownInt <= 0) {
    return 'Finding peers…';
  }
  if (shown >= 99.5 && speed < 0.05) {
    return 'Buffering $shownInt%$swarm';
  }
  if (speedLabel.isNotEmpty) {
    return 'Buffering $shownInt%  ·  $speedLabel$swarm';
  }
  if (connected || shownInt > 0) {
    return 'Buffering ${shownInt.clamp(1, 100)}%$swarm';
  }
  return 'Finding peers…';
}
