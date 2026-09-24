import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:graphql_flutter/graphql_flutter.dart';

import '../graphql/queries.dart';
import '../models.dart';
import '../providers/catalog.dart';
import '../providers/settings.dart';
import '../theme.dart';
import '../widgets/cached_art.dart';
import '../widgets/hero_banner.dart';
import '../widgets/streaming_picker.dart';
import '../widgets/title_meta.dart';
import '../tv.dart';
import '../tv_nav.dart';
import '../widgets/tv_chrome.dart';
import '../window_layout.dart';
import '../youtube_stream.dart';

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
  final FocusNode _back = FocusNode(debugLabel: 'detail-back');
  final ScrollController _scroll = ScrollController();

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

    ({Season season, Episode episode})? seriesPlayTarget() {
      if (item.kind == 'MOVIE') return null;
      bool completed(Episode e) => e.userState?.watched == true;

      final resumeId = item.userState?.episodeId;
      final flat = <({Season season, Episode episode})>[];
      for (final s in item.seasons) {
        for (final e in s.episodes) {
          flat.add((season: s, episode: e));
        }
      }
      if (flat.isEmpty) return null;

      var idx = 0;
      if (resumeId != null) {
        final found = flat.indexWhere((x) => x.episode.id == resumeId);
        if (found >= 0) idx = found;
      }
      // Finished episode → continue from the next one, not the end of this torrent.
      if (completed(flat[idx].episode)) {
        for (var i = idx + 1; i < flat.length; i++) {
          if (!completed(flat[i].episode)) return flat[i];
        }
        return flat[idx];
      }
      return flat[idx];
    }

    final resumeMs = item.userState?.positionMs ?? 0;
    final resumeTarget = seriesPlayTarget();
    final resumeEpisodeDone = resumeTarget?.episode.userState?.watched == true;
    final resumeEpPos = resumeTarget?.episode.userState?.positionMs ?? 0;
    final resume = item.kind == 'MOVIE'
        ? (resumeMs > 2000 && item.userState?.watched != true)
        : (!resumeEpisodeDone &&
            ((resumeEpPos > 2000) ||
                (resumeMs > 2000 &&
                    item.userState?.watched != true &&
                    resumeTarget?.episode.id == item.userState?.episodeId)));
    final effectiveResumeMs = item.kind == 'MOVIE'
        ? resumeMs
        : (resumeEpPos > 2000 ? resumeEpPos : resumeMs);
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
          'catalogTitle': item.title,
          'kind': item.kind,
          'titleId': item.id,
          'episodeId': file.episodeId ?? item.userState?.episodeId,
          'season': seasonNum,
          'episode': episodeNum,
          'files': files,
          'startMs': startMs ?? 0,
          'posterUrl': item.posterUrl,
          'backdropUrl': item.backdropUrl,
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
      void openPlayer(StreamStart started) {
        if (!context.mounted) return;
        final queryTitle = (season != null && episode != null)
            ? '${item.title} S${season.toString().padLeft(2, '0')}E${episode.toString().padLeft(2, '0')}'
            : item.title;
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
            'streamFileIndex': started.fileIndex,
            'catalogTitle': item.title,
            'kind': item.kind,
            'posterUrl': item.posterUrl,
            'backdropUrl': item.backdropUrl,
          },
        );
      }

      var opened = false;
      final started = await showStreamingPicker(
        context: context,
        client: ref.read(graphQLClientProvider),
        title: item.title,
        kind: item.kind,
        titleId: item.id,
        season: season,
        episode: episode,
        preferredLanguages: ref.read(serverInfoProvider).valueOrNull?.preferredLanguages ??
            ref.read(settingsProvider).preferredLanguages,
        resumePlayback: startMs == null || startMs > 0,
        onReadyToPlay: (s) {
          opened = true;
          openPlayer(s);
        },
      );
      if (started == null || opened) return;
      if (!context.mounted) return;
      openPlayer(started);
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
      final epDone = episode.userState?.watched == true;
      final epPos = episode.userState?.positionMs ?? 0;
      final titleResumeHere = state != null &&
          state.episodeId == episode.id &&
          state.positionMs > 2000 &&
          !state.watched;
      final resumeHere = !epDone &&
          ((epPos > 2000) || titleResumeHere);
      final startMs = resumeHere
          ? (epPos > 2000 ? epPos : state!.positionMs)
          : 0;
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

    return TvNavHost(
      strategies: [TvNavDetailStrategy()],
      child: PopScope(
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
                      resumeMs: effectiveResumeMs,
                      onPlay: playFile,
                      onPlayFromStart: () {
                        if (playTarget != null) {
                          playFile(playTarget, startMs: 0);
                        } else if (canStream) {
                          final target = seriesPlayTarget();
                          if (target != null) {
                            playStream(
                              season: target.season.seasonNumber,
                              episode: target.episode.episodeNumber,
                              episodeId: target.episode.id,
                              startMs: 0,
                            );
                          } else {
                            playStream(startMs: 0);
                          }
                        }
                      },
                      onStream: () {
                        if (item.kind == 'MOVIE') {
                          playStream();
                          return;
                        }
                        final target = seriesPlayTarget();
                        if (target != null) {
                          playEpisode(target.season, target.episode);
                          return;
                        }
                        // Last resort — still pass S01E01 so Skip Intro can resolve.
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
                        ref.invalidate(favoritesFeedProvider);
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
                    if (item.playableTrailers.isNotEmpty) _TrailerRow(item: item),
                    if (item.seasons.isNotEmpty)
                      _SeasonList(
                        item: item,
                        files: files,
                        progressEpisodeId: resumeTarget?.episode.id ?? item.userState?.episodeId,
                        onPlayEpisode: playEpisode,
                      ),
                  ],
                );
                if (!isAndroidTv) return list;
                return list;
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
                ],
              ),
            ),
          ],
        ),
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
      topInset: HeroBannerFrame.headerGap(context),
      art: BannerArt(
        url: bestBannerUrl(
          backdropUrl: item.backdropUrl,
          thumbUrl: item.thumbUrl,
          posterUrl: item.posterUrl,
        ),
        fallbackUrl: item.posterUrl,
        logoUrl: item.logoUrl,
      ),
      child: HeroBannerCopy(
        eyebrow: _eyebrow,
        title: item.title,
        synopsis: item.synopsis ?? '',
        meta: TitleMetaRow(item: item, maxGenres: 3),
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
  bool _loading = false;

  Future<void> _play() async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      await playTrailer(
        context,
        videoId: widget.trailer.youtubeKey,
        title: widget.trailer.name,
        preferredQuality: '720p',
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.trailer;
    return MouseRegion(
      onEnter: (_) => setState(() => _highlighted = true),
      onExit: (_) => setState(() => _highlighted = false),
      child: GestureDetector(
        onTap: _play,
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
                        Center(
                          child: _loading
                              ? const SizedBox(
                                  width: 36,
                                  height: 36,
                                  child: CircularProgressIndicator(strokeWidth: 3, color: Colors.white),
                                )
                              : const Icon(
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
          Text('Trailer', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
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
  late List<bool> _expanded;
  final Map<String, ExpansionTileController> _controllers = {};

  ExpansionTileController _controllerFor(String id) {
    return _controllers.putIfAbsent(id, ExpansionTileController.new);
  }

  List<Season> get _seasons {
    final seasons = widget.item.seasons.where((s) {
      if (s.seasonNumber <= 0) return false;
      final name = (s.name ?? '').toLowerCase();
      if (name.contains('special')) return false;
      // Only list seasons that already have at least one aired episode.
      return _episodesOf(s).isNotEmpty;
    }).toList()
      ..sort((a, b) => a.seasonNumber.compareTo(b.seasonNumber));
    return seasons;
  }

  int _seasonIndexForProgress(List<Season> seasons) {
    final progressId = widget.progressEpisodeId;
    if (progressId == null || progressId.isEmpty) return 0;
    for (var i = 0; i < seasons.length; i++) {
      if (_episodesOf(seasons[i]).any((e) => e.id == progressId)) return i;
    }
    return 0;
  }

  void _syncExpanded(List<Season> seasons, {bool preferProgress = false}) {
    final active = _seasonIndexForProgress(seasons);
    if (_expanded.length != seasons.length || preferProgress) {
      _expanded = List.generate(seasons.length, (i) => i == active);
      // Drive expand/collapse through controllers so the tile can animate.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _applyControllers(seasons);
      });
      return;
    }
    while (_expanded.length < seasons.length) {
      _expanded.add(false);
    }
    if (_expanded.length > seasons.length) {
      _expanded = _expanded.sublist(0, seasons.length);
    }
  }

  void _applyControllers(List<Season> seasons) {
    for (var i = 0; i < seasons.length; i++) {
      final c = _controllerFor(seasons[i].id);
      if (_expanded[i]) {
        c.expand();
      } else {
        c.collapse();
      }
    }
  }

  @override
  void initState() {
    super.initState();
    final seasons = _seasons;
    final active = _seasonIndexForProgress(seasons);
    // Only the in-progress / last-played season starts open; everything else collapsed.
    _expanded = List.generate(seasons.length, (i) => i == active);
  }

  @override
  void didUpdateWidget(covariant _SeasonList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.progressEpisodeId != widget.progressEpisodeId) {
      _syncExpanded(_seasons, preferProgress: true);
    }
  }

  @override
  void dispose() {
    _controllers.clear();
    super.dispose();
  }

  List<Episode> _episodesOf(Season season) {
    // Never invent placeholder episodes from episodeCount — those are often
    // unreleased slots. Only show real, already-aired episodes.
    return season.episodes.where((e) => e.isReleased).toList();
  }

  void _setExpanded(int index, bool open, List<Season> seasons) {
    // Animate siblings closed via controllers — do not remount tiles (that
    // killed ExpansionTile's built-in expand/collapse animation).
    if (open) {
      for (var i = 0; i < seasons.length; i++) {
        if (i == index) continue;
        _controllerFor(seasons[i].id).collapse();
      }
    }
    setState(() {
      if (open) {
        for (var i = 0; i < _expanded.length; i++) {
          _expanded[i] = i == index;
        }
      } else {
        _expanded[index] = false;
      }
    });
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
    final epState = e.userState;
    final completed = epState?.watched == true;
    final pct = ((epState?.progressPercent ?? 0) * 100).clamp(0, 100).round();
    final started = !completed && ((epState?.positionMs ?? 0) > 2000 || pct > 0);
    final String statusLine;
    if (started) {
      statusLine = 'In progress · $pct%';
    } else if (hasLocal) {
      statusLine = 'Play from library';
    } else {
      statusLine = 'Play episode';
    }
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
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      e.stillPath != null
                          ? CachedNetworkImage(imageUrl: e.stillPath!, fit: BoxFit.cover)
                          : ColoredBox(
                              color: const Color(0xFF1C1C24),
                              child: Icon(
                                hasLocal ? Icons.play_circle_outline : Icons.play_circle,
                                color: inProgress || started ? AppTheme.seed : Colors.white70,
                                size: 22,
                              ),
                            ),
                      if (started)
                        Align(
                          alignment: Alignment.bottomCenter,
                          child: LinearProgressIndicator(
                            value: (epState?.progressPercent ?? 0).clamp(0.02, 1),
                            minHeight: 3,
                            backgroundColor: Colors.black45,
                            color: AppTheme.seed,
                          ),
                        ),
                      if (completed)
                        const Align(
                          alignment: Alignment.topRight,
                          child: Padding(
                            padding: EdgeInsets.all(4),
                            child: Icon(Icons.check_circle, color: PtTheme.completed, size: 16),
                          ),
                        ),
                    ],
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
                        color: inProgress || started ? AppTheme.seed : null,
                      ),
                    ),
                    Text(
                      statusLine,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: started ? AppTheme.seed.withValues(alpha: 0.9) : Colors.white54,
                        fontSize: tv ? 11 : 12,
                        fontWeight: started ? FontWeight.w600 : FontWeight.w400,
                      ),
                    ),
                    if (started) ...[
                      const SizedBox(height: 5),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(2),
                        child: LinearProgressIndicator(
                          value: (epState?.progressPercent ?? 0).clamp(0.02, 1),
                          minHeight: 3,
                          backgroundColor: Colors.white12,
                          color: AppTheme.seed,
                        ),
                      ),
                    ],
                    if (e.overview != null && e.overview!.isNotEmpty)
                      Text(
                        e.overview!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: Colors.white38, fontSize: tv ? 10 : 12),
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
                  color: inProgress || started ? AppTheme.seed : Colors.white54,
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
    _syncExpanded(seasons);
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
              child: Theme(
                data: Theme.of(context).copyWith(
                  dividerColor: Colors.transparent,
                  splashColor: scheme.primary.withValues(alpha: 0.08),
                ),
                child: ExpansionTile(
                  // Stable key so expand/collapse can animate (never remount on toggle).
                  key: ValueKey('season-${seasons[i].id}'),
                  controller: _controllerFor(seasons[i].id),
                  initiallyExpanded: _expanded[i],
                  maintainState: true,
                  onExpansionChanged: (v) => _setExpanded(i, v, seasons),
                  tilePadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
                  childrenPadding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                  expandedAlignment: Alignment.centerLeft,
                  expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
                  shape: const Border(),
                  collapsedShape: const Border(),
                  title: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        seasons[i].name ?? 'Season ${seasons[i].seasonNumber}',
                        style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                      ),
                      Builder(
                        builder: (_) {
                          final eps = _episodesOf(seasons[i]);
                          final done = eps.where((e) => e.userState?.watched == true).length;
                          final started = eps.where((e) {
                            final s = e.userState;
                            if (s == null || s.watched) return false;
                            return s.positionMs > 2000 || s.progressPercent > 0;
                          }).length;
                          if (done == 0 && started == 0) {
                            return Text(
                              '${eps.length} episodes',
                              style: const TextStyle(color: Colors.white54, fontSize: 12),
                            );
                          }
                          return Text(
                            '$done of ${eps.length} completed'
                            '${started > 0 ? ' · $started in progress' : ''}',
                            style: TextStyle(
                              color: done == eps.length
                                  ? PtTheme.completed
                                  : Colors.white54,
                              fontSize: 12,
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                  children: [
                    for (final e in _episodesOf(seasons[i]))
                      _episodeTile(seasons[i], e),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }
}
