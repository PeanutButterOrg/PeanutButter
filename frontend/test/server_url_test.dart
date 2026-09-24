import 'package:flutter_test/flutter_test.dart';
import 'package:peanutbutter/graphql/client.dart';

void main() {
  test('normalizeServerBase keeps explicit :3001', () {
    expect(
      normalizeServerBase('http://10.0.0.110:3001/'),
      'http://10.0.0.110:3001',
    );
  });

  test('normalizeServerBase strips trailing slash without inventing a port', () {
    expect(
      normalizeServerBase('http://10.0.0.110/'),
      'http://10.0.0.110',
    );
  });
}
