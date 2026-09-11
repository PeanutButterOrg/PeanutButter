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
  /// URL field stays hidden until LAN discovery fails (or user already typed one).
  bool _showUrlField = false;
  String? _foundLabel;

  @override
  void initState() {
    super.initState();
    final saved = ref.read(settingsProvider);
    final savedUrl = saved.serverUrl.trim();
    final hasUsableUrl = savedUrl.isNotEmpty && !isLocalServer(savedUrl);
    _url = TextEditingController(text: hasUsableUrl ? savedUrl : '');
    _token = TextEditingController();
    _showUrlField = hasUsableUrl;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      if (hasUsableUrl) {
        if (isAndroidTv && _tokenFocus.canRequestFocus) {
          _tokenFocus.requestFocus();
        }
        return;
      }
      await _autoFindServer();
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

  Future<void> _autoFindServer() async {
    if (_connecting || _finding) return;
    setState(() {
      _finding = true;
      _showUrlField = false;
      _foundLabel = null;
    });
    final found = await ref.read(settingsProvider.notifier).discoverLocalhost();
    if (!mounted) return;
    if (found != null) {
      _url.text = found;
      setState(() {
        _finding = false;
        _showUrlField = false;
        _foundLabel = found;
      });
      if (isAndroidTv && _tokenFocus.canRequestFocus) {
        _tokenFocus.requestFocus();
      }
      return;
    }
    setState(() {
      _finding = false;
      _showUrlField = true;
      _foundLabel = null;
    });
    if (isAndroidTv && _urlFocus.canRequestFocus) {
      _urlFocus.requestFocus();
    }
  }

  Future<void> _connect() async {
    if (_connecting || _finding) return;
    setState(() => _connecting = true);
    final notifier = ref.read(settingsProvider.notifier);
    await notifier.runPairingAttempt(() async {
      final typed = _url.text.trim();
      if (typed.isEmpty) {
        await notifier.clearPairingAttempt(
          'No server found yet. Wait for network search, or enter the server address.',
        );
        return;
      }
      await notifier.setServerUrl(typed);
      await notifier.setApiToken(_token.text);
      if (mounted) _token.text = ref.read(settingsProvider).apiToken;
      final reachable = await notifier.probeCurrent();
      if (!reachable) {
        await notifier.clearPairingAttempt(
          ref.read(settingsProvider).lastError ??
              'Cannot reach that server. Check the address and try again.',
        );
        if (mounted) {
          setState(() => _showUrlField = true);
        }
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
    await _autoFindServer();
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final searching = _finding || settings.discovering;
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
        Text(
          searching
              ? 'Looking for a catalog server on this network…'
              : (_foundLabel != null
                  ? 'Server found on this network. Enter the 6-digit pairing code from the console.'
                  : 'Sign in on the server console, create a 6-digit code, then type it here.'),
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white54, height: 1.45, fontSize: 15),
        ),
        const SizedBox(height: 28),
        if (searching) ...[
          const Center(
            child: SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
          ),
          const SizedBox(height: 20),
        ] else ...[
          if (_foundLabel != null && !_showUrlField) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                color: const Color(0xFF121218),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  const Icon(Icons.dns_rounded, color: Colors.white54, size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _foundLabel!,
                      style: const TextStyle(color: Colors.white70, fontSize: 14),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  TextButton(
                    onPressed: () => setState(() => _showUrlField = true),
                    child: const Text('Change'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
          ],
          if (_showUrlField) ...[
            TvTextField(
              chromeFocus: _urlFocus,
              controller: _url,
              autofocus: isAndroidTv && _foundLabel == null,
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
          ],
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
              onPressed: (_connecting || searching) ? null : _connect,
              child: Text(_connecting ? 'Connecting…' : 'Connect'),
            ),
          ),
          const SizedBox(height: 10),
          TvFocus(
            allowHorizontal: false,
            child: TextButton(
              focusNode: isAndroidTv ? _findFocus : null,
              onPressed: (_connecting || searching) ? null : _findServer,
              child: Text(searching ? 'Searching…' : 'Find on this network'),
            ),
          ),
        ],
        if (settings.lastError != null && !searching) ...[
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
