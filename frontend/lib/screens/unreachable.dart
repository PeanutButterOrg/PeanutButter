import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../friendly_error.dart';
import '../graphql/client.dart';
import '../providers/settings.dart';
import '../theme.dart';
import '../tv.dart';
import '../widgets/tv_chrome.dart';

class UnreachableScreen extends ConsumerStatefulWidget {
  const UnreachableScreen({super.key});

  @override
  ConsumerState<UnreachableScreen> createState() => _UnreachableScreenState();
}

class _UnreachableScreenState extends ConsumerState<UnreachableScreen> {
  final FocusNode _retryFocus = FocusNode(debugLabel: 'unreachable-retry');
  final FocusNode _findFocus = FocusNode(debugLabel: 'unreachable-find');
  final FocusNode _disconnectFocus = FocusNode(debugLabel: 'unreachable-disconnect');
  bool _retrying = false;
  bool _finding = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (isAndroidTv && _retryFocus.canRequestFocus) {
        _retryFocus.requestFocus();
      }
    });
  }

  @override
  void dispose() {
    _retryFocus.dispose();
    _findFocus.dispose();
    _disconnectFocus.dispose();
    super.dispose();
  }

  bool get _locked => _retrying || _finding;

  Future<void> _retry() async {
    if (_locked) return;
    setState(() => _retrying = true);
    final notifier = ref.read(settingsProvider.notifier);
    try {
      final reachable = await notifier.probeCurrent();
      if (!reachable) return;
      ref.invalidate(serverInfoProvider);
      try {
        await ref.read(serverInfoProvider.future);
        await notifier.markConnected();
      } catch (e) {
        if (isUnauthorizedError(e)) {
          await notifier.forgetPairing(
            message: 'This pairing code is no longer valid. Create a new code in the server console.',
          );
        } else {
          await notifier.markDisconnected(friendlyRequestError(e));
        }
      }
    } finally {
      if (mounted) setState(() => _retrying = false);
    }
  }

  Future<void> _findServer() async {
    if (_locked) return;
    setState(() => _finding = true);
    final notifier = ref.read(settingsProvider.notifier);
    try {
      final found = await notifier.discoverLocalhost();
      if (!mounted || found == null) return;
      final reachable = await notifier.probeCurrent();
      if (!reachable) return;
      ref.invalidate(serverInfoProvider);
      try {
        await ref.read(serverInfoProvider.future);
        await notifier.markConnected();
      } catch (e) {
        if (isUnauthorizedError(e)) {
          await notifier.forgetPairing(
            message: 'This pairing code is no longer valid. Create a new code in the server console.',
          );
        } else {
          await notifier.markDisconnected(friendlyRequestError(e));
        }
      }
    } finally {
      if (mounted) setState(() => _finding = false);
    }
  }

  Future<void> _disconnect() async {
    if (_locked) return;
    await ref.read(settingsProvider.notifier).forgetPairing(
          message: 'Disconnected. Pair this device again to continue.',
        );
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final url = settings.serverUrl.isEmpty ? 'your catalog server' : settings.serverUrl;
    final detail = settings.lastError?.trim();
    final body = Column(
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
          'Server unreachable',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 8),
        Text(
          'This device is still paired, but it can’t reach $url right now. Check that the server is running on the same network, then try again.',
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white54, height: 1.45, fontSize: 15),
        ),
        if (detail != null && detail.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text(
            detail,
            textAlign: TextAlign.center,
            style: TextStyle(color: Theme.of(context).colorScheme.error, height: 1.4),
          ),
        ],
        const SizedBox(height: 28),
        TvFocus(
          allowHorizontal: false,
          child: FilledButton(
            focusNode: isAndroidTv ? _retryFocus : null,
            onPressed: _locked ? null : _retry,
            child: Text(_retrying ? 'Trying…' : 'Try again'),
          ),
        ),
        const SizedBox(height: 10),
        TvFocus(
          allowHorizontal: false,
          child: TextButton(
            focusNode: isAndroidTv ? _findFocus : null,
            onPressed: (_locked || settings.discovering) ? null : _findServer,
            child: Text((_finding || settings.discovering) ? 'Searching…' : 'Find on this network'),
          ),
        ),
        const SizedBox(height: 10),
        TvFocus(
          allowHorizontal: false,
          child: TextButton(
            focusNode: isAndroidTv ? _disconnectFocus : null,
            onPressed: _locked ? null : _disconnect,
            child: const Text('Disconnect this device'),
          ),
        ),
      ],
    );

    return Scaffold(
      backgroundColor: AppTheme.canvas,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final scroll = SingleChildScrollView(
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.maxHeight),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 36),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 480),
                      child: body,
                    ),
                  ),
                ),
              ),
            );
            if (!isAndroidTv) return scroll;
            return FocusTraversalGroup(
              policy: WidgetOrderTraversalPolicy(),
              child: scroll,
            );
          },
        ),
      ),
    );
  }
}
