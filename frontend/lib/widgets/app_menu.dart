import 'package:flutter/material.dart';

import '../design/tokens.g.dart';
import '../theme.dart';
import '../tv.dart';
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

  /// A filter (compact) with something other than its first ("Any …") entry
  /// picked; settings menus never light up.
  bool get _active => compact && entries.isNotEmpty && value != null && value != entries.first.value;

  Future<void> _pick(BuildContext context) async {
    final picked = isAndroidTv ? await _dialog(context) : await _dropdown(context);
    if (picked != null) onSelected(picked);
  }

  /// Desktop / web: a list right under the button.
  Future<T?> _dropdown(BuildContext context) {
    final box = context.findRenderObject() as RenderBox?;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (box == null || overlay == null) return _dialog(context);
    final topLeft = box.localToGlobal(Offset(0, box.size.height + 6), ancestor: overlay);
    return showMenu<T>(
      context: context,
      position: RelativeRect.fromLTRB(
        topLeft.dx,
        topLeft.dy,
        overlay.size.width - topLeft.dx - box.size.width,
        0,
      ),
      color: PbColors.surfaceRaised,
      elevation: 12,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(PbRadius.card + 2),
        side: const BorderSide(color: PbColors.line),
      ),
      constraints: BoxConstraints(
        minWidth: box.size.width < 180 ? 180 : box.size.width,
        maxHeight: MediaQuery.sizeOf(context).height * 0.5,
      ),
      items: [
        for (final entry in entries)
          PopupMenuItem<T>(
            value: entry.value,
            height: 40,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    entry.label,
                    style: PbType.body.copyWith(
                      fontSize: 14,
                      color: entry.value == value ? PbColors.primary : PbColors.text,
                      fontWeight: entry.value == value ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ),
                if (entry.value == value) const Icon(Icons.check_rounded, size: 18, color: PbColors.primary),
              ],
            ),
          ),
      ],
    );
  }

  Future<T?> _dialog(BuildContext context) {
    return showDialog<T>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: PbColors.surface,
          title: Text(hint, style: PbType.h2.copyWith(color: PbColors.text)),
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
                      selectedColor: PbColors.primary,
                      title: Text(entry.label),
                      trailing: entry.value == value
                          ? const Icon(Icons.check_rounded, color: PbColors.primary)
                          : null,
                      onTap: () => Navigator.pop(ctx, entry.value),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final active = _active;
    final fg = active ? PbColors.primary : PbColors.text;
    final radius = BorderRadius.circular(compact ? PbRadius.pill : 12);
    return TvFocus(
      child: Material(
        color: active ? PbColors.primary.withValues(alpha: 0.12) : PbColors.surfaceRaised,
        borderRadius: radius,
        child: InkWell(
          focusNode: focusNode,
          borderRadius: radius,
          hoverColor: Colors.white.withValues(alpha: 0.05),
          onTap: () => _pick(context),
          child: Container(
            height: compact ? 40 : 48,
            padding: EdgeInsets.fromLTRB(compact ? 14 : 14, 0, compact ? 10 : 10, 0),
            decoration: BoxDecoration(
              borderRadius: radius,
              border: Border.all(color: active ? PbColors.primary.withValues(alpha: 0.6) : PbColors.line),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 16, color: active ? PbColors.primary : PbColors.textMuted),
                  const SizedBox(width: 8),
                ],
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: compact ? 140 : 220),
                  child: Text(
                    _label,
                    overflow: TextOverflow.ellipsis,
                    style: PbType.button.copyWith(fontSize: 13.5, color: fg),
                  ),
                ),
                const SizedBox(width: 4),
                Icon(Icons.keyboard_arrow_down_rounded, size: 18, color: active ? PbColors.primary : PbColors.textMuted),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Multi-select dropdown that keeps current selections checked when opened.
class AppMultiMenuButton extends StatelessWidget {
  const AppMultiMenuButton({
    super.key,
    required this.values,
    required this.entries,
    required this.onChanged,
    this.hint = 'Select',
    this.emptyLabel = 'All',
    this.icon,
    this.compact = false,
  });

  final List<String> values;
  final List<AppMenuEntry<String>> entries;
  final ValueChanged<List<String>> onChanged;
  final String hint;
  final String emptyLabel;
  final IconData? icon;
  final bool compact;

  String get _label {
    if (values.isEmpty) return emptyLabel;
    final labels = <String>[];
    for (final code in values) {
      for (final entry in entries) {
        if (entry.value == code) {
          labels.add(entry.label);
          break;
        }
      }
    }
    if (labels.isEmpty) return emptyLabel;
    return labels.join(', ');
  }

  Future<void> _pick(BuildContext context) async {
    var selected = {...values};
    final confirmed = await showDialog<List<String>>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setLocal) {
            return AlertDialog(
              title: Text(hint),
              contentPadding: const EdgeInsets.fromLTRB(8, 12, 8, 8),
              content: SizedBox(
                width: 420,
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.sizeOf(ctx).height * 0.6,
                  ),
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      ListTile(
                        selected: selected.isEmpty,
                        leading: Icon(
                          selected.isEmpty ? Icons.check_box_rounded : Icons.check_box_outline_blank_rounded,
                          color: selected.isEmpty ? Theme.of(ctx).colorScheme.primary : null,
                        ),
                        title: Text(emptyLabel),
                        onTap: () => setLocal(() => selected = {}),
                      ),
                      const Divider(height: 12),
                      for (final entry in entries)
                        ListTile(
                          selected: selected.contains(entry.value),
                          leading: Icon(
                            selected.contains(entry.value)
                                ? Icons.check_box_rounded
                                : Icons.check_box_outline_blank_rounded,
                            color: selected.contains(entry.value)
                                ? Theme.of(ctx).colorScheme.primary
                                : null,
                          ),
                          title: Text(entry.label),
                          onTap: () => setLocal(() {
                            if (selected.contains(entry.value)) {
                              selected.remove(entry.value);
                            } else {
                              selected.add(entry.value);
                            }
                          }),
                        ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, selected.toList()..sort()),
                  child: const Text('Done'),
                ),
              ],
            );
          },
        );
      },
    );
    if (confirmed != null) onChanged(confirmed);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return TvFocus(
      child: Material(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(compact ? 20 : 12),
        child: InkWell(
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
                  constraints: BoxConstraints(maxWidth: compact ? 160 : 260),
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
];
