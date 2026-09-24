import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peanutbutter/tv.dart';
import 'package:peanutbutter/widgets/tv_text_field.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    debugIsAndroidTvOverride = true;
  });

  tearDown(() {
    debugIsAndroidTvOverride = null;
  });

  Future<void> pumpField(
    WidgetTester tester, {
    required TextEditingController controller,
    required FocusNode chrome,
    VoidCallback? onMoveDown,
    VoidCallback? onMoveUp,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TvTextField(
            controller: controller,
            chromeFocus: chrome,
            decoration: const InputDecoration(hintText: 'Server address'),
            onMoveDown: onMoveDown,
            onMoveUp: onMoveUp,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('chrome Select enters edit and shows typed text', (tester) async {
    final controller = TextEditingController();
    final chrome = FocusNode(debugLabel: 'url-chrome');
    await pumpField(tester, controller: controller, chrome: chrome);

    chrome.requestFocus();
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'http://10.0.0.110:3001/');
    await tester.pumpAndSettle();
    expect(controller.text, 'http://10.0.0.110:3001/');
  });

  testWidgets('D-pad down from chrome moves focus via callback', (tester) async {
    final controller = TextEditingController();
    final chrome = FocusNode(debugLabel: 'url-chrome');
    var movedDown = false;
    await pumpField(
      tester,
      controller: controller,
      chrome: chrome,
      onMoveDown: () => movedDown = true,
    );

    chrome.requestFocus();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(movedDown, isTrue);
  });

  testWidgets('pairing code digits stay in controller', (tester) async {
    final controller = TextEditingController();
    final chrome = FocusNode(debugLabel: 'token-chrome');
    await pumpField(tester, controller: controller, chrome: chrome);

    chrome.requestFocus();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '204295');
    await tester.pumpAndSettle();
    expect(controller.text, '204295');
  });

  testWidgets('arrow down while editing ends edit then moves', (tester) async {
    final controller = TextEditingController(text: 'http://10.0.0.110:3001/');
    final chrome = FocusNode(debugLabel: 'url-chrome');
    var movedDown = false;
    await pumpField(
      tester,
      controller: controller,
      chrome: chrome,
      onMoveDown: () => movedDown = true,
    );

    chrome.requestFocus();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(movedDown, isTrue);
    expect(find.byType(TextField), findsNothing);
  });
}
