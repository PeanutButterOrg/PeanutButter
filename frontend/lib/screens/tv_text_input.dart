import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';
import '../widgets/tv_chrome.dart';

/// Fullscreen text entry for Android TV — full soft keyboard, no field stroke.
class TvTextInputScreen extends StatefulWidget {
  const TvTextInputScreen({
    super.key,
    required this.title,
    this.initial = '',
    this.hint,
    this.obscureText = false,
    this.keyboardType = TextInputType.text,
    this.textInputAction = TextInputAction.done,
  });

  final String title;
  final String initial;
  final String? hint;
  final bool obscureText;
  final TextInputType keyboardType;
  final TextInputAction textInputAction;

  @override
  State<TvTextInputScreen> createState() => _TvTextInputScreenState();
}

class _TvTextInputScreenState extends State<TvTextInputScreen> {
  late final TextEditingController _controller;
  final FocusNode _fieldFocus = FocusNode(debugLabel: 'tv-input-field');
  final FocusNode _doneFocus = FocusNode(debugLabel: 'tv-input-done');

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initial);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _fieldFocus.requestFocus();
      SystemChannels.textInput.invokeMethod('TextInput.show');
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _fieldFocus.dispose();
    _doneFocus.dispose();
    super.dispose();
  }

  void _submit() {
    Navigator.of(context).pop(_controller.text);
  }

  @override
  Widget build(BuildContext context) {
    final body = SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.title,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 28,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 28),
            TextField(
              controller: _controller,
              focusNode: _fieldFocus,
              autofocus: true,
              obscureText: widget.obscureText,
              keyboardType: widget.keyboardType,
              textInputAction: widget.textInputAction,
              style: const TextStyle(color: Colors.white, fontSize: 22),
              cursorColor: AppTheme.seed,
              decoration: InputDecoration(
                hintText: widget.hint,
                hintStyle: const TextStyle(color: Colors.white38),
                filled: true,
                fillColor: const Color(0xFF1A1A22),
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 18,
                ),
              ),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 24),
            Align(
              alignment: Alignment.centerRight,
              child: TvFocus(
                child: FilledButton(
                  focusNode: _doneFocus,
                  onPressed: _submit,
                  child: const Text('Done'),
                ),
              ),
            ),
          ],
        ),
      ),
    );

    return Scaffold(
      backgroundColor: PtTheme.bg,
      body: TvBackScope(
        popOnFirstBack: true,
        header: const SizedBox.shrink(),
        body: body,
      ),
    );
  }
}
