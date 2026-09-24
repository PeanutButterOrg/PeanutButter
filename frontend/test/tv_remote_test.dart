import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peanutbutter/platform/device_profile.dart';
import 'package:peanutbutter/tv.dart';
import 'package:peanutbutter/tv_nav.dart';
import 'package:peanutbutter/tv_remote.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    debugIsAndroidTvOverride = true;
    DeviceProfile.debugOverride = const AndroidTvProfile();
  });

  tearDown(() {
    debugIsAndroidTvOverride = null;
    DeviceProfile.debugOverride = null;
  });

  test('tvNavDirFromKey maps arrows and aliases', () {
    expect(
      tvNavDirFromKey(
        const KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.arrowDown,
          logicalKey: LogicalKeyboardKey.arrowDown,
          timeStamp: Duration.zero,
        ),
      ),
      TvNavDir.down,
    );
    expect(
      tvNavDirFromKey(
        const KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.pageDown,
          logicalKey: LogicalKeyboardKey.pageDown,
          timeStamp: Duration.zero,
        ),
      ),
      TvNavDir.down,
    );
    expect(
      tvNavDirFromKey(
        const KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.mediaFastForward,
          logicalKey: LogicalKeyboardKey.mediaFastForward,
          timeStamp: Duration.zero,
        ),
      ),
      TvNavDir.right,
    );
  });

  test('TvNavController.move returns false when nothing handled', () {
    final nav = TvNavController(strategies: const []);
    addTearDown(nav.dispose);
    // No primary focus → false
    expect(nav.move(TvNavDir.down), isFalse);
  });

  test('tvIsActivateKey covers Select/Enter/gamepad A', () {
    expect(tvIsActivateKey(LogicalKeyboardKey.select), isTrue);
    expect(tvIsActivateKey(LogicalKeyboardKey.enter), isTrue);
    expect(tvIsActivateKey(LogicalKeyboardKey.gameButtonA), isTrue);
    expect(tvIsActivateKey(LogicalKeyboardKey.escape), isFalse);
  });
}
