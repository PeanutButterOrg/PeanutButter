import 'package:flutter_test/flutter_test.dart';
import 'package:peanutbutter/platform/stream_seek_controller.dart';

void main() {
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
