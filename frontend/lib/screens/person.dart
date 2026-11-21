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

/// A cast or crew member's page: photo, name, birth and bio, then everything
/// they acted in and worked on. Opened from a title's Cast & crew.
class PersonScreen extends ConsumerStatefulWidget {
  const PersonScreen({super.key, required this.tmdbId, this.name = ''});

  final int tmdbId;
  /// Shown while the page loads.
  final String name;

  @override
  ConsumerState<PersonScreen> createState() => _PersonScreenState();
}

class _PersonScreenState extends ConsumerState<PersonScreen> {
  bool _opening = false;

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
    const gutter = PbSpace.gutterDesktop;
    const poster = PbSize.posterWidthDesktop;
    final p = person.valueOrNull;

    Widget section(String label, List<PersonCredit> credits) => SliverMainAxisGroup(
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(gutter, 32, gutter, 14),
              sliver: SliverToBoxAdapter(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(label, style: PbType.h2.copyWith(color: PbColors.text)),
                    const SizedBox(width: 10),
                    Text('${credits.length}', style: PbType.meta.copyWith(color: PbColors.textFaint)),
                  ],
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: gutter),
              sliver: SliverGrid(
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: poster + 14,
                  crossAxisSpacing: 14,
                  mainAxisSpacing: 20,
                  // Poster (2:3) plus two lines of text under it.
                  childAspectRatio: poster / (poster * 1.5 + 44),
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, i) => _CreditTile(credit: credits[i], onOpen: () => _open(credits[i])),
                  childCount: credits.length,
                ),
              ),
            ),
          ],
        );

    return Scaffold(
      backgroundColor: PbColors.ground,
      body: SafeArea(
        child: Stack(
          children: [
            CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(gutter - 8, 14, gutter, 0),
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
                          child: _Header(person: p, name: widget.name, loading: person.isLoading),
                        ),
                      ],
                    ),
                  ),
                ),
                if (person.hasError)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: Text(
                          'Couldn\'t load this person. Opening people needs PeanutButter server 0.3.26 or later.',
                          textAlign: TextAlign.center,
                          style: PbType.body.copyWith(fontSize: 16, color: PbColors.textMuted),
                        ),
                      ),
                    ),
                  ),
                if (p != null && p.acting.isNotEmpty) section('Acting', p.acting),
                if (p != null && p.crew.isNotEmpty) section('Crew', p.crew),
                const SliverToBoxAdapter(child: SizedBox(height: 40)),
              ],
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
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.person, required this.name, required this.loading});

  final PersonDetails? person;
  final String name;
  final bool loading;

  /// "Acting · Born 18 Dec 1963 in Shawnee, Oklahoma · Died …"
  static String _meta(PersonDetails p) {
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    String date(String d) {
      final t = DateTime.tryParse(d);
      return t == null ? d : '${t.day} ${months[t.month - 1]} ${t.year}';
    }

    return [
      if (p.knownFor != null) p.knownFor!,
      if (p.birthday != null) 'Born ${date(p.birthday!)}${p.placeOfBirth != null ? ' in ${p.placeOfBirth}' : ''}',
      if (p.deathday != null) 'Died ${date(p.deathday!)}',
    ].join('  ·  ');
  }

  @override
  Widget build(BuildContext context) {
    final p = person;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(PbRadius.card + 4),
          child: SizedBox(
            width: 180,
            height: 270,
            child: p?.profileUrl == null
                ? const ColoredBox(
                    color: PbColors.surface,
                    child: Center(child: Icon(Icons.person, color: Colors.white24, size: 56)),
                  )
                : CachedArt(url: p!.profileUrl, alignment: Alignment.topCenter),
          ),
        ),
        const SizedBox(width: 32),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                p?.name ?? name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: PbType.hero.copyWith(fontSize: 52, color: PbColors.text, height: 1.05),
              ),
              if (p != null && _meta(p).isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(_meta(p), style: PbType.meta.copyWith(fontSize: 15, color: PbColors.textMuted)),
              ],
              if (p?.biography != null) ...[
                const SizedBox(height: 16),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 820),
                  child: Text(
                    p!.biography!,
                    maxLines: 8,
                    overflow: TextOverflow.ellipsis,
                    style: PbType.body.copyWith(fontSize: 15, height: 1.55, color: const Color(0xFFD6DAE3)),
                  ),
                ),
              ],
              if (loading) ...[
                const SizedBox(height: 16),
                Text('Loading…', style: PbType.body.copyWith(color: PbColors.textFaint)),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _CreditTile extends StatelessWidget {
  const _CreditTile({required this.credit, required this.onOpen});

  final PersonCredit credit;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    // A poster card needs a title; credits outside the catalog get a stand-in id.
    final item = TitleItem(
      id: credit.titleId ?? 'tmdb-${credit.kind}-${credit.tmdbId}',
      kind: credit.kind,
      title: credit.title,
      year: credit.year,
      posterUrl: credit.posterUrl,
      ratings: Ratings(tmdbVoteAverage: credit.voteAverage),
    );
    final sub = [if (credit.year != null) '${credit.year}', if (credit.role != null) credit.role!].join(' · ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AspectRatio(aspectRatio: 2 / 3, child: PosterCard(item: item, onOpen: onOpen)),
        const SizedBox(height: 8),
        Text(
          credit.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: PbColors.text),
        ),
        if (sub.isNotEmpty)
          Text(
            sub,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white54, fontSize: 12),
          ),
      ],
    );
  }
}
