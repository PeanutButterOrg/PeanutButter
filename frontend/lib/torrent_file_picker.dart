/// Picks the one video file to stream from a torrent: the requested episode
/// in a season pack, the feature (not extras or samples) in a movie folder.
/// Same rules as the TV picker (android-native/core/.../TorrentFilePicker.kt).
library;

import 'dart:math' as math;

class PickEntry {
  const PickEntry(this.index, this.path, this.size);
  final int index;
  final String path;
  final int size;
}

const _videoExt = {
  'mkv', 'mp4', 'm4v', 'mov', 'avi', 'webm', 'ts', 'm2ts', 'mts', //
  'mpeg', 'mpg', 'vob', 'flv', 'wmv', 'ogv', '3gp',
};

/// Folder and file words that mark bonus material, not the feature.
const _junkWords = [
  'sample', 'trailer', 'teaser', 'extras', 'extra', 'featurette', 'featurettes', //
  'bonus', 'behind the scenes', 'behindthescenes', 'deleted scenes', 'deleted scene',
  'interview', 'interviews', 'making of', 'gag reel', 'bloopers', 'promo', 'proof',
  'screens', 'short films', 'specials', 'ncop', 'nced', 'creditless', 'opening', 'ending',
];

const _minFeatureBytes = 60 * 1024 * 1024;

bool isVideoPath(String path) {
  final dot = path.lastIndexOf('.');
  return dot >= 0 && _videoExt.contains(path.substring(dot + 1).toLowerCase());
}

/// The file a Stremio add-on chose (`so=` in the magnet), if any.
int? selectedFileIndex(String magnet) {
  final q = magnet.indexOf('?');
  if (q < 0) return null;
  for (final part in magnet.substring(q + 1).split('&')) {
    if (!part.startsWith('so=')) continue;
    return int.tryParse(part.substring(3).split(',').first.split('-').first);
  }
  return null;
}

/// The magnet without `so=`: libtorrent applies it as file priorities after
/// metadata, which can wipe the stream's piece priorities; the engine picks
/// the file per piece itself.
String withoutFileSelection(String magnet) {
  final q = magnet.indexOf('?');
  if (q < 0) return magnet;
  final kept = magnet.substring(q + 1).split('&').where((p) => !p.startsWith('so='));
  return '${magnet.substring(0, q + 1)}${kept.join('&')}';
}

int? pickTorrentFile(List<PickEntry> files, {int? season, int? episode, int? hint}) {
  final videos = files.where((f) => isVideoPath(f.path)).toList();
  if (videos.isEmpty) {
    if (files.isEmpty) return null;
    return files.reduce((a, b) => b.size > a.size ? b : a).index;
  }
  final wantEpisode = season != null && episode != null && season >= 0 && episode > 0;

  if (hint != null) {
    for (final f in videos) {
      if (f.index != hint) continue;
      final tag = _episodeTag(f.path);
      // Trust the add-on unless the name clearly says another episode.
      if (!_isJunk(f, videos) &&
          (!wantEpisode || tag == null || (tag.$1 == season && tag.$2 == episode))) {
        return f.index;
      }
    }
  }

  var features = videos.where((f) => !_isJunk(f, videos)).toList();
  if (features.isEmpty) features = videos;
  if (wantEpisode) {
    PickEntry? best;
    var bestScore = 0;
    for (final f in features) {
      final s = episodeScore(f.path, season!, episode!);
      if (s > bestScore || (s == bestScore && s > 0 && f.size > best!.size)) {
        best = f;
        bestScore = s;
      }
    }
    if (best != null) return best.index;
  }
  return features.reduce((a, b) => b.size > a.size ? b : a).index;
}

String _norm(String p) => p.replaceAll('\\', '/').toLowerCase();
String _name(String p) => _norm(p).split('/').last;
String _dirs(String p) {
  final n = _norm(p);
  final i = n.lastIndexOf('/');
  return i < 0 ? '' : n.substring(0, i);
}

String _words(String s) =>
    ' ${s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim()} ';

bool _isJunk(PickEntry f, List<PickEntry> all) {
  final name = _name(f.path);
  final dot = name.lastIndexOf('.');
  final inName = _words(dot < 0 ? name : name.substring(0, dot));
  final inDir = _words(_dirs(f.path));
  for (final w in _junkWords) {
    if (inDir.contains(' $w ') || inName.contains(' $w ')) return true;
  }
  // A tiny clip next to a full-size file is a sample or an extra.
  final biggest = all.map((e) => e.size).reduce(math.max);
  return f.size > 0 && f.size < _minFeatureBytes && biggest >= _minFeatureBytes * 4;
}

final _sxe = RegExp(r'(?<![a-z0-9])s(\d{1,2})[ ._-]?e(\d{1,3})(?!\d)');
final _nxn = RegExp(r'(?<![a-z0-9])(\d{1,2})x(\d{1,3})(?!\d)');

/// Season/episode written in the file name itself (S01E05, 1x05).
(int, int)? _episodeTag(String path) {
  final name = _name(path);
  final m = _sxe.firstMatch(name) ?? _nxn.firstMatch(name);
  if (m == null) return null;
  return (int.parse(m.group(1)!), int.parse(m.group(2)!));
}

/// 0 = not this episode. Higher is surer:
///  4 S01E05 / 1x05 in the name (also S01E04E05 and S01E04-E05 ranges),
///  3 "Season 1" folder + E05 / Episode 5 / "05 - " in the name,
///  2 E05 / Episode 5 alone, 1 a bare " 05 " (anime-style numbering).
int episodeScore(String path, int season, int episode) {
  final name = _name(path);
  final dirs = _dirs(path);

  for (final m in _sxe.allMatches(name)) {
    final s = int.parse(m.group(1)!);
    final e = int.parse(m.group(2)!);
    if (s != season) continue;
    if (e == episode) return 4;
    // Multi-episode file: S01E04E05 or S01E04-E05 / S01E04-05.
    final more = RegExp(r'^(?:[ ._-]?e|-)(\d{1,3})(?!\d)').firstMatch(name.substring(m.end));
    final e2 = more == null ? null : int.tryParse(more.group(1)!);
    if (e2 != null && episode >= e && episode <= e2) return 4;
  }
  for (final m in _nxn.allMatches(name)) {
    if (int.parse(m.group(1)!) == season && int.parse(m.group(2)!) == episode) return 4;
  }
  // The name names a different episode: not this one.
  if (_episodeTag(name) != null) return 0;

  final ep = '0*$episode(?!\\d)';
  final explicit = RegExp('(?<![a-z0-9])(?:e|ep|episode)[ ._-]?$ep').hasMatch(name);
  final leading = RegExp('^$ep[ ._-]').hasMatch(name) ||
      RegExp('(?<![a-z0-9])-[ ._]?$ep[ ._\\[(-]').hasMatch(name);
  final seasonDir =
      RegExp('(?<![a-z0-9])(?:season|series|s)[ ._-]?0*$season(?!\\d)').hasMatch(dirs);
  final otherSeasonDir = RegExp(r'(?<![a-z0-9])(?:season|series)[ ._-]?0*(\d+)(?!\d)')
      .allMatches(dirs)
      .any((m) => int.parse(m.group(1)!) != season);
  if (otherSeasonDir && !seasonDir) return 0;
  final dot = name.lastIndexOf('.');
  final stem = dot < 0 ? name : name.substring(0, dot);
  if ((explicit || leading) && seasonDir) return 3;
  if (explicit) return 2;
  if (leading) return 1;
  // Not "5.1" audio or "x265": the number stands alone.
  if (RegExp('(?<![a-z0-9.])$ep(?![a-z0-9.])').hasMatch(stem)) return 1;
  return 0;
}

/// The episode number releases use, when the catalog orders episodes
/// differently. Some shows title episodes with their own number (Samurai
/// Jack: S01E07 is "IX", S02E01 is "XIV"); releases follow that number, so
/// the catalog's S01E07 file is really "VII". Titles like "IX", "Episode 9"
/// or "Chapter 9: …" give the show's number; it counts across seasons when
/// it is past this season's size.
///
/// [seasons] maps season number → (episode number → title), from the
/// catalog. Returns null when nothing needs changing.
int? releaseEpisode(Map<int, Map<int, String?>> seasons, int season, int episode) {
  final titles = seasons[season];
  if (titles == null || !titles.containsKey(episode)) return null;
  // Only shows that number every episode this way, not one odd title.
  final numbered = titles.values.where((t) => _numberInTitle(t) != null).length;
  if (numbered * 2 < titles.length) return null;
  final n = _numberInTitle(titles[episode]);
  if (n == null) return null;
  final size = titles.length;
  var earlier = 0;
  seasons.forEach((s, list) {
    if (s > 0 && s < season) earlier += list.length;
  });
  final int inSeason;
  if (n > size && n - earlier >= 1 && n - earlier <= size) {
    inSeason = n - earlier;
  } else if (n <= size) {
    inSeason = n;
  } else {
    return null;
  }
  return inSeason == episode ? null : inSeason;
}

int? _numberInTitle(String? title) {
  if (title == null) return null;
  final head = title.trim().split(':').first.trim().toLowerCase();
  final m = RegExp(r'^(?:(?:episode|chapter|ep\.?|part)\s*)?([ivxlcdm]+|\d{1,4})\.?$')
      .firstMatch(head);
  if (m == null) return null;
  return int.tryParse(m.group(1)!) ?? _roman(m.group(1)!);
}

int? _roman(String s) {
  const v = {'i': 1, 'v': 5, 'x': 10, 'l': 50, 'c': 100, 'd': 500, 'm': 1000};
  var total = 0;
  for (var i = 0; i < s.length; i++) {
    final cur = v[s[i]];
    if (cur == null) return null;
    final next = i + 1 < s.length ? v[s[i + 1]] ?? 0 : 0;
    total += cur < next ? -cur : cur;
  }
  // Words made of roman letters ("Civil", "Mild") aren't numerals.
  return total >= 1 && total <= 399 && _toRoman(total) == s ? total : null;
}

String _toRoman(int n) {
  const parts = [
    (100, 'c'), (90, 'xc'), (50, 'l'), (40, 'xl'), (10, 'x'), //
    (9, 'ix'), (5, 'v'), (4, 'iv'), (1, 'i'),
  ];
  var rest = n;
  final sb = StringBuffer();
  for (final (value, r) in parts) {
    while (rest >= value) {
      sb.write(r);
      rest -= value;
    }
  }
  return sb.toString();
}
