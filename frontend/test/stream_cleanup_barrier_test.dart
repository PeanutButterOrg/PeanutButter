import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:peanutbutter/stream_cleanup_barrier.dart';

void main() {
  test('new playback waits for native teardown AND cache cleanup', () async {
    final barrier = StreamCleanupBarrier();
    final teardown = Completer<void>();
    final cacheDeletion = Completer<void>();
    barrier.add(teardown.future.then((_) => cacheDeletion.future));
    var started = false;
    final playback = barrier.wait().then((_) => started = true);

    // Leaving the page does not complete native teardown.
    await Future<void>.delayed(Duration.zero);
    expect(started, isFalse);
    teardown.complete();
    await Future<void>.delayed(Duration.zero);
    expect(started, isFalse);

    cacheDeletion.complete();
    await playback;
    expect(started, isTrue);
    await barrier.wait();
  });

  test('cleanup added during a wait cannot overwrite older cleanup', () async {
    final barrier = StreamCleanupBarrier();
    final first = Completer<void>();
    final second = Completer<void>();
    barrier.add(first.future);
    var started = false;
    final playback = barrier.wait().then((_) => started = true);
    barrier.add(second.future);

    second.complete();
    await Future<void>.delayed(Duration.zero);
    expect(started, isFalse);
    first.complete();
    await playback;
    expect(started, isTrue);
  });

  test('cleanup registered during a wait must also finish', () async {
    final barrier = StreamCleanupBarrier();
    final first = Completer<void>();
    final second = Completer<void>();
    barrier.add(first.future);
    var started = false;
    final playback = barrier.wait().then((_) => started = true);
    barrier.add(second.future);

    first.complete();
    await Future<void>.delayed(Duration.zero);
    expect(started, isFalse);
    second.complete();
    await playback;
    expect(started, isTrue);
  });

  test('failed cleanup releases waiting playback and permits another wait',
      () async {
    final barrier = StreamCleanupBarrier();
    final cleanup = Completer<void>();
    barrier.add(cleanup.future);
    final playback = barrier.wait();
    cleanup.completeError(StateError('native teardown failed'));
    await playback;
    await barrier.wait();
  });
}
