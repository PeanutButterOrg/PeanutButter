import 'package:flutter_test/flutter_test.dart';
import 'package:peanutbutter/models.dart';

void main() {
  test('trending cards read service tags; other rows have none', () {
    final t = TitleItem.fromJson({
      'id': '1',
      'title': 'Godzilla Minus One',
      'services': [
        {'id': 'netflix', 'name': 'Netflix'},
        {'id': 'toppicks', 'name': 'Top Picks'},
      ],
    });
    expect(t.services.map((s) => s.badge.label), ['N', 'TOP']);
    expect(t.copyWith().services.length, 2);
    expect(TitleItem.fromJson({'id': '2', 'title': 'x'}).services, isEmpty);
  });
}
