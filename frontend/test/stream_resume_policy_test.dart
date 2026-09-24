import 'package:flutter_test/flutter_test.dart';
import 'package:peanutbutter/stream_resume_policy.dart';

void main() {
  group('shouldShowStreamPicker', () {
    test('Resume with saved magnet skips picker', () {
      expect(
        shouldShowStreamPicker(
          fromBeginning: false,
          preferResume: true,
          hasSavedMagnet: true,
        ),
        isFalse,
      );
    });

    test('Resume without saved magnet shows picker', () {
      expect(
        shouldShowStreamPicker(
          fromBeginning: false,
          preferResume: true,
          hasSavedMagnet: false,
        ),
        isTrue,
      );
    });

    test('Play from beginning always shows picker', () {
      expect(
        shouldShowStreamPicker(
          fromBeginning: true,
          preferResume: true,
          hasSavedMagnet: true,
        ),
        isTrue,
      );
    });

    test('Fresh Play shows picker', () {
      expect(
        shouldShowStreamPicker(
          fromBeginning: false,
          preferResume: false,
          hasSavedMagnet: false,
        ),
        isTrue,
      );
    });
  });
}
