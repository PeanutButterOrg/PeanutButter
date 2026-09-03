import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../friendly_error.dart';
import '../graphql/client.dart';
import '../providers/catalog.dart';
import '../providers/settings.dart';
import '../theme.dart';
import '../tv.dart';
import '../widgets/tv_chrome.dart';
import '../widgets/tv_text_field.dart';

class PairingScreen extends ConsumerStatefulWidget {
  const PairingScreen({super.key});

  @override
  ConsumerState<PairingScreen> createState() => _PairingScreenState();
}

class _PairingScreenState extends ConsumerState<PairingScreen> {
  late final TextEditingController _url;
  late final TextEditingController _token;
  final FocusNode _urlFocus = FocusNode(debugLabel: 'pair-url');
  final FocusNode _tokenFocus = FocusNode(debugLabel: 'pair-token');
  final FocusNode _connectFocus = FocusNode(debugLabel: 'pair-connect');
  final FocusNode _findFocus = FocusNode(debugLabel: 'pair-find');
  bool _connecting = false;
  bool _finding = false;

  @override
  void initState() {
    super.initState();
    final saved = ref.read(settingsProvider);
    _url = TextEditingController(text: saved.serverUrl);
    _token = TextEditingController();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      if (isAndroidTv && _urlFocus.canRequestFocus) {
        _urlFocus.requestFocus();
      }
      if (saved.serverUrl.isEmpty) {
        final found = await ref.read(settingsProvider.notifier).discoverLocalhost();
        if (!mounted) return;
        if (found != null) _url.text = found;
      }
    });
  }

  @override
  void dispose() {
    _url.dispose();
    _token.dispose();
    _urlFocus.dispose();
    _tokenFocus.dispose();
    _connectFocus.dispose();
    _findFocus.dispose();
    super.dispose();
  }

  InputDecoration _field(String hint) {
    return InputDecoration(
      hintText: hint,
      isDense: true,
      filled: true,
      fillColor: const Color(0xFF121218),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppTheme.seed),
      ),
    );
  }

  Future<void> _connect() async {
    if (_connecting || _finding) return;
    setState(() => _connecting = true);
    final notifier = ref.read(settingsProvider.notifier);
    await notifier.runPairingAttempt(() async {
      await notifier.setServerUrl(_url.text);
      await notifier.setApiToken(_token.text);
      if (mounted) _token.text = ref.read(settingsProvider).apiToken;
      final reachable = await notifier.probeCurrent();
      if (!reachable) {
        await notifier.clearPairingAttempt(
          ref.read(settingsProvider).lastError ??
              'Cannot reach that server. Check the address and try again.',
        );
        return;
      }
      ref.invalidate(serverInfoProvider);
      try {
        await ref.read(serverInfoProvider.future).timeout(const Duration(seconds: 20));
        await notifier.markConnected();
        ref.invalidate(homeFeedProvider('MOVIE'));
        ref.invalidate(homeFeedProvider('SERIES'));
        ref.invalidate(homeFeedProvider('ANIME'));
      } catch (e) {
        await notifier.clearPairingAttempt(
          isUnauthorizedError(e)
              ? 'That pairing code was not accepted. Create a code in the server console and type it here.'
              : friendlyRequestError(e),
        );
      }
    });
    if (mounted) setState(() => _connecting = false);
  }

  Future<void> _findServer() async {
    if (_connecting || _finding) return;
    setState(() => _finding = true);
    final found = await ref.read(settingsProvider.notifier).discoverLocalhost();
    if (!mounted) return;
    if (found != null) _url.text = found;
    setState(() => _finding = false);
    if (isAndroidTv && _urlFocus.canRequestFocus) _urlFocus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final form = Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'PEANUTBUTTER',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: AppTheme.seed,
            fontWeight: FontWeight.w800,
            letterSpacing: 2.4,
            fontSize: 12,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          'Pair this device',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 8),
        const Text(
          'Sign in on the server console, create a 6-digit code, then type it here. Every TV and desktop needs its own code.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white54, height: 1.45, fontSize: 15),
        ),
        const SizedBox(height: 28),
        TvTextField(
          chromeFocus: _urlFocus,
          controller: _url,
          autofocus: isAndroidTv,
          keyboardType: TextInputType.url,
          textInputAction: TextInputAction.next,
          decoration: _field('Server address'),
          onMoveDown: () => _tokenFocus.requestFocus(),
          onSubmitted: (_) {
            if (isAndroidTv) {
              _tokenFocus.requestFocus();
            } else {
              _connect();
            }
          },
        ),
        const SizedBox(height: 12),
        TvTextField(
          chromeFocus: _tokenFocus,
          controller: _token,
          keyboardType: const TextInputType.numberWithOptions(decimal: false, signed: false),
          textInputAction: TextInputAction.done,
          decoration: _field('6-digit pairing code'),
          onMoveDown: () => _connectFocus.requestFocus(),
          onSubmitted: (_) => _connect(),
        ),
        const SizedBox(height: 20),
        TvFocus(
          allowHorizontal: false,
          child: FilledButton(
            focusNode: isAndroidTv ? _connectFocus : null,
            onPressed: (_connecting || _finding) ? null : _connect,
            child: Text(_connecting ? 'Connecting…' : 'Connect'),
          ),
        ),
        const SizedBox(height: 10),
        TvFocus(
          allowHorizontal: false,
          child: TextButton(
            focusNode: isAndroidTv ? _findFocus : null,
            onPressed: (_connecting || _finding || settings.discovering) ? null : _findServer,
            child: Text((_finding || settings.discovering) ? 'Searching…' : 'Find on this network'),
          ),
        ),
        if (settings.lastError != null) ...[
          const SizedBox(height: 16),
          Text(
            settings.lastError!,
            textAlign: TextAlign.center,
            style: TextStyle(color: Theme.of(context).colorScheme.error, height: 1.4),
          ),
        ],
      ],
    );

    return Scaffold(
      backgroundColor: AppTheme.canvas,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final body = SingleChildScrollView(
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.maxHeight),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 36),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 480),
                      child: form,
                    ),
                  ),
                ),
              ),
            );
            if (!isAndroidTv) return body;
            return FocusTraversalGroup(
              policy: WidgetOrderTraversalPolicy(),
              child: body,
            );
          },
        ),
      ),
    );
  }
}
