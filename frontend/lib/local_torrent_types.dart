/// Data shared by the desktop torrent engine and its web stand-in.
library;

class LocalStreamHandle {
  const LocalStreamHandle({
    required this.torrentId,
    required this.streamId,
    required this.url,
    required this.magnet,
  });

  final int torrentId;
  final int streamId;
  final String url;
  final String magnet;
}

/// Thrown when a newer [LocalTorrentEngine.start] supersedes this one.
class LocalStreamCancelled implements Exception {}

class LocalStreamStats {
  const LocalStreamStats({
    required this.bufferPct,
    required this.downloadMbps,
    required this.seeders,
    required this.peers,
    required this.ready,
    this.stateLabel = '',
    this.torrentComplete = false,
    this.swarmActive = false,
  });

  final double bufferPct;
  final double downloadMbps;
  final int seeders;
  final int peers;
  final bool ready;
  final String stateLabel;
  final bool torrentComplete;
  final bool swarmActive;
}

const int kDownloadBudgetBytes = 10 * 1024 * 1024 * 1024;

class DownloadEntry {
  const DownloadEntry(this.path, this.bytes, this.lastUsedMs);

  final String path;
  final int bytes;
  final int lastUsedMs;
}

/// Oldest first, until what's left fits in [budget].
List<DownloadEntry> downloadsToDelete(List<DownloadEntry> entries, int budget) {
  var used = entries.fold<int>(0, (sum, e) => sum + e.bytes);
  final oldestFirst = [...entries]..sort((a, b) => a.lastUsedMs.compareTo(b.lastUsedMs));
  final out = <DownloadEntry>[];
  for (final e in oldestFirst) {
    if (used <= budget) break;
    out.add(e);
    used -= e.bytes;
  }
  return out;
}
