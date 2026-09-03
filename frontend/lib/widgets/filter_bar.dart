import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models.dart';
import '../providers/catalog.dart';
import '../tv.dart';
import '../widgets/app_menu.dart';

class _KindStepIntent extends Intent {
  const _KindStepIntent(this.delta);
  final int delta;
}

class _KindDownIntent extends Intent {
  const _KindDownIntent();
}

class _KindTrailingIntent extends Intent {
  const _KindTrailingIntent();
}

/// Movies / Series / Anime — same control on Home and Search.
class KindSwitch extends StatelessWidget {
  const KindSwitch({
    super.key,
    required this.kind,
    required this.onChanged,
    this.moviesFocus,
    this.seriesFocus,
    this.animeFocus,
    this.onMoveDown,
    this.onMoveTrailing,
  });

  final String kind;
  final ValueChanged<String> onChanged;
  final FocusNode? moviesFocus;
  final FocusNode? seriesFocus;
  final FocusNode? animeFocus;
  final VoidCallback? onMoveDown;
  final VoidCallback? onMoveTrailing;

  static const _keys = ['MOVIE', 'SERIES', 'ANIME'];

  FocusNode _nodeFor(String k) {
    return switch (k) {
      'SERIES' => seriesFocus ?? TvHeaderFocus.series,
      'ANIME' => animeFocus ?? TvHeaderFocus.anime,
      _ => moviesFocus ?? TvHeaderFocus.movies,
    };
  }

  void _step(int delta) {
    final primary = FocusManager.instance.primaryFocus;
    var i = -1;
    for (var k = 0; k < _keys.length; k++) {
      final node = _nodeFor(_keys[k]);
      if (identical(primary, node) || (primary?.debugLabel != null && primary!.debugLabel == node.debugLabel)) {
        i = k;
        break;
      }
    }
    if (i < 0) i = _keys.indexOf(kind);
    if (i < 0) i = 0;
    final next = (i + delta).clamp(0, _keys.length - 1);
    if (next == i) return;
    _nodeFor(_keys[next]).requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const items = [
      ('Movies', 'MOVIE'),
      ('Series', 'SERIES'),
      ('Anime', 'ANIME'),
    ];
    return Actions(
      actions: {
        _KindStepIntent: CallbackAction<_KindStepIntent>(
          onInvoke: (intent) {
            _step(intent.delta);
            return null;
          },
        ),
        _KindDownIntent: CallbackAction<_KindDownIntent>(
          onInvoke: (_) {
            onMoveDown?.call();
            return null;
          },
        ),
        _KindTrailingIntent: CallbackAction<_KindTrailingIntent>(
          onInvoke: (_) {
            onMoveTrailing?.call();
            return null;
          },
        ),
      },
      child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (i, item) in items.indexed)
              Shortcuts(
                shortcuts: {
                  const SingleActivator(LogicalKeyboardKey.arrowLeft): i == 0
                      ? const DoNothingIntent()
                      : const _KindStepIntent(-1),
                  const SingleActivator(LogicalKeyboardKey.arrowRight): i == items.length - 1
                      ? (onMoveTrailing != null
                          ? const _KindTrailingIntent()
                          : const DirectionalFocusIntent(TraversalDirection.right))
                      : const _KindStepIntent(1),
                  if (onMoveDown != null)
                    const SingleActivator(LogicalKeyboardKey.arrowDown): const _KindDownIntent(),
                },
                child: Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: SizedBox(
                    height: 40,
                    child: TextButton(
                      focusNode: _nodeFor(item.$2),
                      onPressed: () => onChanged(item.$2),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        minimumSize: const Size(64, 40),
                        tapTargetSize: MaterialTapTargetSize.padded,
                        foregroundColor: kind == item.$2 ? scheme.primary : scheme.onSurfaceVariant,
                      ),
                      child: Text(
                        item.$1,
                        style: TextStyle(
                          fontWeight: kind == item.$2 ? FontWeight.w700 : FontWeight.w500,
                          fontSize: 15,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
    );
  }
}

const kSortOptions = <(String, String)>[
  ('CONTINUE_WATCHING', 'Continue watching'),
  ('TRENDING', 'Trending'),
  ('POPULARITY', 'Popular'),
  ('DATE_ADDED', 'Last added'),
  ('YEAR', 'Year'),
  ('RATING', 'Rating'),
  ('ROTTEN_TOMATOES', 'Rotten Tomatoes'),
  ('TITLE', 'Title'),
];

/// Sort choices shown in picker menus (home “See all” already picks the rail).
const kCatalogSortMenuOptions = <(String, String)>[
  ('CONTINUE_WATCHING', 'Continue watching'),
  ('POPULARITY', 'Popular'),
  ('DATE_ADDED', 'Last added'),
  ('YEAR', 'Year'),
  ('RATING', 'Rating'),
  ('ROTTEN_TOMATOES', 'Rotten Tomatoes'),
  ('TITLE', 'Title'),
];

String catalogHeading(CatalogFilter filter) {
  var sortLabel = 'Catalog';
  for (final opt in kSortOptions) {
    if (opt.$1 == filter.sort) {
      sortLabel = opt.$2;
      break;
    }
  }
  if (filter.sort == 'CONTINUE_WATCHING' && filter.kind == null) {
    return sortLabel;
  }
  final kind = switch (filter.kind) {
    'MOVIE' => 'movies',
    'SERIES' => 'series',
    'ANIME' => 'anime',
    _ => 'titles',
  };
  return '$sortLabel $kind';
}

const kRatingPresets = <(double, String)>[
  (0, 'Any rating'),
  (9, '9+'),
  (8, '8+'),
  (7, '7+'),
  (6, '6+'),
  (5, '5+'),
];

int catalogYearMenuValue(CatalogFilter filter) => filter.selectedYear ?? 0;

List<int> catalogYearChoices() {
  final now = DateTime.now().year;
  return [for (var year = now; year >= 1900; year--) year];
}

class CatalogSortMenu extends StatelessWidget {
  const CatalogSortMenu({
    super.key,
    required this.filter,
    required this.onChanged,
    this.compact = false,
    this.focusNode,
  });

  final CatalogFilter filter;
  final ValueChanged<CatalogFilter> onChanged;
  final bool compact;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    return AppMenuButton<String>(
      hint: 'Sort',
      icon: Icons.sort_rounded,
      compact: compact,
      focusNode: focusNode,
      value: filter.sort,
      entries: [
        for (final opt in kCatalogSortMenuOptions) AppMenuEntry(value: opt.$1, label: opt.$2),
      ],
      onSelected: (value) => onChanged(filter.copyWith(sort: value)),
    );
  }
}

class FilterBar extends StatelessWidget {
  const FilterBar({
    super.key,
    required this.filter,
    required this.onChanged,
    this.compact = true,
    this.firstFocus,
  });

  final CatalogFilter filter;
  final ValueChanged<CatalogFilter> onChanged;
  final bool compact;
  final FocusNode? firstFocus;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 8),
      child: Row(
        children: [
          CatalogYearMenu(
            compact: compact,
            filter: filter,
            onChanged: onChanged,
            focusNode: firstFocus,
          ),
          const SizedBox(width: 8),
          CatalogRatingMenu(compact: compact, filter: filter, onChanged: onChanged),
          const SizedBox(width: 8),
          CatalogGenreMenu(compact: compact, filter: filter, onChanged: onChanged),
        ],
      ),
    );
  }
}

class TvCatalogHeaderFilters extends StatelessWidget {
  const TvCatalogHeaderFilters({
    super.key,
    required this.filter,
    required this.onChanged,
    this.firstFocus,
  });

  final CatalogFilter filter;
  final ValueChanged<CatalogFilter> onChanged;
  final FocusNode? firstFocus;

  @override
  Widget build(BuildContext context) {
    return FilterBar(
      filter: filter,
      onChanged: onChanged,
      compact: true,
      firstFocus: firstFocus,
    );
  }
}

class CatalogYearMenu extends StatelessWidget {
  const CatalogYearMenu({
    super.key,
    required this.filter,
    required this.onChanged,
    this.compact = false,
    this.focusNode,
  });

  final CatalogFilter filter;
  final ValueChanged<CatalogFilter> onChanged;
  final bool compact;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    return AppMenuButton<int>(
      hint: 'Year',
      icon: Icons.calendar_today_outlined,
      compact: compact,
      focusNode: focusNode,
      value: catalogYearMenuValue(filter),
      entries: [
        const AppMenuEntry(value: 0, label: 'Any year'),
        for (final year in catalogYearChoices()) AppMenuEntry(value: year, label: '$year'),
      ],
      onSelected: (year) {
        if (year <= 0) {
          onChanged(filter.copyWith(yearMin: 1900, clearYearMax: true));
          return;
        }
        onChanged(filter.copyWith(yearMin: year, yearMax: year));
      },
    );
  }
}

class CatalogRatingMenu extends StatelessWidget {
  const CatalogRatingMenu({
    super.key,
    required this.filter,
    required this.onChanged,
    this.compact = false,
    this.focusNode,
  });

  final CatalogFilter filter;
  final ValueChanged<CatalogFilter> onChanged;
  final bool compact;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final current = kRatingPresets.any((e) => e.$1 == filter.ratingMin) ? filter.ratingMin : 0.0;
    return AppMenuButton<double>(
      hint: 'Rating',
      icon: Icons.star_outline_rounded,
      compact: compact,
      focusNode: focusNode,
      value: current,
      entries: [
        for (final preset in kRatingPresets) AppMenuEntry(value: preset.$1, label: preset.$2),
      ],
      onSelected: (value) => onChanged(filter.copyWith(ratingMin: value)),
    );
  }
}

class CatalogGenreMenu extends ConsumerWidget {
  const CatalogGenreMenu({
    super.key,
    required this.filter,
    required this.onChanged,
    this.compact = false,
    this.focusNode,
  });

  final CatalogFilter filter;
  final ValueChanged<CatalogFilter> onChanged;
  final bool compact;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final genres = ref.watch(genresProvider).maybeWhen(
          data: (v) => v,
          orElse: () => const <String>[],
        );
    return AppMenuButton<String>(
      hint: 'Genre',
      icon: Icons.category_outlined,
      compact: compact,
      focusNode: focusNode,
      value: filter.genre ?? 'all',
      entries: [
        const AppMenuEntry(value: 'all', label: 'All genres'),
        ...genres.map((g) => AppMenuEntry(value: g, label: g)),
      ],
      onSelected: (value) {
        onChanged(
          value == 'all' ? filter.copyWith(clearGenre: true) : filter.copyWith(genre: value),
        );
      },
    );
  }
}
