import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../platform/device_profile.dart';
import '../platform/input_policy.dart';
import '../tv.dart';
import 'tv_chrome.dart';

/// Text field that D-pad can highlight. On Android TV:
/// - Arrows move between fields.
/// - Select opens a fullscreen soft-keyboard screen (full IME, no stroke).
class TvTextField extends StatefulWidget {
  const TvTextField({
    super.key,
    this.controller,
    this.focusNode,
    this.chromeFocus,
    this.decoration,
    this.obscureText = false,
    this.autofocus = false,
    this.keyboardType,
    this.textInputAction,
    this.maxLines = 1,
    this.debugLabel,
    this.onChanged,
    this.onSubmitted,
    this.onMoveDown,
    this.onMoveUp,
    this.onMoveLeft,
    this.onMoveRight,
    this.pill = false,
    this.enterEditing = false,
  });

  final TextEditingController? controller;
  final FocusNode? focusNode;
  final FocusNode? chromeFocus;
  final InputDecoration? decoration;
  final bool obscureText;
  final bool autofocus;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final int? maxLines;
  final String? debugLabel;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final VoidCallback? onMoveDown;
  final VoidCallback? onMoveUp;
  final VoidCallback? onMoveLeft;
  final VoidCallback? onMoveRight;
  final bool pill;
  final bool enterEditing;

  @override
  State<TvTextField> createState() => TvTextFieldState();
}

class TvTextFieldState extends State<TvTextField> {
  late final FocusNode _chrome;
  late final FocusNode _input;
  late final bool _ownsChrome;
  late final bool _ownsInput;
  bool _editing = false;

  bool get _androidTv => isAndroidTv;

  @override
  void initState() {
    super.initState();
    _ownsChrome = widget.chromeFocus == null;
    _chrome = widget.chromeFocus ?? FocusNode(debugLabel: widget.debugLabel ?? 'tv-field-chrome');
    _ownsInput = widget.focusNode == null;
    _input = widget.focusNode ?? FocusNode(debugLabel: 'tv-field-input');
    if (_androidTv) {
      _input.skipTraversal = true;
      _input.canRequestFocus = false;
      _input.onKeyEvent = _onInputKey;
    }
    _chrome.addListener(_onChrome);
    if (_androidTv && (widget.autofocus || widget.enterEditing)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _chrome.requestFocus();
        if (widget.enterEditing) _beginEdit();
      });
    }
  }

  @override
  void dispose() {
    _chrome.removeListener(_onChrome);
    if (_androidTv) _input.onKeyEvent = null;
    if (_ownsChrome) _chrome.dispose();
    if (_ownsInput) _input.dispose();
    super.dispose();
  }

  void _onChrome() => setState(() {});

  void _hideIme() {
    SystemChannels.textInput.invokeMethod('TextInput.hide');
  }

  void _beginEdit() {
    if (DeviceProfile.current.usesSoftKeyboardOverlay) {
      unawaited(_beginFullscreenEdit());
      return;
    }
    setState(() => _editing = true);
    _input.canRequestFocus = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_editing) return;
      _input.requestFocus();
      _hideIme();
      Future<void>.delayed(const Duration(milliseconds: 80), () {
        if (mounted && _editing) _hideIme();
      });
    });
  }

  Future<void> _beginFullscreenEdit() async {
    final title = widget.decoration?.labelText ??
        widget.decoration?.hintText ??
        widget.debugLabel ??
        'Enter text';
    final result = await InputPolicy.forProfile(DeviceProfile.current).editText(
      context,
      title: title,
      initial: widget.controller?.text ?? '',
      hint: widget.decoration?.hintText,
      obscureText: widget.obscureText,
      keyboardType: widget.keyboardType ?? TextInputType.text,
      textInputAction: widget.textInputAction ?? TextInputAction.done,
    );
    if (!mounted || result == null) return;
    widget.controller?.value = TextEditingValue(
      text: result,
      selection: TextSelection.collapsed(offset: result.length),
    );
    widget.onChanged?.call(result);
    widget.onSubmitted?.call(result);
  }

  void focusChrome() {
    if (!mounted) return;
    _endEdit();
    if (_chrome.canRequestFocus) _chrome.requestFocus();
  }

  void focusAndEdit() {
    if (!mounted) return;
    _chrome.requestFocus();
    _beginEdit();
  }

  void endEdit() => _endEdit();

  void _endEdit() {
    _hideIme();
    _input.unfocus();
    _input.canRequestFocus = false;
    if (_editing) setState(() => _editing = false);
    if (_chrome.canRequestFocus) _chrome.requestFocus();
  }

  KeyEventResult _move(LogicalKeyboardKey key) {
    if (key == LogicalKeyboardKey.arrowDown) {
      _endEdit();
      if (widget.onMoveDown != null) {
        widget.onMoveDown!();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      _endEdit();
      if (widget.onMoveUp != null) {
        widget.onMoveUp!();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      _endEdit();
      if (widget.onMoveLeft != null) {
        widget.onMoveLeft!();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      _endEdit();
      if (widget.onMoveRight != null) {
        widget.onMoveRight!();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    return KeyEventResult.ignored;
  }

  KeyEventResult _onChromeKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;

    final moved = _move(key);
    if (moved != KeyEventResult.ignored) return moved;

    final activate = key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.gameButtonA;
    if (activate) {
      if (_editing) {
        widget.onSubmitted?.call(widget.controller?.text ?? '');
        _endEdit();
      } else {
        _beginEdit();
      }
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.escape ||
        key == LogicalKeyboardKey.goBack ||
        key == LogicalKeyboardKey.browserBack) {
      if (_editing) {
        _endEdit();
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  KeyEventResult _onInputKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;

    final moved = _move(key);
    if (moved == KeyEventResult.handled) return moved;

    if (key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.gameButtonA) {
      widget.onSubmitted?.call(widget.controller?.text ?? '');
      _endEdit();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape ||
        key == LogicalKeyboardKey.goBack ||
        key == LogicalKeyboardKey.browserBack) {
      _endEdit();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    if (!_androidTv) {
      return TextField(
        controller: widget.controller,
        focusNode: _input,
        autofocus: widget.autofocus,
        obscureText: widget.obscureText,
        keyboardType: widget.keyboardType,
        textInputAction: widget.textInputAction,
        maxLines: widget.maxLines,
        onChanged: widget.onChanged,
        onSubmitted: widget.onSubmitted,
        scrollPadding: const EdgeInsets.fromLTRB(24, 80, 24, 220),
        decoration: widget.decoration,
      );
    }

    final seed = Theme.of(context).colorScheme.primary;
    final highlighted = _chrome.hasFocus || _editing;
    final radius = widget.pill ? 24.0 : 12.0;
    final hint = widget.decoration?.hintText;
    final text = widget.controller?.text ?? '';

    final Widget inner;
    if (_editing) {
      // TextInputType.none keeps soft IME closed on TV while still opening a
      // TextInputConnection so adb `input text` / hardware keys work.
      inner = TextField(
        controller: widget.controller,
        focusNode: _input,
        autofocus: true,
        obscureText: widget.obscureText,
        keyboardType: TextInputType.none,
        textInputAction: widget.textInputAction,
        maxLines: widget.maxLines,
        onChanged: widget.onChanged,
        onSubmitted: (value) {
          widget.onSubmitted?.call(value);
          _endEdit();
        },
        scrollPadding: EdgeInsets.zero,
        style: const TextStyle(color: Colors.white, fontSize: 16),
        cursorColor: seed,
        decoration: InputDecoration(
          isDense: true,
          hintText: hint,
          hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.38), fontSize: 16),
          border: InputBorder.none,
          contentPadding: EdgeInsets.zero,
        ),
      );
    } else {
      inner = text.isEmpty
          ? Text(
              hint ?? '',
              maxLines: widget.maxLines,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: Colors.white.withValues(alpha: 0.38), fontSize: 16),
            )
          : Text(
              widget.obscureText ? '•' * text.length : text,
              maxLines: widget.maxLines,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 16),
            );
    }

    final field = AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: highlighted ? const Color(0xFF1E2430) : const Color(0xFF121218),
        borderRadius: BorderRadius.circular(radius),
      ),
      child: inner,
    );

    return TvFocus(
      allowHorizontal: widget.onMoveLeft == null && widget.onMoveRight == null,
      child: Focus(
        focusNode: _chrome,
        descendantsAreFocusable: _editing,
        descendantsAreTraversable: false,
        onKeyEvent: _onChromeKey,
        child: GestureDetector(
          onTap: () {
            if (_chrome.canRequestFocus) _chrome.requestFocus();
          },
          child: field,
        ),
      ),
    );
  }
}
