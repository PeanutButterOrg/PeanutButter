import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../design/tokens.g.dart';
import '../friendly_error.dart';
import '../providers/settings.dart';
import '../models.dart';
import '../providers/catalog.dart';
import '../widgets/cached_art.dart';
import '../widgets/poster_card.dart';

/// A cast or crew member's page, in the app's own look (as on TV): their
/// best-known title's art behind a portrait, name, birth and bio, then rows
/// like Home's. Opened from a title's Cast & crew.
class PersonScreen extends ConsumerStatefulWidget {
  const PersonScreen({super.key, required this.tmdbId, this.name = ''});

  final int tmdbId;

  /// Shown while the page loads.
  final String name;

  @override
  ConsumerState<PersonScreen> createState() => _PersonScreenState();
}

/// One row of the page: a heading and its cards.
class _CreditRow {
  const _CreditRow(this.title, this.credits, {this.wide = false});
  final String title;
  final List<PersonCredit> credits;
  final bool wide;
}

/// Their best-known titles first (most TMDB votes, then popularity), then
/// what they acted in by kind, newest first, then their work behind the camera.
/// Only what's out (older servers also send announced titles): a year, and
/// not a future one.
bool _isOut(PersonCredit c) => c.year != null && c.year! <= DateTime.now().year;

List<_CreditRow> _rowsFor(PersonDetails p) {
  final acting = p.acting.where(_isOut).toList();
  final crewAll = p.crew.where(_isOut).toList();
  final seen = <String>{};
  final all = [...acting, ...crewAll].where((c) => seen.add('${c.kind}-${c.tmdbId}')).toList();
  final known = all.where((c) => c.voteCount > 0 || c.popularity > 0).toList()
    ..sort((a, b) {
      final v = b.voteCount.compareTo(a.voteCount);
      return v != 0 ? v : b.popularity.compareTo(a.popularity);
    });
  // Newest first; titles without a year go last.
  List<PersonCredit> newest(Iterable<PersonCredit> credits) =>
      credits.toList()..sort((a, b) => (b.year ?? -1).compareTo(a.year ?? -1));
  final movies = newest(acting.where((c) => c.kind == 'MOVIE'));
  final series = newest(acting.where((c) => c.kind != 'MOVIE'));
  final crew = newest(crewAll);
  return [
    if (known.length >= 3) _CreditRow('Known for', known.take(12).toList(), wide: true),
    if (movies.isNotEmpty) _CreditRow('Movies', movies),
    if (series.isNotEmpty) _CreditRow('Series', series),
    if (crew.isNotEmpty) _CreditRow('Behind the camera', crew),
  ];
}

class _PersonScreenState extends ConsumerState<PersonScreen> {
  bool _opening = false;
  Timer? _recheck;
  int? _lastChecking;
  Duration _wait = const Duration(seconds: 3);
  int _stalled = 0;
  bool _gaveUp = false;

  @override
  void dispose() {
    _recheck?.cancel();
    super.dispose();
  }

  /// The server is still checking some titles: ask until it's done (this
  /// stops when the page closes). Every 3 s while titles keep arriving,
  /// easing off to 15 s while none do.
  void _scheduleRecheck(PersonDetails? p) {
    if (p == null || p.checkingCredits == 0 || _recheck != null || _gaveUp) return;
    final last = _lastChecking;
    if (last != null) {
      final progressed = p.checkingCredits < last;
      _wait = progressed
          ? const Duration(seconds: 3)
          : Duration(milliseconds: (_wait.inMilliseconds * 3 ~/ 2).clamp(3000, 15000));
      _stalled = progressed ? 0 : _stalled + 1;
      // Older servers never settle titles they couldn't check: stop asking
      // (and drop "Checking more titles…") after a while with no progress.
      if (_stalled >= 4) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) setState(() => _gaveUp = true);
        });
        return;
      }
    }
    _lastChecking = p.checkingCredits;
    _recheck = Timer(_wait, () {
      _recheck = null;
      if (mounted) ref.invalidate(personProvider(widget.tmdbId));
    });
  }

  Future<void> _open(PersonCredit credit) async {
    final known = credit.titleId;
    if (known != null) {
      context.push('/title/$known');
      return;
    }
    if (_opening) return;
    // Not in the catalog yet: the server stores it first.
    setState(() => _opening = true);
    try {
      final id = await openTmdbTitle(ref.read(graphQLClientProvider), credit);
      if (mounted && id.isNotEmpty) context.push('/title/$id');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(friendlyError(e))));
      }
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final person = ref.watch(personProvider(widget.tmdbId));
    final p = person.valueOrNull;
    if (!person.isLoading) _scheduleRecheck(p);
    final rows = p == null ? const <_CreditRow>[] : _rowsFor(p);
    PersonCredit? art;
    for (final row in rows.where((r) => r.wide)) {
      for (final c in row.credits) {
        if (c.backdropUrl != null) {
          art = c;
          break;
        }
      }
    }
    art ??= p == null ? null : [...p.acting, ...p.crew].where((c) => c.backdropUrl != null).firstOrNull;

    return Scaffold(
      backgroundColor: PbColors.ground,
      body: Stack(
        children: [
          CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: _Hero(
                  person: p,
                  name: widget.name,
                  art: art,
                  loading: p == null && person.isLoading,
                  checking: p != null && p.checkingCredits > 0 && !_gaveUp,
                ),
              ),
              if (person.hasError && p == null)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.all(48),
                    child: Text(
                      'Couldn\'t load this person. Opening people needs PeanutButter server 0.3.26 or later.',
                      textAlign: TextAlign.center,
                      style: PbType.body.copyWith(fontSize: 16, color: PbColors.textMuted),
                    ),
                  ),
                ),
              for (final row in rows) SliverToBoxAdapter(child: _Shelf(row: row, onOpen: _open)),
              const SliverToBoxAdapter(child: SizedBox(height: 48)),
            ],
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(PbSpace.gutterDesktop - 12, 12, 0, 0),
              child: IconButton(
                tooltip: 'Back',
                style: IconButton.styleFrom(backgroundColor: const Color(0xCC121218)),
                onPressed: () => context.canPop() ? context.pop() : context.go('/'),
                icon: const Icon(Icons.arrow_back_rounded, color: PbColors.text),
              ),
            ),
          ),
          if (_opening)
            const Positioned.fill(
              child: ColoredBox(
                color: Color(0x8C000000),
                child: Center(child: CircularProgressIndicator()),
              ),
            ),
        ],
      ),
    );
  }
}

/// Their best-known title's art, faded, behind portrait, name, facts and bio.
class _Hero extends StatelessWidget {
  const _Hero({
    required this.person,
    required this.name,
    required this.art,
    required this.loading,
    required this.checking,
  });

  final PersonDetails? person;
  final String name;
  final PersonCredit? art;
  final bool loading;
  final bool checking;

  static const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

  static String _show(DateTime d) => '${d.day} ${_months[d.month - 1]} ${d.year}';

  static int _years(DateTime from, DateTime to) {
    var y = to.year - from.year;
    if (to.month < from.month || (to.month == from.month && to.day < from.day)) y--;
    return y;
  }

  /// "Born 21 Jul 2005 (age 21)", "Melbourne, Australia", "41 titles".
  static List<String> _facts(PersonDetails p) {
    final born = p.birthday == null ? null : DateTime.tryParse(p.birthday!);
    final died = p.deathday == null ? null : DateTime.tryParse(p.deathday!);
    final seen = <String>{};
    final titles = [...p.acting, ...p.crew].where(_isOut).where((c) => seen.add('${c.kind}-${c.tmdbId}')).length;
    return [
      if (born != null)
        died != null
            ? '${_show(born)} – ${_show(died)} (aged ${_years(born, died)})'
            : 'Born ${_show(born)} (age ${_years(born, DateTime.now())})',
      if (p.placeOfBirth != null) p.placeOfBirth!,
      if (titles > 0) '$titles title${titles == 1 ? '' : 's'}',
    ];
  }

  @override
  Widget build(BuildContext context) {
    final p = person;
    // As tall as its content (taller only to show art): without art a fixed
    // height left a black gap above the name.
    final hasArt = art?.backdropUrl != null;
    final minHeight = hasArt ? (MediaQuery.sizeOf(context).height * 0.5).clamp(380.0, 560.0) : 0.0;
    return ConstrainedBox(
      constraints: BoxConstraints(minHeight: minHeight),
      child: Stack(
        alignment: AlignmentDirectional.bottomStart,
        children: [
          if (hasArt) Positioned.fill(child: CachedArt(url: art!.backdropUrl, alignment: Alignment.topCenter)),
          const Positioned.fill(
              child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [Color(0xFA0E0E12), Color(0xE60E0E12), Color(0x990E0E12), Color(0x330E0E12)],
                stops: [0, 0.35, 0.6, 0.85],
              ),
            ),
          )),
          const Positioned.fill(
              child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0x000E0E12), PbColors.ground],
                stops: [0.45, 1],
              ),
            ),
          )),
          Padding(
            padding: const EdgeInsets.fromLTRB(PbSpace.gutterDesktop, 96, PbSpace.gutterDesktop, 20),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 170,
                  height: 255,
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    color: PbColors.surface,
                    borderRadius: BorderRadius.circular(PbRadius.card + 4),
                    boxShadow: const [BoxShadow(color: Color(0x99000000), blurRadius: 30, offset: Offset(0, 12))],
                  ),
                  child: p?.profileUrl == null
                      ? const Center(child: Icon(Icons.person, color: Colors.white24, size: 56))
                      : CachedArt(url: p!.profileUrl, alignment: Alignment.topCenter),
                ),
                const SizedBox(width: 32),
                Expanded(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 760),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (p?.knownFor != null) ...[
                          Text(
                            _designation(p!.knownFor!).toUpperCase(),
                            style: PbType.label.copyWith(color: PbColors.primary, letterSpacing: 1.1),
                          ),
                        ],
                        Text(
                          p?.name ?? name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: PbType.hero.copyWith(fontSize: 50, height: 1.05, color: PbColors.text),
                        ),
                        if (p != null && _facts(p).isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text(
                            _facts(p).join('   •   '),
                            style: PbType.meta.copyWith(fontSize: 15, color: Colors.white.withValues(alpha: 0.82)),
                          ),
                        ],
                        if (p?.biography != null) ...[
                          const SizedBox(height: 22),
                          Text(
                            p!.biography!,
                            maxLines: 4,
                            overflow: TextOverflow.ellipsis,
                            style: PbType.body.copyWith(fontSize: 15, height: 1.55, color: const Color(0xFFD6DAE3)),
                          ),
                        ],
                        if (loading) ...[
                          const SizedBox(height: 12),
                          Text('Loading…', style: PbType.body.copyWith(color: PbColors.textFaint)),
                        ] else if (checking) ...[
                          const SizedBox(height: 10),
                          Text('Checking more titles…', style: PbType.meta.copyWith(color: PbColors.textFaint)),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A heading and a sideways row of cards, like Home's.
class _Shelf extends StatelessWidget {
  const _Shelf({required this.row, required this.onOpen});

  final _CreditRow row;
  final void Function(PersonCredit) onOpen;

  @override
  Widget build(BuildContext context) {
    const poster = PbSize.posterWidthDesktop;
    const wide = PbSize.wideCardWidthDesktop;
    final width = row.wide ? wide : poster;
    final height = row.wide ? wide * 9 / 16 : poster * 1.5 + 44;
    return Padding(
      padding: const EdgeInsets.only(top: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: PbSpace.gutterDesktop),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(row.title, style: PbType.h2.copyWith(color: PbColors.text)),
                const SizedBox(width: 10),
                Text('${row.credits.length}', style: PbType.meta.copyWith(color: PbColors.textFaint)),
              ],
            ),
          ),
          SizedBox(
            height: height + 24,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              clipBehavior: Clip.none,
              padding: const EdgeInsets.symmetric(horizontal: PbSpace.gutterDesktop, vertical: 12),
              itemCount: row.credits.length,
              separatorBuilder: (_, __) => const SizedBox(width: 14),
              itemBuilder: (context, i) {
                final c = row.credits[i];
                return SizedBox(
                  width: width,
                  child: row.wide
                      ? _KnownForCard(credit: c, onOpen: () => onOpen(c))
                      : _CreditTile(credit: c, onOpen: () => onOpen(c)),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// A credit as a TitleItem, for the poster card (outside the catalog: a stand-in id).
TitleItem _asTitle(PersonCredit c) => TitleItem(
      id: c.titleId ?? 'tmdb-${c.kind}-${c.tmdbId}',
      kind: c.kind,
      title: c.title,
      year: c.year,
      posterUrl: c.posterUrl,
      backdropUrl: c.backdropUrl,
      ratings: Ratings(tmdbVoteAverage: c.voteAverage),
    );

class _CreditTile extends StatelessWidget {
  const _CreditTile({required this.credit, required this.onOpen});

  final PersonCredit credit;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AspectRatio(aspectRatio: 2 / 3, child: PosterCard(item: _asTitle(credit), onOpen: onOpen)),
        const SizedBox(height: 8),
        Text(
          credit.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: PbColors.text),
        ),
        if (credit.caption.isNotEmpty)
          Text(
            credit.caption,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white54, fontSize: 12),
          ),
      ],
    );
  }
}

/// Known for: the title's wide art with its name, year and their role on it.
class _KnownForCard extends StatefulWidget {
  const _KnownForCard({required this.credit, required this.onOpen});

  final PersonCredit credit;
  final VoidCallback onOpen;

  @override
  State<_KnownForCard> createState() => _KnownForCardState();
}

class _KnownForCardState extends State<_KnownForCard> {
  bool _lit = false;

  @override
  Widget build(BuildContext context) {
    final c = widget.credit;
    return FocusableActionDetector(
      mouseCursor: SystemMouseCursors.click,
      onShowHoverHighlight: (v) => setState(() => _lit = v),
      onShowFocusHighlight: (v) => setState(() => _lit = v),
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) {
          widget.onOpen();
          return null;
        }),
      },
      child: GestureDetector(
        onTap: widget.onOpen,
        child: AnimatedScale(
          scale: _lit ? 1.03 : 1,
          duration: PbMotion.fast,
          child: Container(
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: PbColors.surface,
              borderRadius: BorderRadius.circular(PbRadius.card),
              border: Border.all(color: _lit ? PbColors.focus : Colors.transparent, width: PbSize.focusRing),
            ),
            child: Stack(
              fit: StackFit.expand,
              children: [
                CachedArt(url: c.backdropUrl ?? c.posterUrl),
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Color(0x00000000), Color(0xE6000000)],
                      stops: [0.35, 1],
                    ),
                  ),
                ),
                Positioned(
                  left: 12,
                  right: 12,
                  bottom: 12,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        c.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: PbType.title.copyWith(color: PbColors.text),
                      ),
                      if (c.caption.isNotEmpty)
                        Text(
                          c.caption,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: PbType.meta.copyWith(color: PbColors.textMuted),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// TMDB's department ("Acting", "Directing") as what they are ("Actor", "Director").
String _designation(String department) => switch (department.trim().toLowerCase()) {
      'acting' => 'Actor',
      'directing' => 'Director',
      'writing' => 'Writer',
      'production' => 'Producer',
      'editing' => 'Editor',
      'camera' => 'Cinematographer',
      'sound' => 'Composer & sound',
      'art' => 'Production designer',
      'costume & make-up' => 'Costume & make-up',
      'visual effects' => 'Visual effects',
      'lighting' => 'Lighting',
      'creator' => 'Creator',
      _ => department,
    };
