import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:graphql_flutter/graphql_flutter.dart';

import '../design/tokens.g.dart';
import '../graphql/client.dart' show resolveArtUrl;
import '../graphql/queries.dart';
import '../models.dart';
import '../player_launch.dart';
import '../torrent_file_picker.dart';
import '../providers/catalog.dart';
import '../providers/settings.dart';
import '../widgets/cached_art.dart';
import '../widgets/hero_banner.dart';
import '../widgets/poster_card.dart';
import '../widgets/streaming_picker.dart';
import '../widgets/title_meta.dart';
import '../tv.dart';
import '../tv_nav.dart';
import '../widgets/episode_alerts.dart';
import '../widgets/tv_chrome.dart';
import '../window_layout.dart';
import '../youtube_stream.dart';

class DetailScreen extends ConsumerWidget {
  const DetailScreen({super.key, required this.titleId, this.autoPlay = false});

  final String titleId;
  /// Start playing once the page is up (Play on the home hero).
  final bool autoPlay;

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
        return _DetailBody(item: item, autoPlay: autoPlay);
      },
    );
  }
}

class _DetailBody extends ConsumerStatefulWidget {
  const _DetailBody({required this.item, this.autoPlay = false});

  final TitleItem item;
  final bool autoPlay;

  @override
  ConsumerState<_DetailBody> createState() => _DetailBodyState();
}

class _DetailBodyState extends ConsumerState<_DetailBody> {
  bool _autoPlayed = false;
  final FocusNode _play = FocusNode(debugLabel: 'detail-play');
  final FocusNode _watched = FocusNode(debugLabel: 'detail-watched');
  final FocusNode _favorite = FocusNode(debugLabel: 'detail-favorite');
  final FocusNode _back = FocusNode(debugLabel: 'detail-back');
  final ScrollController _scroll = ScrollController();
  TitleItem? _optimistic;

  TitleItem get item => _optimistic ?? widget.item;

  @override
  void didUpdateWidget(covariant _DetailBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.id != widget.item.id) {
      _optimistic = null;
    } else if (_optimistic != null &&
        widget.item.userState?.favorite == _optimistic!.userState?.favorite &&
        widget.item.userState?.watched == _optimistic!.userState?.watched) {
      // Server caught up — drop local override.
      _optimistic = null;
    }
  }

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

  Future<void> _toggleWatched() async {
    final current = item;
    final next = current.userState?.watched != true;
    final prev = _optimistic;
    setState(() {
      _optimistic = current.copyWith(
        userState: (current.userState ?? const UserState()).copyWith(
          watched: next,
          positionMs: next ? 0 : current.userState?.positionMs ?? 0,
          progressPercent: next ? 0 : current.userState?.progressPercent ?? 0,
        ),
      );
    });
    try {
      await ref.read(graphQLClientProvider).mutate(
            MutationOptions(
              document: gql(SET_WATCHED),
              variables: {'titleId': current.id, 'watched': next},
            ),
          );
      invalidatePlaybackProgress(
        ref,
        titleId: current.id,
        patch: (s) => s.copyWith(
          watched: next,
          positionMs: next ? 0 : s.positionMs,
          progressPercent: next ? 0 : s.progressPercent,
        ),
      );
    } catch (_) {
      if (mounted) setState(() => _optimistic = prev);
    }
  }

  Future<void> _toggleFavorite() async {
    final current = item;
    final next = current.userState?.favorite != true;
    final prev = _optimistic;
    setState(() {
      _optimistic = current.copyWith(
        userState: (current.userState ?? const UserState()).copyWith(favorite: next),
      );
    });
    try {
      await ref.read(graphQLClientProvider).mutate(
            MutationOptions(
              document: gql(SET_FAVORITE),
              variables: {'titleId': current.id, 'favorite': next},
            ),
          );
      ref.invalidate(favoritesFeedProvider);
      invalidatePlaybackProgress(
        ref,
        titleId: current.id,
        patch: (s) => s.copyWith(favorite: next),
      );
    } catch (_) {
      if (mounted) setState(() => _optimistic = prev);
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
    final current = _scroll.offset;
    if (current < 1.5) return;
    final ms = (280 + current * 0.45).clamp(320, 560).round();
    _scroll.animateTo(
      0,
      duration: Duration(milliseconds: ms),
      curve: Curves.easeInOutCubic,
    );
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
      final titles = episodeTitles(item.seasons);
      for (final s in [...item.seasons]
        ..sort((a, b) => a.seasonNumber.compareTo(b.seasonNumber))) {
        for (final e in episodesInViewingOrder(s, titles)) {
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
      if (!PlayerLaunch.beginPlay()) return;
      PlayerLaunch.endPlay();
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
      bool fromBeginning = false,
      bool? preferResume,
    }) async {
      if (!PlayerLaunch.beginPlay()) return;
      try {
      // Resume → reuse last magnet. From-beginning / first play → torrent picker.
      final forceBeginning = fromBeginning;
      final wantResume = forceBeginning
          ? false
          : (preferResume ?? (startMs == null ? resume : startMs > 0));
      final showPicker = forceBeginning || !wantResume;

      // Releases may number the episode differently (Samurai Jack's S01E07
      // is "IX"): search and pick the file by the number they use.
      final fileEpisode = season != null && episode != null
          ? releaseEpisode(episodeTitles(item.seasons), season, episode)
          : null;

      void openPlayer(StreamStart started) {
        if (!context.mounted || playbackSessionActive) return;
        final queryTitle = (season != null && episode != null)
            ? '${item.title} S${season.toString().padLeft(2, '0')}E${episode.toString().padLeft(2, '0')}'
            : item.title;
        final sameEpisode = episodeId == null || episodeId == item.userState?.episodeId;
        final userResume = sameEpisode ? (item.userState?.positionMs ?? 0) : 0;
        final streamResume = sameEpisode ? started.session.resumePosition : 0;
        final seek = showPicker || startMs == 0
            ? 0
            : (startMs ?? (userResume > 2000 ? userResume : (streamResume > 2000 ? streamResume : 0)));
        final extra = <String, dynamic>{
          'url': started.session.streamUrl,
          'title': episodeLabel ?? queryTitle,
          'titleId': item.id,
          'episodeId': episodeId ?? item.userState?.episodeId,
          'season': season,
          'episode': episode,
          'fileEpisode': fileEpisode,
          'startMs': seek,
          'isStream': true,
          'sessionId': started.session.id,
          'magnet': started.magnet,
          'localTorrent': started.localTorrent,
          ...started.routeExtras,
          'listedSeeders': started.session.seeders,
          'listedPeers': started.session.peers,
          'streamFileIndex': started.fileIndex,
          'catalogTitle': item.title,
          'kind': item.kind,
          'posterUrl': item.posterUrl,
          'backdropUrl': item.backdropUrl,
        };
        context.push('/player/${started.session.id}', extra: extra);
      }

      var opened = false;
      final started = await beginStreaming(
        context: context,
        client: ref.read(graphQLClientProvider),
        title: item.title,
        kind: item.kind,
        titleId: item.id,
        posterUrl: item.posterUrl,
        season: season,
        episode: fileEpisode ?? episode,
        preferredLanguages: ref.read(serverInfoProvider).valueOrNull?.preferredLanguages ??
            ref.read(settingsProvider).preferredLanguages,
        preferResume: wantResume,
        fromBeginning: showPicker,
        resumePlayback: wantResume && !showPicker,
        onReadyToPlay: (s) {
          opened = true;
          openPlayer(s);
        },
      );
      if (started == null || opened) return;
      if (!context.mounted) return;
      openPlayer(started);
      } finally {
        PlayerLaunch.endPlay();
      }
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
          preferResume: resumeHere,
          fromBeginning: !resumeHere,
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
        preferResume: resumeHere,
        fromBeginning: !resumeHere,
      );
    }

    void streamNow() {
      if (item.kind == 'MOVIE') {
        // Resume → last magnet; first Play → torrent picker.
        playStream(
          preferResume: resume,
          fromBeginning: !resume,
        );
        return;
      }
      final target = seriesPlayTarget();
      if (target != null) {
        playEpisode(target.season, target.episode);
        return;
      }
      // Last resort — still pass S01E01 so Skip Intro can resolve.
      playStream(
        season: 1,
        episode: 1,
        preferResume: resume,
        fromBeginning: !resume,
      );
    }

    // Play from the home hero (/title/<id>?play=1): press Play once, as soon as it's here.
    if (widget.autoPlay && !_autoPlayed && (playTarget != null || canStream)) {
      _autoPlayed = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (playTarget != null) {
          playFile(playTarget, startMs: resume ? effectiveResumeMs : 0);
        } else {
          streamNow();
        }
      });
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
                              fromBeginning: true,
                            );
                          } else {
                            playStream(fromBeginning: true);
                          }
                        }
                      },
                      onStream: streamNow,
                      onHeroFocus: _pinTop,
                      onToggleWatched: () {
                        unawaited(_toggleWatched());
                      },
                      onToggleFavorite: () {
                        unawaited(_toggleFavorite());
                      },
                    ),
                    if (files.length > 1)
                      Padding(
                        padding: EdgeInsets.fromLTRB(_gutter, 8, _gutter, 0),
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
                    if (item.people.isNotEmpty) _Credits(people: item.people),
                    if (item.people.isNotEmpty) _CastRow(people: item.people),
                    if (item.playableTrailers.isNotEmpty) _TrailerRow(item: item),
                    if (item.seasons.isNotEmpty) ...[
                      _SeasonList(
                        item: item,
                        files: files,
                        progressEpisodeId: resumeTarget?.episode.id ?? item.userState?.episodeId,
                        onPlayEpisode: playEpisode,
                      ),
                    ],
                    _MoreLikeThis(titleId: item.id),
                  ],
                );
                if (!isAndroidTv) return list;
                // Block Flutter's instant showOnScreen so D-pad up/down both use our
                // leisurely tvEnsureVisible (up used to jump; down looked smooth).
                return TvNoJumpScroll(child: list);
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
    final kind = switch (item.kind) {
      'SERIES' => 'Series',
      'ANIME' => 'Anime',
      _ => 'Movie',
    };
    return [kind, if (item.year != null) '${item.year}'].join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final file = playTarget;
    final tv = isAndroidTv;
    final size = Size(0, tv ? PbSize.buttonHeightTv : 40);
    final watched = item.userState?.watched == true;
    final listed = item.userState?.favorite == true;
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
        // One row, same order as the home hero: Play first, then the toggles.
        action: Wrap(
          spacing: 10,
          runSpacing: 10,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (file != null || canStream)
              _PlayButtons(
                playFocus: playFocus,
                resume: resume,
                onHeroFocus: onHeroFocus,
                onPlay: file != null
                    ? () => onPlay(file, startMs: resume ? resumeMs : 0)
                    : onStream,
                onPlayFromStart: resume ? onPlayFromStart : null,
              ),
            TvFocus(
              child: OutlinedButton.icon(
                focusNode: favoriteFocus,
                onPressed: onToggleFavorite,
                style: OutlinedButton.styleFrom(minimumSize: size),
                icon: Icon(listed ? Icons.check_rounded : Icons.add_rounded),
                label: const Text('My List'),
              ),
            ),
            TvFocus(
              child: OutlinedButton.icon(
                focusNode: watchedFocus,
                onPressed: onToggleWatched,
                style: OutlinedButton.styleFrom(minimumSize: size),
                icon: Icon(watched ? Icons.check_circle_rounded : Icons.check_circle_outline_rounded),
                label: Text(watched ? 'Watched' : 'Mark watched'),
              ),
            ),
            if (item.kind != 'MOVIE') TvFocus(child: FollowButton(titleId: item.id)),
          ],
        ),
      ),
    );
  }
}

/// Cast, director and writers as short lines under the hero.
class _Credits extends StatelessWidget {
  const _Credits({required this.people});

  final List<Person> people;

  @override
  Widget build(BuildContext context) {
    List<String> names(bool Function(Person) test, int max) {
      final seen = <String>{};
      return [for (final p in people) if (test(p) && seen.add(p.name)) p.name].take(max).toList();
    }

    final cast = names((p) => p.department.toLowerCase() == 'acting' || p.character != null, 5);
    final directors = names((p) => (p.job ?? '').toLowerCase() == 'director', 2);
    final writers = names((p) {
      final job = (p.job ?? '').toLowerCase();
      return p.department.toLowerCase() == 'writing' || job == 'writer' || job == 'screenplay';
    }, 3);
    final lines = [
      if (cast.isNotEmpty) ('Cast', cast),
      if (directors.isNotEmpty) ('Director', directors),
      if (writers.isNotEmpty) ('Writers', writers),
    ];
    if (lines.isEmpty) return const SizedBox.shrink();
    final style = (isAndroidTv ? PbTypeTv.meta : PbType.meta);
    return Padding(
      padding: EdgeInsets.fromLTRB(_gutter, 4, _gutter, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final (label, list) in lines)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text.rich(
                TextSpan(
                  text: '$label: ',
                  style: style.copyWith(color: PbColors.textFaint),
                  children: [TextSpan(text: list.join(', '), style: style.copyWith(color: PbColors.text))],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
      ),
    );
  }
}

double get _gutter => isAndroidTv ? PbSpace.gutterTv : PbSpace.gutterDesktop;

/// Section heading on the title page (Cast & crew, Trailer, Seasons, Episodes).
Widget _heading(BuildContext context, String text) => Text(
      text,
      style: (isAndroidTv ? PbTypeTv.h2 : PbType.h2).copyWith(color: PbColors.text),
    );

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
        style: FilledButton.styleFrom(minimumSize: Size(120, isAndroidTv ? PbSize.buttonHeightTv : 40)),
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
            style: OutlinedButton.styleFrom(minimumSize: Size(0, isAndroidTv ? PbSize.buttonHeightTv : 40)),
            child: const Text('From start'),
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
            padding: EdgeInsets.symmetric(horizontal: _gutter),
            child: Text(
              'Cast & crew',
              style: (isAndroidTv ? PbTypeTv.h2 : PbType.h2).copyWith(color: PbColors.text),
            ),
          ),
          SizedBox(
            height: tv ? 228 : 248,
            child: ListView.builder(
              clipBehavior: Clip.none,
              padding: EdgeInsets.symmetric(horizontal: _gutter, vertical: 16),
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
            // Same address rewrite as posters (CachedArt): the server's
            // PUBLIC_URL may not be how this app reaches it, and on the web
            // it's another origin, so photos failed while posters loaded.
            imageUrl: resolveArtUrl(
              person.profileUrl!,
              ProviderScope.containerOf(context, listen: false).read(settingsProvider).serverUrl,
            ),
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
    final tv = isAndroidTv;
    return MouseRegion(
      onEnter: (_) => setState(() => _highlighted = true),
      onExit: (_) => setState(() => _highlighted = false),
      child: GestureDetector(
        onTap: _play,
        child: _LabeledFocus(
          label: 'trailer',
          onActivate: _play,
          onFocus: (focused) {
            if (_highlighted == focused) return;
            setState(() => _highlighted = focused);
          },
          child: AnimatedScale(
            scale: _highlighted ? 1.08 : 1,
            alignment: Alignment.center,
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            child: SizedBox(
              width: tv ? 240 : 220,
              child: Material(
                elevation: _highlighted ? (tv ? 28 : 18) : (tv ? 4 : 2),
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
      ),
    );
  }
}

class _TrailerRow extends StatelessWidget {
  const _TrailerRow({required this.item});

  final TitleItem item;

  @override
  Widget build(BuildContext context) {
    final tv = isAndroidTv;
    return Padding(
      padding: EdgeInsets.fromLTRB(_gutter, tv ? 12 : 8, _gutter, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _heading(context, 'Trailer'),
          const SizedBox(height: 12),
          SizedBox(
            height: tv ? 156 : 140,
            child: ListView.separated(
              clipBehavior: Clip.none,
              scrollDirection: Axis.horizontal,
              physics: const ClampingScrollPhysics(),
              itemCount: item.playableTrailers.length,
              separatorBuilder: (_, __) => SizedBox(width: tv ? 18 : 12),
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
  /// The season shown below the season cards.
  int? _selected;

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

  @override
  void didUpdateWidget(covariant _SeasonList oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Resume moved to another season (an episode just finished): follow it.
    if (oldWidget.progressEpisodeId != widget.progressEpisodeId) _selected = null;
  }

  List<Episode> _episodesOf(Season season) {
    // Never invent placeholder episodes from episodeCount — those are often
    // unreleased slots. Only show real, already-aired episodes.
    return episodesInViewingOrder(season, episodeTitles(widget.item.seasons))
        .where((e) => e.isReleased)
        .toList();
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

  String _art(String path) => resolveArtUrl(
        path,
        ProviderScope.containerOf(context, listen: false).read(settingsProvider).serverUrl,
      );

  int _number(Season season, Episode e) =>
      releaseEpisode(episodeTitles(widget.item.seasons), season.seasonNumber, e.episodeNumber) ?? e.episodeNumber;

  bool _started(Episode e) {
    final st = e.userState;
    if (st == null || st.watched) return false;
    return st.positionMs > 2000 || st.progressPercent > 0;
  }

  /// The episode to put in the Up next card: the one in progress, else the
  /// first one not watched yet, else the first.
  Episode _upNext(List<Episode> eps) {
    final id = widget.progressEpisodeId;
    return eps.firstWhere(
      (e) => e.id == id,
      orElse: () => eps.firstWhere((e) => e.userState?.watched != true, orElse: () => eps.first),
    );
  }

  Widget _still(Episode e, {required double width, required double radius}) {
    final completed = e.userState?.watched == true;
    final started = _started(e);
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox(
        width: width,
        height: width * 9 / 16,
        child: Stack(
          fit: StackFit.expand,
          children: [
            const ColoredBox(color: PbColors.surfaceRaised),
            if (e.stillPath != null)
              CachedNetworkImage(imageUrl: _art(e.stillPath!), fit: BoxFit.cover)
            else
              const Icon(Icons.movie_outlined, color: PbColors.textFaint),
            if (started)
              Align(
                alignment: Alignment.bottomCenter,
                child: LinearProgressIndicator(
                  value: (e.userState?.progressPercent ?? 0).clamp(0.02, 1),
                  minHeight: 4,
                  backgroundColor: Colors.black45,
                  color: PbColors.primary,
                ),
              ),
            if (completed)
              const Align(
                alignment: Alignment.topRight,
                child: Padding(
                  padding: EdgeInsets.all(6),
                  child: Icon(Icons.check_circle_rounded, color: PbColors.good, size: 18),
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _sub(Episode e) {
    final st = e.userState;
    final parts = <String>[
      if (e.runtime != null && e.runtime! > 0) TitleMetaRow.formatRuntime(e.runtime!),
      if (st?.watched == true) 'Watched'
      else if (_started(e)) '${((st?.progressPercent ?? 0) * 100).clamp(0, 100).round()}% watched',
      if (widget.files.any((f) => f.episodeId == e.id)) 'In your library',
    ];
    return parts.join(' · ');
  }

  /// Season card: the season's poster (or its name on a gradient), name and count.
  Widget _seasonCard(Season season, int index, bool selected) {
    final tv = isAndroidTv;
    final eps = _episodesOf(season);
    final done = eps.where((e) => e.userState?.watched == true).length;
    final label = season.name ?? 'Season ${season.seasonNumber}';
    final width = tv ? 120.0 : 116.0;
    return Padding(
      padding: const EdgeInsets.only(right: 12),
      child: _LabeledFocus(
        label: 'season-card',
        onActivate: () => setState(() => _selected = index),
        child: InkWell(
          canRequestFocus: false,
          borderRadius: BorderRadius.circular(PbRadius.card),
          onTap: () => setState(() => _selected = index),
          child: SizedBox(
            width: width,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AnimatedContainer(
                  duration: PbMotion.fast,
                  width: width,
                  height: width * 1.5,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(PbRadius.card + 3),
                    border: Border.all(
                      color: selected ? PbColors.primary : Colors.transparent,
                      width: PbSize.focusRing,
                    ),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(PbRadius.card),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        const DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [Color(0xFF2A2D37), PbColors.surface],
                            ),
                          ),
                        ),
                        if (season.posterPath != null)
                          CachedNetworkImage(imageUrl: _art(season.posterPath!), fit: BoxFit.cover)
                        else
                          Center(
                            child: Padding(
                              padding: const EdgeInsets.all(8),
                              child: Text(
                                label.toUpperCase(),
                                textAlign: TextAlign.center,
                                style: PbType.h2.copyWith(color: PbColors.text, height: 1.05),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: PbType.button.copyWith(color: selected ? PbColors.primary : PbColors.text),
                ),
                Text(
                  done == 0 ? '${eps.length} episodes' : '$done of ${eps.length} watched',
                  style: PbType.meta.copyWith(
                    fontSize: 12,
                    color: done == eps.length ? PbColors.good : PbColors.textMuted,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Up next: the episode to watch, big, with a Play button.
  Widget _upNextCard(Season season, Episode e) {
    final tv = isAndroidTv;
    final busy = _busyEpisodeId == e.id;
    final started = _started(e);
    final copy = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '${started ? 'CONTINUE' : 'UP NEXT'} · EPISODE ${_number(season, e)}',
          style: (tv ? PbTypeTv.label : PbType.label).copyWith(color: PbColors.primary, letterSpacing: 1.1),
        ),
        const SizedBox(height: 6),
        Text(
          e.name ?? 'Episode ${_number(season, e)}',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: (tv ? PbTypeTv.h1 : PbType.h1).copyWith(color: PbColors.text, fontSize: tv ? 28 : 26),
        ),
        if (_sub(e).isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(_sub(e), style: (tv ? PbTypeTv.meta : PbType.meta).copyWith(color: PbColors.textMuted)),
        ],
        if ((e.overview ?? '').isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            e.overview!,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: (tv ? PbTypeTv.body : PbType.body).copyWith(color: const Color(0xFFD6DAE3), height: 1.45),
          ),
        ],
        const SizedBox(height: 14),
        TvFocus(
          child: FilledButton.icon(
            onPressed: busy ? null : () => _playEpisode(season, e),
            style: FilledButton.styleFrom(minimumSize: Size(110, tv ? PbSize.buttonHeightTv : 40)),
            icon: busy
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.play_arrow_rounded),
            label: Text(started ? 'Resume' : 'Play'),
          ),
        ),
      ],
    );
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(PbRadius.panel + 4),
        border: Border.all(color: PbColors.line),
        gradient: const LinearGradient(
          colors: [Color(0xFF1C1D25), PbColors.surface],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: LayoutBuilder(
        builder: (context, box) {
          final narrow = box.maxWidth < 640;
          final still = _still(e, width: narrow ? box.maxWidth : 380, radius: PbRadius.panel - 4);
          if (narrow) return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [still, const SizedBox(height: 14), copy]);
          return Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [still, const SizedBox(width: 24), Expanded(child: copy)],
          );
        },
      ),
    );
  }

  Widget _episodeTile(Season season, Episode e) {
    final tv = isAndroidTv;
    final busy = _busyEpisodeId == e.id;
    final started = _started(e);
    return _LabeledFocus(
      label: 'episode',
      allowHorizontal: false,
      onActivate: () => _playEpisode(season, e),
      child: InkWell(
        canRequestFocus: false,
        borderRadius: BorderRadius.circular(PbRadius.card),
        onTap: () => _playEpisode(season, e),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: PbColors.line)),
          ),
          child: Row(
            children: [
              _still(e, width: tv ? 150 : 160, radius: PbRadius.card - 2),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${_number(season, e)}. ${e.name ?? 'Episode'}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: (tv ? PbTypeTv.title : PbType.title).copyWith(
                        color: started ? PbColors.primary : PbColors.text,
                      ),
                    ),
                    if (_sub(e).isNotEmpty)
                      Text(_sub(e), style: (tv ? PbTypeTv.meta : PbType.meta).copyWith(color: PbColors.textMuted)),
                    if ((e.overview ?? '').isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        e.overview!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: (tv ? PbTypeTv.meta : PbType.meta).copyWith(color: PbColors.textFaint, height: 1.4),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: started ? PbColors.primary : Colors.white.withValues(alpha: 0.10),
                ),
                child: busy
                    ? const Padding(
                        padding: EdgeInsets.all(11),
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(Icons.play_arrow_rounded, color: started ? PbColors.onPrimary : PbColors.text),
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
    final index = (_selected ?? _seasonIndexForProgress(seasons)).clamp(0, seasons.length - 1);
    final season = seasons[index];
    final eps = _episodesOf(season);
    final next = _upNext(eps);
    return Padding(
      padding: EdgeInsets.fromLTRB(_gutter, 16, _gutter, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (seasons.length > 1) ...[
            _heading(context, 'Seasons'),
            const SizedBox(height: 12),
            SizedBox(
              height: (isAndroidTv ? 120.0 : 116.0) * 1.5 + 54,
              child: ListView(
                scrollDirection: Axis.horizontal,
                clipBehavior: Clip.none,
                children: [
                  for (var i = 0; i < seasons.length; i++) _seasonCard(seasons[i], i, i == index),
                ],
              ),
            ),
            const SizedBox(height: 20),
          ],
          _heading(context, 'Episodes · ${season.name ?? 'Season ${season.seasonNumber}'}'),
          const SizedBox(height: 12),
          // Full width, like the rows above it.
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: double.infinity),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _upNextCard(season, next),
                for (final e in eps)
                  if (e.id != next.id) _episodeTile(season, e),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// "More like this": what TMDB recommends, as a poster row.
class _MoreLikeThis extends ConsumerWidget {
  const _MoreLikeThis({required this.titleId});

  final String titleId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(similarTitlesProvider(titleId)).valueOrNull ?? const <TitleItem>[];
    if (items.isEmpty) return const SizedBox.shrink();
    final tv = isAndroidTv;
    final width = tv ? TvPosterDim.width : PbSize.posterWidthDesktop;
    return Padding(
      padding: const EdgeInsets.only(top: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.symmetric(horizontal: _gutter),
            child: _heading(context, 'More like this'),
          ),
          SizedBox(
            height: width * 1.5 + 24,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              clipBehavior: Clip.none,
              padding: EdgeInsets.symmetric(horizontal: _gutter, vertical: 12),
              itemExtent: width + 14,
              itemCount: items.length,
              itemBuilder: (context, i) => Padding(
                padding: const EdgeInsets.only(right: 14),
                child: PosterCard(item: items[i]),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
