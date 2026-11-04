import 'package:flutter_test/flutter_test.dart';
import 'package:peanutbutter/models.dart';
import 'package:peanutbutter/providers/catalog.dart';

Season _season(List<String> names) => Season(
      id: 's1',
      seasonNumber: 1,
      episodes: [
        for (var i = 0; i < names.length; i++)
          Episode(id: 'e${i + 1}', episodeNumber: i + 1, name: names[i]),
      ],
    );

void main() {
  List<int> order(Season s) => episodesInViewingOrder(s, episodeTitles([s]))
      .map((e) => e.episodeNumber)
      .toList();

  test('episodes follow their own numbering when the catalog is out of order', () {
    expect(order(_season(['I', 'II', 'IV', 'III'])), [1, 2, 4, 3]);
  });

  test('normal titles and clashing numbers keep the catalog order', () {
    expect(order(_season(['Pilot', 'The Second One'])), [1, 2]);
    expect(order(_season(['I', 'I', 'II'])), [1, 2, 3]);
  });

  test('a short page is requested again only while more is coming', () {
    int after(int items, bool hasNext) =>
        catalogPageAfter(page: 3, items: items, perPage: 50, hasNext: hasNext);
    expect(after(50, true), 3);
    expect(after(20, true), 2);
    expect(after(20, false), 3);
  });
}
