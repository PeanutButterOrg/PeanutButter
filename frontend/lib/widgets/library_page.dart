import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../design/tokens.g.dart';
import '../models.dart';
import 'app_menu.dart';
import 'poster_card.dart';
import 'poster_grid.dart';
import 'wide_card.dart';

/// My List and Watched on desktop / web, as in the design: a big title with
/// counts, All / Movies / Series, Recently added / A–Z, an optional Keep
/// watching row, then the grid.
class LibraryPage extends StatefulWidget {
  const LibraryPage({
    super.key,
    required this.title,
    required this.items,
    required this.emptyMessage,
    this.keepWatching = false,
  });

  final String title;
  /// Newest first, as the server returns them.
  final List<TitleItem> items;
  final String emptyMessage;
  /// My List: titles you've started, as wide cards above the grid.
  final bool keepWatching;

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  String? _kind;
  var _az = false;

  @override
  Widget build(BuildContext context) {
    final all = widget.items;
    final movies = all.where((t) => t.kind == 'MOVIE').length;
    final series = all.length - movies;
    var shown = _kind == null
        ? all
        : all.where((t) => _kind == 'MOVIE' ? t.kind == 'MOVIE' : t.kind != 'MOVIE').toList();
    if (_az) {
      shown = [...shown]..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    }
    final started = widget.keepWatching
        ? shown.where((t) => titleProgress(t) > 0.02 && t.userState?.watched != true).toList()
        : const <TitleItem>[];
    final counts = [
      '${all.length} title${all.length == 1 ? '' : 's'}',
      [if (movies > 0) '$movies movie${movies == 1 ? '' : 's'}', if (series > 0) '$series series'].join(', '),
    ].where((e) => e.isNotEmpty).join('  ·  ');

    final header = Padding(
      padding: const EdgeInsets.fromLTRB(PbSpace.gutterDesktop - 8, 14, PbSpace.gutterDesktop, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          IconButton(
            tooltip: 'Back',
            onPressed: () => context.canPop() ? context.pop() : context.go('/'),
            icon: const Icon(Icons.arrow_back_rounded, color: PbColors.text),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 8, top: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.title, style: PbType.hero.copyWith(fontSize: 56, color: PbColors.text, height: 1)),
                const SizedBox(height: 8),
                Text(counts, style: PbType.meta.copyWith(fontSize: 15, color: PbColors.textMuted)),
                const SizedBox(height: 18),
                Row(
                  children: [
                    for (final (label, kind) in const [('All', null), ('Movies', 'MOVIE'), ('Series', 'SERIES')]) ...[
                      AppFilterChip(
                        label: label,
                        selected: _kind == kind,
                        onSelected: (_) => setState(() => _kind = kind),
                      ),
                      const SizedBox(width: 8),
                    ],
                    const Spacer(),
                    AppFilterChip(
                      label: 'Recently added',
                      selected: !_az,
                      onSelected: (_) => setState(() => _az = false),
                    ),
                    const SizedBox(width: 8),
                    AppFilterChip(
                      label: 'A–Z',
                      selected: _az,
                      onSelected: (_) => setState(() => _az = true),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );

    if (all.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header,
          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  widget.emptyMessage,
                  textAlign: TextAlign.center,
                  style: PbType.body.copyWith(fontSize: 16, color: PbColors.textMuted),
                ),
              ),
            ),
          ),
        ],
      );
    }

    const wideW = PbSize.wideCardWidthDesktop;
    return PosterGrid(
      items: shown,
      sidePadding: PbSpace.gutterDesktop,
      headerSlivers: [
        SliverToBoxAdapter(child: header),
        if (started.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(PbSpace.gutterDesktop, 28, PbSpace.gutterDesktop, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Keep watching', style: PbType.h2.copyWith(color: PbColors.text)),
                  const SizedBox(height: 12),
                  SizedBox(
                    height: wideW * 9 / 16,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      clipBehavior: Clip.none,
                      itemCount: started.length,
                      separatorBuilder: (_, __) => const SizedBox(width: 14),
                      itemBuilder: (context, i) => SizedBox(width: wideW, child: WideCard(item: started[i])),
                    ),
                  ),
                ],
              ),
            ),
          ),
        const SliverToBoxAdapter(child: SizedBox(height: 16)),
      ],
    );
  }
}
