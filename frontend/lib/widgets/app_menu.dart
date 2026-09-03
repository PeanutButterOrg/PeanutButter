import 'package:flutter/material.dart';

import '../theme.dart';
import 'tv_chrome.dart';

class AppMenuEntry<T> {
  const AppMenuEntry({required this.value, required this.label});

  final T value;
  final String label;
}

/// Compact themed picker used on search, catalog, settings, and browse.
class AppMenuButton<T> extends StatelessWidget {
  const AppMenuButton({
    super.key,
    required this.value,
    required this.entries,
    required this.onSelected,
    this.hint = 'Select',
    this.icon,
    this.compact = false,
    this.focusNode,
  });

  final T? value;
  final List<AppMenuEntry<T>> entries;
  final ValueChanged<T> onSelected;
  final String hint;
  final IconData? icon;
  final bool compact;
  final FocusNode? focusNode;

  String get _label {
    for (final entry in entries) {
      if (entry.value == value) return entry.label;
    }
    return hint;
  }

  Future<void> _pick(BuildContext context) async {
    final picked = await showDialog<T>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: Text(hint),
          contentPadding: const EdgeInsets.fromLTRB(8, 12, 8, 16),
          content: SizedBox(
            width: 420,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(ctx).height * 0.6,
              ),
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final entry in entries)
                    ListTile(
                      autofocus: entry.value == value,
                      selected: entry.value == value,
                      title: Text(entry.label),
                      onTap: () => Navigator.pop(ctx, entry.value),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
    if (picked != null) onSelected(picked);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return TvFocus(
      child: Material(
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.55),
      borderRadius: BorderRadius.circular(compact ? 20 : 12),
      child: InkWell(
        focusNode: focusNode,
        borderRadius: BorderRadius.circular(compact ? 20 : 12),
        onTap: () => _pick(context),
        child: Container(
          height: compact ? 40 : 48,
          padding: EdgeInsets.fromLTRB(compact ? 10 : 12, 0, compact ? 4 : 8, 0),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(compact ? 20 : 12),
            border: Border.all(color: scheme.outline.withValues(alpha: 0.22)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: compact ? 15 : 16, color: scheme.onSurfaceVariant),
                SizedBox(width: compact ? 6 : 8),
              ],
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: compact ? 132 : 220),
                child: Text(
                  _label,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    fontSize: compact ? 13 : null,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              Icon(Icons.expand_more_rounded, size: compact ? 16 : 18, color: scheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
      ),
    );
  }
}

class AppFilterChip extends StatelessWidget {
  const AppFilterChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onSelected,
  });

  final String label;
  final bool selected;
  final ValueChanged<bool> onSelected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return TvFocus(
      child: TextButton(
      onPressed: () => onSelected(!selected),
      style: TextButton.styleFrom(
        foregroundColor: selected ? scheme.primary : scheme.onSurface,
        backgroundColor: selected
            ? AppTheme.seed.withValues(alpha: 0.28)
            : scheme.surfaceContainerHighest.withValues(alpha: 0.45),
        minimumSize: const Size(64, 40),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(
            color: selected ? AppTheme.seed : scheme.outline.withValues(alpha: 0.22),
          ),
        ),
      ),
      child: Text(label, style: TextStyle(fontWeight: selected ? FontWeight.w700 : FontWeight.w500)),
    ),
    );
  }
}

const kKindFilters = <(String, String?)>[
  ('All', null),
  ('Movies', 'MOVIE'),
  ('Series', 'SERIES'),
  ('Anime', 'ANIME'),
];
