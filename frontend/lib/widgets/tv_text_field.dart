import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'tv_chrome.dart';

class _FieldDownIntent extends Intent {
  const _FieldDownIntent();
}

class _FieldLeftIntent extends Intent {
  const _FieldLeftIntent();
}

class _FieldRightIntent extends Intent {
  const _FieldRightIntent();
}

/// Text field that D-pad can highlight, but does not type until Select / tap.
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

  bool get _androidTv => !kIsWeb && Platform.isAndroid;

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
    }
    _chrome.addListener(_onChrome);
    _input.addListener(_onInput);
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
    _input.removeListener(_onInput);
    if (_ownsChrome) _chrome.dispose();
    if (_ownsInput) _input.dispose();
    super.dispose();
  }

  void _onChrome() {
    setState(() {});
  }

  void _onInput() {
    if (_input.hasFocus) {
      if (!_editing) setState(() => _editing = true);
      return;
    }
    if (_editing) setState(() => _editing = false);
  }

  void _beginEdit() {
    setState(() => _editing = true);
    _input.canRequestFocus = true;
    _input.requestFocus();
  }

  /// Focus the field chrome without opening the keyboard (for D-pad navigation).
  void focusChrome() {
    if (!mounted) return;
    _endEdit();
    if (_chrome.canRequestFocus) _chrome.requestFocus();
  }

  /// Focus the field and open the on-screen keyboard (Android TV).
  void focusAndEdit() {
    if (!mounted) return;
    _chrome.requestFocus();
    _beginEdit();
  }

  void endEdit() => _endEdit();

  void _endEdit() {
    _input.unfocus();
    _input.canRequestFocus = false;
    setState(() => _editing = false);
    if (_chrome.canRequestFocus) _chrome.requestFocus();
  }

  KeyEventResult _onChromeKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final activate = key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.gameButtonA ||
        key == LogicalKeyboardKey.space;
    if (activate) {
      _beginEdit();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  KeyEventResult _onInputKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape ||
        key == LogicalKeyboardKey.goBack ||
        key == LogicalKeyboardKey.browserBack) {
      _endEdit();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown && widget.onMoveDown != null) {
      _endEdit();
      widget.onMoveDown!();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft && widget.onMoveLeft != null) {
      _endEdit();
      widget.onMoveLeft!();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight && widget.onMoveRight != null) {
      _endEdit();
      widget.onMoveRight!();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight) {
      _endEdit();
      return KeyEventResult.ignored;
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
    final field = AbsorbPointer(
      absorbing: !_editing,
      child: Focus(
        onKeyEvent: _onInputKey,
        child: TextField(
          controller: widget.controller,
          focusNode: _input,
          autofocus: false,
          readOnly: !_editing,
          showCursor: _editing,
          enableInteractiveSelection: _editing,
          obscureText: widget.obscureText,
          keyboardType: widget.keyboardType,
          textInputAction: widget.textInputAction,
          maxLines: widget.maxLines,
          onChanged: widget.onChanged,
          onSubmitted: (value) {
            widget.onSubmitted?.call(value);
            _endEdit();
          },
          scrollPadding: EdgeInsets.zero,
          decoration: (widget.decoration ?? const InputDecoration()).copyWith(
            filled: true,
            fillColor: const Color(0xFF121218),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(radius), borderSide: BorderSide.none),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(radius), borderSide: BorderSide.none),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(radius), borderSide: BorderSide.none),
            disabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(radius), borderSide: BorderSide.none),
          ),
        ),
      ),
    );

    Widget chrome = Focus(
      focusNode: _chrome,
      descendantsAreFocusable: _editing,
      descendantsAreTraversable: false,
      onKeyEvent: _onChromeKey,
      child: GestureDetector(
        onTap: _beginEdit,
        child: widget.pill
            ? field
            : AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(radius),
                  border: Border.all(
                    color: highlighted ? seed : const Color(0x22FFFFFF),
                    width: highlighted ? 2 : 1,
                  ),
                ),
                child: field,
              ),
      ),
    );

    final shortcuts = <ShortcutActivator, Intent>{
      if (widget.onMoveDown != null) const SingleActivator(LogicalKeyboardKey.arrowDown): const _FieldDownIntent(),
      if (widget.onMoveLeft != null) const SingleActivator(LogicalKeyboardKey.arrowLeft): const _FieldLeftIntent(),
      if (widget.onMoveRight != null) const SingleActivator(LogicalKeyboardKey.arrowRight): const _FieldRightIntent(),
    };
    if (shortcuts.isNotEmpty) {
      chrome = Actions(
        actions: {
          _FieldDownIntent: CallbackAction<_FieldDownIntent>(
            onInvoke: (_) {
              _endEdit();
              widget.onMoveDown?.call();
              return null;
            },
          ),
          _FieldLeftIntent: CallbackAction<_FieldLeftIntent>(
            onInvoke: (_) {
              _endEdit();
              widget.onMoveLeft?.call();
              return null;
            },
          ),
          _FieldRightIntent: CallbackAction<_FieldRightIntent>(
            onInvoke: (_) {
              _endEdit();
              widget.onMoveRight?.call();
              return null;
            },
          ),
        },
        child: Shortcuts(
          shortcuts: shortcuts,
          child: chrome,
        ),
      );
    }

    return TvFocus(
      allowHorizontal: widget.onMoveLeft == null && widget.onMoveRight == null,
      child: chrome,
    );
  }
}
