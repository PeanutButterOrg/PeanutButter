import 'package:flutter_test/flutter_test.dart';
import 'package:peanutbutter/release_tags.dart';

void main() {
  test('reads resolution, source, codec and audio from release names', () {
    final a = ReleaseTags.parse('Interstellar.2014.2160p.UHD.BluRay.REMUX.HDR.HEVC.Atmos-FGT');
    expect([a.resolution, a.source, a.codec, a.audio], ['4K', 'Remux', 'HEVC', 'Atmos']);
    final b = ReleaseTags.parse('Dune Part Two (2024) [1080p] [WEBRip] [x265] [5.1]');
    expect([b.resolution, b.source, b.codec, b.audio], ['1080', 'WEB', 'HEVC', '5.1']);
    final c = ReleaseTags.parse('The.Office.S02E03.720p.HDTV.x264-LOL');
    expect([c.resolution, c.source, c.codec], ['720', 'HDTV', 'H.264']);
    final d = ReleaseTags.parse('Some Movie DV HDR10 2160p WEB-DL DDP5.1 H.265');
    expect([d.resolution, d.source, d.codec, d.audio], ['4K', 'DV', 'HEVC', '5.1']);
    expect(ReleaseTags.parse('Plain name').resolution, '');
  });
}
