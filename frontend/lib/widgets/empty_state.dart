import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.message,
    this.title,
    this.icon,
    this.onRefresh,
    this.showSettings = false,
  });

  final String message;
  final String? title;
  final IconData? icon;
  final Future<void> Function()? onRefresh;
  final bool showSettings;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final actions = onRefresh != null || showSettings;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon ?? Icons.movie_filter_outlined,
                size: 48,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(height: 16),
              if (title != null) ...[
                Text(
                  title!,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
                const SizedBox(height: 8),
              ],
              Text(
                message,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: scheme.onSurfaceVariant,
                      height: 1.4,
                    ),
              ),
              if (actions) ...[
                const SizedBox(height: 22),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 10,
                  runSpacing: 8,
                  children: [
                    if (onRefresh != null)
                      FilledButton.icon(
                        onPressed: () => onRefresh!(),
                        icon: const Icon(Icons.refresh_rounded),
                        label: const Text('Refresh'),
                      ),
                    if (showSettings)
                      OutlinedButton.icon(
                        onPressed: () => context.push('/settings'),
                        icon: const Icon(Icons.settings_outlined),
                        label: const Text('Settings'),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
