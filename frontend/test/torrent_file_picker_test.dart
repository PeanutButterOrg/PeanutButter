import 'package:flutter_test/flutter_test.dart';
import 'package:peanutbutter/torrent_file_picker.dart';

const gb = 1024 * 1024 * 1024;
const mb = 1024 * 1024;

List<PickEntry> files(List<(String, int)> p) =>
    [for (var i = 0; i < p.length; i++) PickEntry(i, p[i].$1, p[i].$2)];

String? pick(List<PickEntry> f, int? s, int? e, {int? hint}) {
  final i = pickTorrentFile(f, season: s, episode: e, hint: hint);
  return i == null ? null : f[i].path;
}

void main() {
  final pack = files([
    ('Show S01/Show.S01E01.1080p.mkv', 2 * gb),
    ('Show S01/Show.S01E02.1080p.mkv', 2 * gb),
    ('Show S01/Show.S01E07.1080p.mkv', 1 * gb),
    ('Show S01/Show.S01E10.1080p.mkv', 3 * gb),
    ('Show S01/Sample/Show.S01E07.sample.mkv', 40 * mb),
    ('Show S01/Show.nfo', 1000),
  ]);

  test('SxxEyy', () {
    expect(pick(pack, 1, 7), 'Show S01/Show.S01E07.1080p.mkv');
    expect(pick(pack, 1, 1), 'Show S01/Show.S01E01.1080p.mkv');
    expect(pick(pack, 1, 10), 'Show S01/Show.S01E10.1080p.mkv');
  });

  test('unpadded and spaced', () {
    final f = files([('s1e5.mkv', gb), ('s1e6.mkv', 2 * gb), ('S01 E07 x.mkv', gb), ('1x08 y.mkv', gb)]);
    expect(pick(f, 1, 5), 's1e5.mkv');
    expect(pick(f, 1, 7), 'S01 E07 x.mkv');
    expect(pick(f, 1, 8), '1x08 y.mkv');
  });

  test('complete series picks the right season', () {
    final f = files([
      ('Show/Season 1/Show S01E03.mkv', gb),
      ('Show/Season 2/Show S02E03.mkv', 2 * gb),
      ('Show/Season 3/Show S03E03.mkv', 3 * gb),
    ]);
    expect(pick(f, 2, 3), 'Show/Season 2/Show S02E03.mkv');
  });

  test('season folder with bare numbers', () {
    final f = files([
      ('Show/Season 1/03 - Title.mkv', gb),
      ('Show/Season 2/03 - Other.mkv', 2 * gb),
      ('Show/Season 2/04 - Next.mkv', 3 * gb),
    ]);
    expect(pick(f, 2, 3), 'Show/Season 2/03 - Other.mkv');
  });

  test('anime style', () {
    final f = files([
      ('[Grp] Show - 06 [1080p].mkv', gb),
      ('[Grp] Show - 07 [1080p].mkv', gb),
      ('[Grp] Show - 17 [1080p].mkv', 2 * gb),
    ]);
    expect(pick(f, 1, 7), '[Grp] Show - 07 [1080p].mkv');
  });

  test('multi-episode file', () {
    expect(pick(files([('Show.S01E01E02.mkv', 2 * gb), ('Show.S01E03.mkv', gb)]), 1, 2), 'Show.S01E01E02.mkv');
    expect(pick(files([('Show.S01E01-E03.mkv', 2 * gb), ('Show.S01E04.mkv', gb)]), 1, 2), 'Show.S01E01-E03.mkv');
  });

  test('movie skips extras and samples', () {
    final f = files([
      ('Movie (2020)/Featurettes/Making Of.mkv', 3 * gb),
      ('Movie (2020)/Movie.2020.1080p.mkv', 2 * gb),
      ('Movie (2020)/Movie.2020.sample.mkv', 50 * mb),
      ('Movie (2020)/Trailer.mp4', 100 * mb),
    ]);
    expect(pick(f, null, null), 'Movie (2020)/Movie.2020.1080p.mkv');
  });

  test('add-on hint wins unless it names another episode', () {
    expect(pick(pack, null, null, hint: 1), 'Show S01/Show.S01E02.1080p.mkv');
    expect(pick(pack, 1, 7, hint: 2), 'Show S01/Show.S01E07.1080p.mkv');
    expect(pick(pack, 1, 7, hint: 3), 'Show S01/Show.S01E07.1080p.mkv');
  });

  test('audio channels are not episodes', () {
    final f = files([('Show.S01.DDP5.1/Show.Ep01.mkv', gb), ('Show.S01.DDP5.1/Show.Ep05.mkv', gb)]);
    expect(pick(f, 1, 5), 'Show.S01.DDP5.1/Show.Ep05.mkv');
    expect(pick(f, 1, 1), 'Show.S01.DDP5.1/Show.Ep01.mkv');
  });

  test('so= in the magnet', () {
    expect(selectedFileIndex('magnet:?xt=urn:btih:abc&dn=x&so=3'), 3);
    expect(selectedFileIndex('magnet:?xt=urn:btih:abc&dn=x'), isNull);
    expect(withoutFileSelection('magnet:?xt=urn:btih:abc&dn=x&so=3&tr=t'),
        'magnet:?xt=urn:btih:abc&dn=x&tr=t');
  });

  Map<int, String?> season(List<String> t) => {for (var i = 0; i < t.length; i++) i + 1: t[i]};

  test('Samurai Jack numbering', () {
    final seasons = {
      1: season(['I', 'II', 'III', 'IV', 'VII', 'V', 'IX', 'X', 'VIII', 'XI', 'VI', 'XII', 'XIII']),
      2: season(['XIV', 'XV', 'XVI', 'XVII', 'XVIII', 'XIX', 'XX', 'XXI', 'XXII', 'XXIII', 'XXIV', 'XXV', 'XXVI']),
    };
    expect(releaseEpisode(seasons, 1, 7), 9);
    expect(releaseEpisode(seasons, 1, 5), 7);
    expect(releaseEpisode(seasons, 1, 1), isNull);
    expect(releaseEpisode(seasons, 2, 1), isNull);
  });

  test('normal titles keep the number', () {
    expect(releaseEpisode({1: season(['Pilot', 'Civil War', 'Mild', 'X', 'Chapter Two'])}, 1, 4), isNull);
    final mando = {
      1: season([for (var i = 1; i <= 8; i++) 'Chapter $i: Title']),
      2: season([for (var i = 9; i <= 16; i++) 'Chapter $i: Title']),
    };
    expect(releaseEpisode(mando, 2, 1), isNull);
  });
}
