import 'package:flutter_test/flutter_test.dart';
import 'package:peanutbutter/graphql/queries.dart';
import 'package:peanutbutter/models.dart';

void main() {
  test('the provider filter is only in its own catalog query', () {
    // Servers before 0.3.10 reject an unknown filter field.
    expect(GET_CATALOG.contains('\$service'), isFalse);
    expect(GET_CATALOG_BY_SERVICE.contains('\$service: String'), isTrue);
    expect(GET_CATALOG_BY_SERVICE.contains('service: \$service'), isTrue);
  });

  test('the service is only sent when one is picked', () {
    const all = CatalogFilter(sort: 'TRENDING');
    expect(all.toVariables(page: 1).containsKey('service'), isFalse);
    final netflix = all.copyWith(service: 'netflix');
    expect(netflix.toVariables(page: 1)['service'], 'netflix');
    expect(netflix.copyWith(clearService: true).service, isNull);
    // Only on Trending: a leftover pick doesn't filter another sort.
    expect(netflix.copyWith(sort: 'POPULARITY').toVariables(page: 1).containsKey('service'), isFalse);
  });
}
