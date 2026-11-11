import 'package:flutter_test/flutter_test.dart';
import 'package:peanutbutter/content_languages.dart';

void main() {
  test('English is always offered for subtitles, after the chosen languages', () {
    expect(subtitleLanguageCodes(['hi']), ['hi', 'en']);
    expect(subtitleLanguageCodes(['hi', 'en']), ['hi', 'en']);
    expect(subtitleLanguageCodes(['EN', 'ja']), ['en', 'ja']);
    expect(subtitleLanguageCodes(const []), ['en']);
    expect(subtitleLanguageCodes(['all']), ['en']);
    expect(subtitleLanguageCodes(['hi', ' hi ']), ['hi', 'en']);
  });
}
