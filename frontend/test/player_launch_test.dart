import 'package:flutter_test/flutter_test.dart';
import 'package:peanutbutter/player_launch.dart';

void main() {
  tearDown(PlayerLaunch.endPlay);

  test('Play drops a trailer that is still loading', () {
    final trailer = PlayerLaunch.beginTrailer()!;
    expect(PlayerLaunch.trailerWanted(trailer), isTrue);
    expect(PlayerLaunch.beginPlay(), isTrue);
    expect(PlayerLaunch.trailerWanted(trailer), isFalse);
  });

  test('a trailer cannot start while a play is starting', () {
    expect(PlayerLaunch.beginPlay(), isTrue);
    expect(PlayerLaunch.beginTrailer(), isNull);
    PlayerLaunch.endPlay();
    expect(PlayerLaunch.beginTrailer(), isNotNull);
  });

  test('a double press starts one play', () {
    expect(PlayerLaunch.beginPlay(), isTrue);
    expect(PlayerLaunch.beginPlay(), isFalse);
  });

  test('a lost play does not leave the buttons dead', () {
    final start = DateTime(2026);
    expect(PlayerLaunch.beginPlay(now: start), isTrue);
    expect(PlayerLaunch.beginPlay(now: start.add(const Duration(minutes: 6))), isTrue);
  });

  test('a newer trailer replaces an older one', () {
    final first = PlayerLaunch.beginTrailer()!;
    final second = PlayerLaunch.beginTrailer()!;
    expect(PlayerLaunch.trailerWanted(first), isFalse);
    expect(PlayerLaunch.trailerWanted(second), isTrue);
  });
}
