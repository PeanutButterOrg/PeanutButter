import 'package:flutter_test/flutter_test.dart';
import 'package:peanutbutter/android_playback.dart';

void main() {
  test('urlWithAuth appends key for remote streams', () {
    final out = AndroidPlayback.urlWithAuth(
      'http://10.0.0.110:3001/stream/abc',
      '204295',
    );
    expect(out, contains('key=204295'));
    expect(out, startsWith('http://10.0.0.110:3001/stream/abc'));
  });

  test('urlWithAuth skips loopback', () {
    expect(
      AndroidPlayback.urlWithAuth('http://127.0.0.1:8080/stream/x', '204295'),
      'http://127.0.0.1:8080/stream/x',
    );
  });

  test('prefs round-trip includes vlc', () {
    expect(AndroidPlayback.fromPrefs('vlc'), AndroidPlaybackBackend.vlc);
    expect(AndroidPlayback.fromPrefs('external'), AndroidPlaybackBackend.external);
    expect(AndroidPlayback.fromPrefs('inApp'), AndroidPlaybackBackend.inApp);
    expect(AndroidPlayback.toPrefs(AndroidPlaybackBackend.vlc), 'vlc');
  });
}
