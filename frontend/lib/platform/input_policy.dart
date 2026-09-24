import 'package:flutter/material.dart';

import '../screens/tv_text_input.dart';
import 'device_profile.dart';

/// How text entry works on this device.
abstract class InputPolicy {
  /// Edit [initial] in a dedicated fullscreen screen when true.
  bool get usesFullscreenEditor;

  Future<String?> editText(
    BuildContext context, {
    required String title,
    String initial = '',
    String? hint,
    bool obscureText = false,
    TextInputType keyboardType = TextInputType.text,
    TextInputAction textInputAction = TextInputAction.done,
  });

  static InputPolicy forProfile(DeviceProfile profile) {
    if (profile.usesSoftKeyboardOverlay) return const TvInputPolicy();
    return const DesktopInputPolicy();
  }
}

class DesktopInputPolicy implements InputPolicy {
  const DesktopInputPolicy();

  @override
  bool get usesFullscreenEditor => false;

  @override
  Future<String?> editText(
    BuildContext context, {
    required String title,
    String initial = '',
    String? hint,
    bool obscureText = false,
    TextInputType keyboardType = TextInputType.text,
    TextInputAction textInputAction = TextInputAction.done,
  }) async {
    // Inline editing — callers keep using TextField / TvTextField.
    return null;
  }
}

class TvInputPolicy implements InputPolicy {
  const TvInputPolicy();

  @override
  bool get usesFullscreenEditor => true;

  @override
  Future<String?> editText(
    BuildContext context, {
    required String title,
    String initial = '',
    String? hint,
    bool obscureText = false,
    TextInputType keyboardType = TextInputType.text,
    TextInputAction textInputAction = TextInputAction.done,
  }) {
    return Navigator.of(context, rootNavigator: true).push<String>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => TvTextInputScreen(
          title: title,
          initial: initial,
          hint: hint,
          obscureText: obscureText,
          keyboardType: keyboardType,
          textInputAction: textInputAction,
        ),
      ),
    );
  }
}
