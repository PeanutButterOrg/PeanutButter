import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:graphql_flutter/graphql_flutter.dart';

import '../graphql/client.dart';
import '../graphql/queries.dart';
import '../models.dart';
import '../providers/catalog.dart';
import '../providers/settings.dart';
import '../content_languages.dart';
import '../theme.dart';
import '../widgets/cached_art.dart';
import '../widgets/hero_banner.dart';
import '../widgets/rt_badge.dart';
import '../widgets/streaming_picker.dart';
import '../widgets/tv_chrome.dart';
import '../youtube_stream.dart';
import '../tv.dart';

class DetailScreen extends ConsumerWidget {
  const DetailScreen({super.key, required this.titleId});

  final String titleId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(detailProvider(titleId));
    return async.when(
      loading: () => const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (e, _) => Scaffold(
        appBar: AppBar(),
        body: Center(child: Text('$e')),
      ),
      data: (item) {
        if (item == null) {
          return Scaffold(
            appBar: AppBar(),
            body: const Center(child: Text('Title not found')),
          );
        }
        return _DetailBody(item: item);
      },
    );
  }
}

class _DetailBody extends ConsumerStatefulWidget {
  const _DetailBody({required this.item});

  final TitleItem item;

  @override
  ConsumerState<_DetailBody> createState() => _DetailBodyState();
}

class _DetailBodyState extends ConsumerState<_DetailBody> {
  final FocusNode _play = FocusNode(debugLabel: 'detail-play');
  final FocusNode _watched = FocusNode(debugLabel: 'detail-watched');
  final FocusNode _favorite = FocusNode(debugLabel: 'detail-favorite');
  final FocusNode _refresh = FocusNode(debugLabel: 'detail-refresh');
  final FocusNode _back = FocusNode(debugLabel: 'detail-back');
  final ScrollController _scroll = ScrollController();

  bool _refreshing = false;

  TitleItem get item => widget.item;

  @override
  void initState() {
    super.initState();
    _play.addListener(_pinIfFocused);
    _watched.addListener(_pinIfFocused);
    _favorite.addListener(_pinIfFocused);
    if (isAndroidTv) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (_scroll.hasClients) _scroll.jumpTo(0);
        final jackett = ref.read(settingsProvider).jackettConfigured;
        final node = item.fileReferences.isEmpty && !jackett ? _watched : _play;
        if (node.canRequestFocus) node.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    _play.removeListener(_pinIfFocused);
    _watched.removeListener(_pinIfFocused);
    _favorite.removeListener(_pinIfFocused);
    _play.dispose();
    _watched.dispose();
    _favorite.dispose();
    _refresh.dispose();
    _back.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _pinIfFocused() {
    if (_play.hasFocus || _watched.hasFocus || _favorite.hasFocus) _pinTop();
  }

  void _pinTop() {
    if (!isAndroidTv || !_scroll.hasClients) return;
    _scroll.jumpTo(0);
  }

  Future<void> _refreshFromServer() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    try {
      final result = await ref.read(graphQLClientProvider).mutate(
            MutationOptions(
              document: gql(REFRESH_TITLE),
              variables: {'id': item.id},
            ),
          );
      if (!mounted) return;
      if (result.hasException) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(graphqlMessage(result))),
        );
        return;
      }
      ref.invalidate(detailProvider(item.id));
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  void _leave() {
    TvHomeScroll.pendingHeader = true;
    if (context.canPop()) context.pop();
  }

  @override
  Widget build(BuildContext context) {
    final quality = ref.watch(settingsProvider.select((s) => s.defaultQuality));
    final files = [...item.fileReferences];
    files.sort((a, b) => (b.quality ?? '').compareTo(a.quality ?? ''));
    FileReference? selected;
    for (final f in files) {
      if (f.quality?.toLowerCase() == quality.toLowerCase()) {
        selected = f;
        break;
      }
    }
    final resumeMs = item.userState?.positionMs ?? 0;
    final resume = resumeMs > 2000 && item.userState?.watched != true;
    FileReference? resumeFile;
    final resumeFileId = item.userState?.fileId;
    if (resumeFileId != null) {
      for (final f in files) {
        if (f.id == resumeFileId) {
          resumeFile = f;
          break;
        }
      }
    }
    final info = ref.watch(serverInfoProvider).valueOrNull;
    final jackettOn = (info?.jackettConfigured ?? false) ||
        ref.watch(settingsProvider.select((s) => s.jackettConfigured));
    final playTarget = selected ??
        (jackettOn ? null : (resumeFile ?? (files.isNotEmpty ? files.first : null)));
    final canStream = playTarget == null && jackettOn;

    void playFile(FileReference file, {int? startMs}) {
      int? seasonNum;
      int? episodeNum;
      if (file.episodeId != null) {
        for (final s in item.seasons) {
          for (final e in s.episodes) {
            if (e.id == file.episodeId) {
              seasonNum = s.seasonNumber;
              episodeNum = e.episodeNumber;
            }
          }
        }
      }
      context.push(
        '/player/${file.id}',
        extra: {
          'url': file.playbackUrl,
          'title': item.title,
          'titleId': item.id,
          'episodeId': file.episodeId ?? item.userState?.episodeId,
          'season': seasonNum,
          'episode': episodeNum,
          'files': files,
          'startMs': startMs ?? 0,
        },
      );
    }

    Future<void> playStream({
      int? season,
      int? episode,
      String? episodeId,
      String? episodeLabel,
      int? startMs,
    }) async {
      final language = preferredLanguageCode(ref.read(settingsProvider).preferredLanguages);
      final episodeSearch = season != null && episode != null;
      final queryTitle = episodeSearch
          ? '${item.title} S${season.toString().padLeft(2, '0')}E${episode.toString().padLeft(2, '0')}'
          : item.title;
      final started = await showStreamingPicker(
        context: context,
        client: ref.read(graphQLClientProvider),
        title: episodeSearch ? queryTitle : item.title,
        kind: item.kind,
        titleId: item.id,
        year: episodeSearch ? null : item.year,
        season: season,
        episode: episode,
        language: language,
        resumePlayback: startMs == null || startMs > 0,
      );
      if (started == null) return;
      if (!context.mounted) return;
      final sameEpisode = episodeId == null || episodeId == item.userState?.episodeId;
      final userResume = sameEpisode ? (item.userState?.positionMs ?? 0) : 0;
      final streamResume = sameEpisode ? started.session.resumePosition : 0;
      final seek = startMs ?? (userResume > 2000 ? userResume : (streamResume > 2000 ? streamResume : 0));
      context.push(
        '/player/${started.session.id}',
        extra: {
          'url': started.session.streamUrl,
          'title': episodeLabel ?? queryTitle,
          'titleId': item.id,
          'episodeId': episodeId ?? item.userState?.episodeId,
          'season': season,
          'episode': episode,
          'startMs': seek,
          'isStream': true,
          'sessionId': started.session.id,
          'magnet': started.magnet,
          'localTorrent': started.localTorrent,
          'listedSeeders': started.session.seeders,
          'listedPeers': started.session.peers,
        },
      );
    }

    Future<void> playEpisode(Season season, Episode episode) async {
      FileReference? match;
      FileReference? any;
      for (final f in files) {
        if (f.episodeId != episode.id) continue;
        any ??= f;
        if (f.quality?.toLowerCase() == quality.toLowerCase()) {
          match = f;
          break;
        }
      }
      final state = item.userState;
      final resumeHere = state != null &&
          state.episodeId == episode.id &&
          state.positionMs > 2000 &&
          !state.watched;
      final startMs = resumeHere ? state.positionMs : 0;
      final label =
          '${item.title} · S${season.seasonNumber.toString().padLeft(2, '0')}E${episode.episodeNumber.toString().padLeft(2, '0')}';
      if (match != null) {
        playFile(match, startMs: startMs);
        return;
      }
      if (jackettOn) {
        await playStream(
          season: season.seasonNumber,
          episode: episode.episodeNumber,
          episodeId: episode.id,
          episodeLabel: label,
          startMs: startMs,
        );
        return;
      }
      if (any != null) {
        playFile(any, startMs: startMs);
        return;
      }
      if (!jackettOn) {
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No local file for this episode. Enable Jackett in the server console to stream it.'),
          ),
        );
        return;
      }
      await playStream(
        season: season.seasonNumber,
        episode: episode.episodeNumber,
        episodeId: episode.id,
        episodeLabel: label,
        startMs: startMs,
      );
    }

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _leave();
      },
      child: Scaffold(
        body: Stack(
          children: [
            Builder(
              builder: (context) {
                final list = ListView(
                  controller: _scroll,
                  padding: EdgeInsets.only(bottom: isAndroidTv ? tvCenterBottomPad(context) : 48),
                  physics: const ClampingScrollPhysics(),
                  children: [
                    _DetailHero(
                      item: item,
                      playFocus: _play,
                      watchedFocus: _watched,
                      favoriteFocus: _favorite,
                      playTarget: playTarget,
                      canStream: canStream,
                      resume: resume,
                      resumeMs: resumeMs,
                      onPlay: playFile,
                      onPlayFromStart: () {
                        if (playTarget != null) {
                          playFile(playTarget!, startMs: 0);
                        } else if (canStream) {
                          playStream(startMs: 0);
                        }
                      },
                      onStream: () {
                        if (item.kind == 'MOVIE') {
                          playStream();
                          return;
                        }
                        Season? season;
                        Episode? episode;
                        final resumeId = item.userState?.episodeId;
                        for (final s in item.seasons) {
                          for (final e in s.episodes) {
                            if (resumeId != null && e.id == resumeId) {
                              season = s;
                              episode = e;
                            }
                          }
                        }
                        if (season == null &&
                            item.seasons.isNotEmpty &&
                            item.seasons.first.episodes.isNotEmpty) {
                          season = item.seasons.first;
                          episode = item.seasons.first.episodes.first;
                        }
                        if (season != null && episode != null) {
                          playEpisode(season, episode);
                          return;
                        }
                        playStream(season: 1, episode: 1);
                      },
                      onHeroFocus: _pinTop,
                      onToggleWatched: () async {
                        final next = item.userState?.watched != true;
                        await ref.read(graphQLClientProvider).mutate(
                              MutationOptions(
                                document: gql(SET_WATCHED),
                                variables: {'titleId': item.id, 'watched': next},
                              ),
                            );
                        ref.invalidate(detailProvider(item.id));
                      },
                      onToggleFavorite: () async {
                        final next = item.userState?.favorite != true;
                        await ref.read(graphQLClientProvider).mutate(
                              MutationOptions(
                                document: gql(SET_FAVORITE),
                                variables: {'titleId': item.id, 'favorite': next},
                              ),
                            );
                        ref.invalidate(detailProvider(item.id));
                      },
                    ),
                    if (files.length > 1)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final f in files)
                              ChoiceChip(
                                label: Text(
                                  [
                                    f.quality,
                                    prettyVideoCodec(f.codec),
                                    prettyAudioCodec(f.audioCodec),
                                    prettyContainer(f.container),
                                  ].whereType<String>().where((s) => s.isNotEmpty).join(' · '),
                                ),
                                selected: f.id == selected?.id,
                                onSelected: (_) => playFile(f),
                              ),
                          ],
                        ),
                      ),
                    if (item.people.isNotEmpty) _CastRow(people: item.people),
                    if (!isAndroidTv && item.playableTrailers.isNotEmpty) _TrailerRow(item: item),
                    if (item.seasons.isNotEmpty)
                      _SeasonList(
                        item: item,
                        files: files,
                        progressEpisodeId: item.userState?.episodeId,
                        onPlayEpisode: playEpisode,
                      ),
                  ],
                );
                if (!isAndroidTv) return list;
                return FocusTraversalGroup(policy: TvDetailFocusPolicy(), child: list);
              },
            ),
            Positioned(
              top: MediaQuery.paddingOf(context).top + 8,
              left: 8,
              right: 8,
              child: Row(
                children: [
                  Material(
                    color: const Color(0xCC121218),
                    shape: const CircleBorder(),
                    elevation: 8,
                    child: TvFocus(
                      allowHorizontal: false,
                      child: IconButton(
                        focusNode: isAndroidTv ? _back : null,
                        tooltip: 'Back',
                        onPressed: _leave,
                        icon: const Icon(Icons.arrow_back_rounded),
                      ),
                    ),
                  ),
                  const Spacer(),
                  Material(
                    color: const Color(0xCC121218),
                    shape: const CircleBorder(),
                    elevation: 8,
                    child: TvFocus(
                      allowHorizontal: false,
                      child: IconButton(
                        focusNode: isAndroidTv ? _refresh : null,
                        tooltip: 'Refresh',
                        onPressed: _refreshing ? null : _refreshFromServer,
                        icon: _refreshing
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.refresh_rounded),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DetailHero extends StatelessWidget {
  const _DetailHero({
    required this.item,
    required this.playFocus,
    required this.watchedFocus,
    required this.favoriteFocus,
    required this.playTarget,
    required this.canStream,
    required this.resume,
    required this.resumeMs,
    required this.onPlay,
    required this.onStream,
    required this.onPlayFromStart,
    required this.onHeroFocus,
    required this.onToggleWatched,
    required this.onToggleFavorite,
  });

  final TitleItem item;
  final FocusNode playFocus;
  final FocusNode watchedFocus;
  final FocusNode favoriteFocus;
  final FileReference? playTarget;
  final bool canStream;
  final bool resume;
  final int resumeMs;
  final void Function(FileReference file, {int? startMs}) onPlay;
  final VoidCallback onStream;
  final VoidCallback onPlayFromStart;
  final VoidCallback onHeroFocus;
  final VoidCallback onToggleWatched;
  final VoidCallback onToggleFavorite;

  String get _eyebrow {
    switch (item.kind) {
      case 'SERIES':
        return 'Series';
      case 'ANIME':
        return 'Anime';
      default:
        return 'Movies';
    }
  }

  @override
  Widget build(BuildContext context) {
    final file = playTarget;
    return HeroBannerFrame(
      art: BannerArt(
        url: item.thumbUrl ?? item.backdropUrl ?? item.posterUrl,
        fallbackUrl: item.posterUrl,
        logoUrl: item.logoUrl,
      ),
      child: HeroBannerCopy(
        eyebrow: _eyebrow,
        title: item.title,
        synopsis: item.synopsis ?? '',
        meta: Row(
          children: [
            RatingBadge(item: item, compact: false),
            if (item.year != null) ...[
              const SizedBox(width: 8),
              Text('${item.year}', style: const TextStyle(color: Colors.white70, fontSize: 14)),
            ],
            if (item.runtimeMinutes != null) ...[
              const SizedBox(width: 8),
              Text('${item.runtimeMinutes} min', style: const TextStyle(color: Colors.white70, fontSize: 14)),
            ],
            for (final label in item.mediaLabels) ...[
              const SizedBox(width: 8),
              Text(label, style: const TextStyle(color: Colors.white70, fontSize: 14)),
            ],
            for (final genre in item.genres.take(2)) ...[
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  genre,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white70, fontSize: 14),
                ),
              ),
            ],
          ],
        ),
        belowTitle: file != null || canStream
            ? _PlayButtons(
                playFocus: playFocus,
                resume: resume,
                onHeroFocus: onHeroFocus,
                onPlay: file != null
                    ? () => onPlay(file, startMs: resume ? resumeMs : 0)
                    : onStream,
                onPlayFromStart: resume ? onPlayFromStart : null,
              )
            : null,
        action: Row(
          children: [
            TvFocus(
              child: IconButton.filledTonal(
                focusNode: watchedFocus,
                tooltip: item.userState?.watched == true ? 'Mark unwatched' : 'Mark watched',
                onPressed: onToggleWatched,
                icon: Icon(
                  item.userState?.watched == true ? Icons.check_circle : Icons.check_circle_outline,
                ),
              ),
            ),
            const SizedBox(width: 8),
            TvFocus(
              child: IconButton.filledTonal(
                focusNode: favoriteFocus,
                tooltip: item.userState?.favorite == true ? 'Unfavorite' : 'Favorite',
                onPressed: onToggleFavorite,
                icon: Icon(
                  item.userState?.favorite == true ? Icons.favorite : Icons.favorite_border,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Play / Resume button row shown on the detail hero.
class _PlayButtons extends StatelessWidget {
  const _PlayButtons({
    required this.playFocus,
    required this.resume,
    required this.onPlay,
    required this.onHeroFocus,
    this.onPlayFromStart,
  });

  final FocusNode playFocus;
  final bool resume;
  final VoidCallback onPlay;
  final VoidCallback onHeroFocus;
  final VoidCallback? onPlayFromStart;

  @override
  Widget build(BuildContext context) {
    final mainBtn = TvFocus(
      child: FilledButton.icon(
        focusNode: playFocus,
        autofocus: isAndroidTv,
        onFocusChange: (focused) {
          if (focused) onHeroFocus();
        },
        onPressed: onPlay,
        style: FilledButton.styleFrom(minimumSize: const Size(148, 48)),
        icon: const Icon(Icons.play_arrow_rounded),
        label: Text(resume ? 'Resume' : 'Play'),
      ),
    );

    if (!resume || onPlayFromStart == null) return mainBtn;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        mainBtn,
        const SizedBox(width: 10),
        TvFocus(
          child: OutlinedButton(
            onPressed: onPlayFromStart,
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(0, 48),
              padding: const EdgeInsets.symmetric(horizontal: 14),
              side: const BorderSide(color: Colors.white38),
              foregroundColor: Colors.white70,
            ),
            child: const Text('From start', style: TextStyle(fontSize: 12)),
          ),
        ),
      ],
    );
  }
}

class _LabeledFocus extends StatefulWidget {
  const _LabeledFocus({
    required this.label,
    required this.child,
    this.allowHorizontal = true,
    this.onActivate,
    this.onFocus,
  });

  final String label;
  final Widget child;
  final bool allowHorizontal;
  final VoidCallback? onActivate;
  final ValueChanged<bool>? onFocus;

  @override
  State<_LabeledFocus> createState() => _LabeledFocusState();
}

class _LabeledFocusState extends State<_LabeledFocus> {
  late final FocusNode _node = FocusNode(debugLabel: widget.label);

  @override
  void dispose() {
    _node.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TvFocus(
      allowHorizontal: widget.allowHorizontal,
      child: FocusableActionDetector(
        focusNode: _node,
        onFocusChange: (focused) {
          widget.onFocus?.call(focused);
          if (!focused || !isAndroidTv) return;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) tvEnsureVisible(context, alignment: 0.18);
          });
        },
        actions: {
          if (widget.onActivate != null)
            ActivateIntent: CallbackAction<ActivateIntent>(
              onInvoke: (_) {
                widget.onActivate!();
                return null;
              },
            ),
        },
        child: widget.child,
      ),
    );
  }
}

class _CastRow extends StatelessWidget {
  const _CastRow({required this.people});

  final List<Person> people;

  @override
  Widget build(BuildContext context) {
    final tv = isAndroidTv;
    final cardWidth = tv ? 104.0 : 120.0;
    final imageHeight = tv ? 148.0 : 168.0;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Text(
              'Cast & crew',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          SizedBox(
            height: tv ? 228 : 248,
            child: ListView.builder(
              clipBehavior: Clip.none,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              scrollDirection: Axis.horizontal,
              physics: const ClampingScrollPhysics(),
              itemCount: people.length,
              itemBuilder: (context, i) {
                final person = people[i];
                final role = person.character ?? person.job ?? '';
                return Padding(
                  padding: EdgeInsets.only(right: tv ? 18 : 12),
                  child: SizedBox(
                    width: cardWidth,
                    child: _CastTile(
                      person: person,
                      role: role,
                      cardWidth: cardWidth,
                      imageHeight: imageHeight,
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _CastTile extends StatefulWidget {
  const _CastTile({
    required this.person,
    required this.role,
    required this.cardWidth,
    required this.imageHeight,
  });

  final Person person;
  final String role;
  final double cardWidth;
  final double imageHeight;

  @override
  State<_CastTile> createState() => _CastTileState();
}

class _CastTileState extends State<_CastTile> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final person = widget.person;
    final image = person.profileUrl == null
        ? const ColoredBox(
            color: Color(0xFF1C1C24),
            child: Center(child: Icon(Icons.person, color: Colors.white24, size: 36)),
          )
        : CachedNetworkImage(
            imageUrl: person.profileUrl!,
            fit: BoxFit.cover,
            width: widget.cardWidth,
            height: widget.imageHeight,
            fadeInDuration: Duration.zero,
            errorWidget: (_, __, ___) => const ColoredBox(
              color: Color(0xFF1C1C24),
              child: Center(child: Icon(Icons.person, color: Colors.white24, size: 36)),
            ),
          );
    return _LabeledFocus(
      label: 'cast',
      onFocus: (focused) {
        if (_focused == focused) return;
        setState(() => _focused = focused);
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AnimatedScale(
            scale: _focused && isAndroidTv ? 1.08 : 1,
            duration: const Duration(milliseconds: 180),
            child: Material(
              elevation: _focused && isAndroidTv ? 28 : (isAndroidTv ? 4 : 0),
              shadowColor: Colors.black,
              color: Colors.transparent,
              surfaceTintColor: Colors.transparent,
              borderRadius: BorderRadius.circular(10),
              clipBehavior: Clip.antiAlias,
              child: SizedBox(
                width: widget.cardWidth,
                height: widget.imageHeight,
                child: image,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            person.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
          ),
          if (widget.role.isNotEmpty)
            Text(
              widget.role,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
        ],
      ),
    );
  }
}

class _TrailerCard extends StatefulWidget {
  const _TrailerCard({required this.trailer});

  final Trailer trailer;

  @override
  State<_TrailerCard> createState() => _TrailerCardState();
}

class _TrailerCardState extends State<_TrailerCard> {
  bool _highlighted = false;

  @override
  Widget build(BuildContext context) {
    final t = widget.trailer;
    return MouseRegion(
      onEnter: (_) => setState(() => _highlighted = true),
      onExit: (_) => setState(() => _highlighted = false),
      child: GestureDetector(
        onTap: () => playTrailer(context, videoId: t.youtubeKey, title: t.name),
        child: AnimatedScale(
          scale: _highlighted ? 1.08 : 1,
          alignment: Alignment.center,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          child: SizedBox(
            width: 220,
            child: Material(
              elevation: _highlighted ? 18 : 2,
              shadowColor: Colors.black,
              color: Colors.transparent,
              surfaceTintColor: Colors.transparent,
              borderRadius: BorderRadius.circular(12),
              clipBehavior: Clip.antiAlias,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        CachedArt(url: t.thumbnailUrl, memCacheWidth: 440),
                        const ColoredBox(color: Color(0x59000000)),
                        const Center(
                          child: Icon(
                            Icons.play_circle_fill_rounded,
                            size: 52,
                            color: Colors.white,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
                    child: Text(t.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TrailerRow extends StatelessWidget {
  const _TrailerRow({required this.item});

  final TitleItem item;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Trailers', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 12),
          SizedBox(
            height: 140,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: item.playableTrailers.length,
              separatorBuilder: (_, __) => const SizedBox(width: 12),
              itemBuilder: (context, i) {
                final t = item.playableTrailers[i];
                return _TrailerCard(trailer: t);
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _SeasonList extends StatefulWidget {
  const _SeasonList({
    required this.item,
    required this.files,
    required this.onPlayEpisode,
    this.progressEpisodeId,
  });

  final TitleItem item;
  final List<FileReference> files;
  final Future<void> Function(Season season, Episode episode) onPlayEpisode;
  final String? progressEpisodeId;

  @override
  State<_SeasonList> createState() => _SeasonListState();
}

class _SeasonListState extends State<_SeasonList> {
  String? _busyEpisodeId;
  late final List<bool> _expanded;

  List<Season> get _seasons {
    final seasons = widget.item.seasons.where((s) {
      if (s.seasonNumber <= 0) return false;
      final name = (s.name ?? '').toLowerCase();
      if (name.contains('special')) return false;
      return s.episodes.isNotEmpty || (s.episodeCount ?? 0) > 0;
    }).toList()
      ..sort((a, b) => a.seasonNumber.compareTo(b.seasonNumber));
    return seasons;
  }

  @override
  void initState() {
    super.initState();
    final count = _seasons.length;
    // First season expanded, rest collapsed
    _expanded = List.generate(count, (i) => i == 0);
  }

  List<Episode> _episodesOf(Season season) {
    if (season.episodes.isNotEmpty) return season.episodes;
    final count = season.episodeCount ?? 0;
    return [
      for (var n = 1; n <= count; n++)
        Episode(id: '${season.id}-$n', episodeNumber: n, name: 'Episode $n'),
    ];
  }

  Future<void> _playEpisode(Season season, Episode episode) async {
    if (_busyEpisodeId != null) return;
    setState(() => _busyEpisodeId = episode.id);
    try {
      await widget.onPlayEpisode(season, episode);
    } finally {
      if (mounted) setState(() => _busyEpisodeId = null);
    }
  }

  Widget _episodeTile(Season season, Episode e) {
    final files = widget.files;
    final hasLocal = files.any((f) => f.episodeId == e.id);
    final inProgress = widget.progressEpisodeId == e.id;
    final busy = _busyEpisodeId == e.id;
    final tv = isAndroidTv;
    return _LabeledFocus(
      label: 'episode',
      allowHorizontal: false,
      onActivate: () => _playEpisode(season, e),
      child: InkWell(
        canRequestFocus: false,
        onTap: () => _playEpisode(season, e),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: SizedBox(
                  width: tv ? 80 : 96,
                  height: tv ? 45 : 54,
                  child: e.stillPath != null
                      ? CachedNetworkImage(imageUrl: e.stillPath!, fit: BoxFit.cover)
                      : ColoredBox(
                          color: const Color(0xFF1C1C24),
                          child: Icon(
                            hasLocal ? Icons.play_circle_outline : Icons.play_circle,
                            color: inProgress ? AppTheme.seed : Colors.white70,
                            size: 22,
                          ),
                        ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${e.episodeNumber}. ${e.name ?? 'Episode'}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: tv ? 13 : 15,
                        color: inProgress ? AppTheme.seed : null,
                      ),
                    ),
                    if (e.overview != null && e.overview!.isNotEmpty)
                      Text(
                        e.overview!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: Colors.white54, fontSize: tv ? 11 : 13),
                      )
                    else
                      Text(
                        hasLocal ? 'Play from library' : 'Play episode',
                        style: TextStyle(color: Colors.white38, fontSize: tv ? 11 : 12),
                      ),
                  ],
                ),
              ),
              if (busy)
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                Icon(
                  Icons.play_arrow_rounded,
                  color: inProgress ? AppTheme.seed : Colors.white54,
                ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final seasons = _seasons;
    if (seasons.isEmpty) return const SizedBox.shrink();
    // Keep _expanded in sync if seasons list length changes
    while (_expanded.length < seasons.length) {
      _expanded.add(false);
    }
    final scheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Seasons',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          for (var i = 0; i < seasons.length; i++) ...[
            Material(
              color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
              borderRadius: BorderRadius.circular(12),
              clipBehavior: Clip.antiAlias,
              child: ExpansionTile(
                key: PageStorageKey(seasons[i].id),
                initiallyExpanded: i == 0,
                onExpansionChanged: (v) => setState(() => _expanded[i] = v),
                tilePadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
                childrenPadding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                shape: const Border(),
                collapsedShape: const Border(),
                title: Text(
                  seasons[i].name ?? 'Season ${seasons[i].seasonNumber}',
                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                ),
                subtitle: Text(
                  '${_episodesOf(seasons[i]).length} episodes',
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: 12,
                  ),
                ),
                children: [
                  for (final e in _episodesOf(seasons[i]))
                    _episodeTile(seasons[i], e),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }
}
