import 'package:flutter_test/flutter_test.dart';
import 'package:peanutbutter/android_playback.dart';
import 'package:peanutbutter/platform/device_profile.dart';
import 'package:peanutbutter/platform/playback_backend.dart';
import 'package:peanutbutter/platform/stream_seek_controller.dart';

void main() {
  tearDown(() {
    DeviceProfile.debugOverride = null;
  });

  test('PlaybackBackendFactory maps desktop to media_kit', () {
    DeviceProfile.debugOverride = const DesktopDeviceProfile();
    expect(
      PlaybackBackendFactory.resolveEngine(
        DeviceProfile.current,
        AndroidPlaybackBackend.vlc,
      ),
      PlaybackEngine.mediaKit,
    );
  });

  test('PlaybackBackendFactory maps TV to VLC by default', () {
    DeviceProfile.debugOverride = const AndroidTvProfile();
    expect(
      PlaybackBackendFactory.resolveEngine(
        DeviceProfile.current,
        AndroidPlaybackBackend.vlc,
      ),
      PlaybackEngine.vlc,
    );
  });

  test('PlaybackBackendFactory maps phone to Exo', () {
    DeviceProfile.debugOverride = const AndroidPhoneProfile();
    expect(
      PlaybackBackendFactory.resolveEngine(
        DeviceProfile.current,
        AndroidPlaybackBackend.inApp,
      ),
      PlaybackEngine.exo,
    );
  });

  test('StreamSeekController debounces then commits', () async {
    final commits = <Duration>[];
    final ctl = StreamSeekController(
      settle: const Duration(milliseconds: 50),
      onCommit: (t) async {
        commits.add(t);
      },
    );
    ctl.request(const Duration(seconds: 10));
    ctl.request(const Duration(seconds: 20));
    expect(commits, isEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(commits, [const Duration(seconds: 20)]);
    ctl.dispose();
  });
}
