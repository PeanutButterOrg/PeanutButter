import 'package:flutter_test/flutter_test.dart';
import 'package:peanutbutter/models.dart';

StreamSource _src(String id, int score, {String kind = 'torrent', String url = ''}) => StreamSource(
      id: id,
      title: id,
      magnet: kind == 'torrent' ? 'magnet:?xt=urn:btih:$id' : '',
      seeders: 0,
      peers: 0,
      rating: 1,
      health: 'unknown',
      size: '',
      tracker: '',
      indexer: '',
      kind: kind,
      url: url,
      score: score,
    );

void main() {
  test('merged language lists follow the server score, ties keep order', () {
    final english = [_src('en-a', 900), _src('en-b', 400)];
    final hindi = [_src('hi-a', 1000), _src('hi-b', 400)];
    final ranked = rankByServerScore([...english, ...hindi]);
    expect(ranked.map((s) => s.id), ['hi-a', 'en-a', 'en-b', 'hi-b']);
  });

  test('direct links are keyed by URL and parsed from the server', () {
    final http = StreamSource.fromJson({
      'id': 'http:1',
      'title': 'Troy (2004) WEB-DL [1080p]',
      'magnet': '',
      'kind': 'http',
      'url': 'https://cdn.example/troy.mkv',
      'score': 1200,
      'providers': ['HDHub'],
      'headers': [
        {'name': 'User-Agent', 'value': 'Mozilla/5.0'},
      ],
    });
    expect(http.isHttp, isTrue);
    expect(http.key, 'https://cdn.example/troy.mkv');
    expect(http.headers, {'User-Agent': 'Mozilla/5.0'});
    expect(http.providers, ['HDHub']);
    // Older servers: no kind / score fields at all.
    final old = StreamSource.fromJson({'id': 'x', 'title': 't', 'magnet': 'magnet:?xt=urn:btih:x'});
    expect(old.isHttp, isFalse);
    expect(old.kind, 'torrent');
    expect(old.score, 0);
    expect(old.key, 'magnet:?xt=urn:btih:x');
  });
}
