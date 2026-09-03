import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../friendly_error.dart';
import '../providers/catalog.dart';
import '../widgets/empty_state.dart';
import '../widgets/filter_bar.dart';
import '../widgets/local_overlay.dart';
import '../widgets/poster_grid.dart';

class BrowseScreen extends ConsumerWidget {
  const BrowseScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final kind = ref.watch(selectedKindProvider);
    final filter = ref.watch(browseFilterProvider(kind));
    final catalog = ref.watch(browseProvider(kind));

    return Column(
      children: [
        Material(
          color: Theme.of(context).scaffoldBackgroundColor,
          elevation: 8,
          surfaceTintColor: Colors.transparent,
          child: FilterBar(
            filter: filter,
            onChanged: (next) => ref.read(browseFilterProvider(kind).notifier).state = next,
          ),
        ),
        Expanded(child: ClippedOverlay(child: _Grid(kind: kind, catalog: catalog))),
      ],
    );
  }
}

class _Grid extends ConsumerWidget {
  const _Grid({required this.kind, required this.catalog});

  final String kind;
  final CatalogState catalog;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (catalog.loading && catalog.items.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (catalog.error != null && catalog.items.isEmpty) {
      return EmptyState(
        message: friendlyError(catalog.error!),
        onRefresh: () => ref.read(browseProvider(kind).notifier).refresh(),
        showSettings: true,
      );
    }
    if (catalog.items.isEmpty) {
      return EmptyState(
        message: emptyKindMessage(kind: kind, omdbConfigured: true),
        onRefresh: () => ref.read(browseProvider(kind).notifier).refresh(),
        showSettings: true,
      );
    }
    return PosterGrid(
      items: catalog.items,
      loadingMore: catalog.loadingMore,
      onEndReached: () => ref.read(browseProvider(kind).notifier).loadMore(),
    );
  }
}
