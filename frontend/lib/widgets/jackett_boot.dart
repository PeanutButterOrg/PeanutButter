import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models.dart';
import '../providers/settings.dart';
import '../theme.dart';

/// Full-screen gate while the first Jackett catalog is built and stored.
class JackettBootGate extends ConsumerStatefulWidget {
  const JackettBootGate({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<JackettBootGate> createState() => _JackettBootGateState();
}

class _JackettBootGateState extends ConsumerState<JackettBootGate> {
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _poll = Timer.periodic(const Duration(seconds: 2), (_) {
      if (!mounted) return;
      final pending = ref.read(settingsProvider).jackettCatalogPending;
      final connected = ref.read(settingsProvider).connected;
      final async = ref.read(serverInfoProvider);
      final data = async.asData?.value;
      final blocking = _shouldBlock(
        pending: pending,
        connected: connected,
        data: data,
        hasLoaded: async.hasValue || async.hasError,
      );
      if (blocking && connected) {
        ref.invalidate(serverInfoProvider);
      }
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pending = ref.watch(settingsProvider.select((s) => s.jackettCatalogPending));
    final connected = ref.watch(settingsProvider.select((s) => s.connected));
    final info = ref.watch(serverInfoProvider);
    final data = info.asData?.value;
    final catalog = data?.jackettCatalog;
    final blocking = _shouldBlock(
      pending: pending,
      connected: connected,
      data: data,
      hasLoaded: info.hasValue || info.hasError,
    );

    if (pending && (data != null && (!data.jackettConfigured || data.jackettCatalog.ready))) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ref.read(settingsProvider.notifier).setJackettCatalogPending(false);
      });
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        Focus(
          canRequestFocus: !blocking,
          descendantsAreFocusable: !blocking,
          child: widget.child,
        ),
        if (blocking)
          Positioned.fill(
            child: _JackettCatalogLoader(
              status: catalog ?? const JackettCatalogStatus(ready: false, syncing: true),
              connected: connected,
              error: catalog?.lastError,
            ),
          ),
      ],
    );
  }
}

bool _shouldBlock({
  required bool pending,
  required bool connected,
  required ServerInfo? data,
  required bool hasLoaded,
}) {
  if (!connected) return false;
  if (data != null) {
    return data.jackettConfigured && !data.jackettCatalog.ready;
  }
  // Only the Jackett-enable restart should wait before server info arrives.
  return pending && !hasLoaded;
}

class _JackettCatalogLoader extends StatelessWidget {
  const _JackettCatalogLoader({
    required this.status,
    required this.connected,
    this.error,
  });

  final JackettCatalogStatus status;
  final bool connected;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final total = status.total;
    final done = status.done;
    final hasCounts = total > 0;
    final failed = !status.syncing && (error != null && error!.trim().isNotEmpty) && !status.ready;
    return Material(
      color: AppTheme.canvas,
      child: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (!failed)
                    const SizedBox(
                      width: 48,
                      height: 48,
                      child: CircularProgressIndicator(strokeWidth: 3),
                    )
                  else
                    const Icon(Icons.error_outline, size: 48, color: Colors.white70),
                  const SizedBox(height: 28),
                  Text(
                    failed ? 'Could not build the stream catalog' : 'Building your stream catalog',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    failed
                        ? (error ?? 'Jackett did not return a catalog.')
                        : connected
                            ? 'Searching Jackett for every movie, series, and anime, then keeping healthy magnet links. This can take a while.'
                            : 'Connecting to the catalog server…',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          color: Colors.white70,
                          height: 1.4,
                        ),
                  ),
                  if (hasCounts && !failed) ...[
                    const SizedBox(height: 22),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: LinearProgressIndicator(
                        minHeight: 8,
                        value: (done / total).clamp(0, 1),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      '$done of $total titles',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            color: Colors.white,
                          ),
                    ),
                  ],
                  if (failed) ...[
                    const SizedBox(height: 22),
                    FilledButton(
                      onPressed: () => context.go('/settings'),
                      child: const Text('Open settings'),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
