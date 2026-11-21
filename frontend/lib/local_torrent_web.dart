import 'local_torrent_types.dart';

/// The browser has no torrent engine: everything reports "not supported" or
/// does nothing, with the same API as the desktop engine.
class LocalTorrentEngine {
  LocalTorrentEngine._();
  static final LocalTorrentEngine instance = LocalTorrentEngine._();

  bool get supported => false;
  bool get isActive => false;
  int get generation => 0;
  void noteTeardown(Future<void> teardown) {}

  void configureTrackers(List<String> trackers) {}
  Future<void> prepareTrackers(List<String> serverTrackers) async {}
  Future<void> ensureInit() async {}

  Future<LocalStreamHandle> start({
    required String magnet,
    int? season,
    int? episode,
    int? fileIndex,
    void Function(LocalStreamStats stats)? onStats,
  }) {
    throw UnsupportedError('Torrent streaming needs the desktop or TV app.');
  }

  LocalStreamStats? currentStats() => null;
  Future<void> stop({bool deleteFiles = true, int? onlyGeneration}) async {}
  Future<void> purgeDownloads({int? onlyGeneration}) async {}
  void keepDownloading({int preloadBytes = 32 * 1024 * 1024}) {}
  void seekTo({required int positionMs, int? durationMs}) {}
}
