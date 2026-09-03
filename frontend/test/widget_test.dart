import 'package:flutter_test/flutter_test.dart';
import 'package:peanutbutter/content_languages.dart';
import 'package:peanutbutter/graphql/client.dart';
import 'package:peanutbutter/models.dart';
import 'package:peanutbutter/widgets/filter_bar.dart';

void main() {
  test('normalizeServerBase strips /graphql', () {
    expect(
      normalizeServerBase('http://127.0.0.1:8080/graphql'),
      'http://127.0.0.1:8080',
    );
  });

  test('see all heading names the current rail and kind', () {
    expect(
      catalogHeading(const CatalogFilter(kind: 'MOVIE', sort: 'CONTINUE_WATCHING')),
      'Continue watching movies',
    );
    expect(
      catalogHeading(const CatalogFilter(kind: 'SERIES', sort: 'TRENDING')),
      'Trending series',
    );
    expect(
      catalogHeading(const CatalogFilter(kind: 'ANIME', sort: 'DATE_ADDED')),
      'Last added anime',
    );
  });

  test('catalog filter omits default year min', () {
    final vars = const CatalogFilter().toVariables(page: 2);
    expect(vars['page'], 2);
    expect(vars['yearMin'], isNull);
    expect(vars['sort'], 'POPULARITY');
  });

  test('exact year filter matches that year only', () {
    const filter = CatalogFilter(yearMin: 1999, yearMax: 1999);
    expect(filter.selectedYear, 1999);
    expect(
      filter.matches(TitleItem.fromJson({
        'id': '00000000-0000-0000-0000-000000000010',
        'kind': 'MOVIE',
        'title': 'The Matrix',
        'year': 1999,
      })),
      isTrue,
    );
    expect(
      filter.matches(TitleItem.fromJson({
        'id': '00000000-0000-0000-0000-000000000011',
        'kind': 'MOVIE',
        'title': 'Heat',
        'year': 1995,
      })),
      isFalse,
    );
  });

  test('year and rating filters are sent when set', () {
    final vars = const CatalogFilter(yearMin: 2020, yearMax: 2029, ratingMin: 7).toVariables(page: 1);
    expect(vars['yearMin'], 2020);
    expect(vars['yearMax'], 2029);
    expect(vars['ratingMin'], 7);
  });

  test('title item parses graphql json', () {
    final item = TitleItem.fromJson({
      'id': '00000000-0000-0000-0000-000000000001',
      'kind': 'MOVIE',
      'title': 'The Matrix',
      'year': 1999,
      'posterUrl': 'https://example.com/p.jpg',
      'ratings': {'tmdbVoteAverage': 8.7},
      'genres': ['Science Fiction'],
    });
    expect(item.title, 'The Matrix');
    expect(item.displayRating, 8.7);
    expect(item.displayScore?.source, 'TMDB');
    expect(item.rtScore, isNull);
    expect(item.genres, ['Science Fiction']);
  });

  test('rotten tomatoes score is preferred on the title', () {
    final item = TitleItem.fromJson({
      'id': '00000000-0000-0000-0000-000000000002',
      'kind': 'MOVIE',
      'title': 'Heat',
      'ratings': {'tmdbVoteAverage': 8.2, 'rtScore': 87},
    });
    expect(item.rtScore, 87);
    expect(item.displayScore?.source, 'RT');
  });

  test('imdb rating is used when rotten tomatoes is missing', () {
    final item = TitleItem.fromJson({
      'id': '00000000-0000-0000-0000-000000000003',
      'kind': 'MOVIE',
      'title': 'Dune',
      'ratings': {'imdbRating': 8.0},
    });
    expect(item.displayScore?.source, 'IMDb');
    expect(item.displayScore?.label, '8.0');
  });

  test('preferred language helpers', () {
    expect(preferredLanguageCode(const []), isNull);
    expect(preferredLanguageCode(const ['all']), isNull);
    expect(preferredLanguageCode(const ['hi']), 'hi');
    expect(preferredLanguageCode(const ['en', 'hi']), 'en,hi');
    expect(preferredLanguageCodes(const ['en', 'all', 'hi']), ['en', 'hi']);
    expect(languageDisplayName('hi'), 'Hindi');
    expect(languageDisplayName('en,hi'), 'English, Hindi');
    expect(languageDisplayName(null), 'all languages');
  });
}

