import 'package:flutter_test/flutter_test.dart';
import 'package:peanutbutter/models.dart';

void main() {
  const episode = 22 * 60 * 1000;
  MediaSegment intro(int? end) =>
      MediaSegment(kind: 'INTRO', label: 'Skip Intro', startMs: 10000, endMs: end);

  test('Skip goes away when the intro ends', () {
    final s = intro(40000);
    expect(s.contains(20000, durationMs: episode), isTrue);
    expect(s.contains(40000, durationMs: episode), isFalse);
  });

  test('a missing end time does not keep Skip up for the whole episode', () {
    final s = intro(null);
    expect(s.contains(60000, durationMs: episode), isTrue);
    expect(s.contains(100000, durationMs: episode), isFalse);
  });

  test('an absurd end time is treated as missing', () {
    expect(intro(15 * 60 * 1000).contains(300000, durationMs: episode), isFalse);
    expect(intro(episode - 1000).contains(300000, durationMs: episode), isFalse);
  });

  test('skipping lands where the button stops showing', () {
    for (final s in [intro(40000), intro(null), intro(15 * 60 * 1000)]) {
      expect(s.contains(s.skipTargetMs(durationMs: episode), durationMs: episode), isFalse);
    }
  });

  test('credits still run to the end', () {
    const credits = MediaSegment(kind: 'CREDITS', label: 'Credits', startMs: 1200000);
    expect(credits.contains(episode - 1000, durationMs: episode), isTrue);
  });
}
