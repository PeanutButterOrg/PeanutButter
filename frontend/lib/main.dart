import 'dart:async';
import 'dart:io' show Platform;
import 'dart:ui' show AppExitResponse;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'friendly_error.dart';
import 'graphql/client.dart';
import 'graphql/queries.dart';
import 'models.dart';
import 'providers/settings.dart';
import 'screens/catalog.dart';
import 'screens/detail.dart';
import 'screens/edit_title.dart';
import 'screens/favourites.dart';
import 'screens/watched.dart';
import 'screens/home.dart';
import 'screens/pairing.dart';
import 'screens/player.dart';
import 'screens/search.dart';
import 'screens/settings.dart';
import 'screens/unreachable.dart';
import 'theme.dart';
import 'tv.dart';
import 'widgets/cached_art.dart';
import 'player_cache.dart';
import 'local_torrent.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Surface build failures instead of a silent black window.
  ErrorWidget.builder = (details) {
    return Material(
      color: const Color(0xFF0E0E12),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: SingleChildScrollView(
            child: Text(
              'UI error\n\n${details.exceptionAsString()}',
              style: const TextStyle(color: Color(0xFFFF6B6B), fontSize: 14, height: 1.4),
            ),
          ),
        ),
      ),
    );
  };
  final android = !kIsWeb && Platform.isAndroid;
  if (!android) {
    try {
      await dotenv.load(fileName: '.env');
    } catch (_) {}
  }
  // Do NOT init MediaKit / libtorrent here — on Windows/macOS that can leave a
  // blank black surface before any UI mounts. Player / LocalTorrentEngine init
  // themselves when streaming actually starts.
  final prefs = await SharedPreferences.getInstance();
  runApp(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
      ],
      child: const PeanutButterApp(),
    ),
  );
}

final _routerRefresh = _RouterRefresh();

class _RouterRefresh extends ChangeNotifier {
  void bump() => notifyListeners();
}

GoRouter _buildRouter(SettingsState Function() readSettings) {
  return GoRouter(
    initialLocation: '/boot',
    refreshListenable: _routerRefresh,
    redirect: (context, state) {
      final settings = readSettings();
      final path = state.uri.path;
      final onPlayer = path.startsWith('/player');
      final playing = playbackSessionActive;

      // Never yank the user off the player while a stream is active —
      // local torrents keep playing even if the catalog API is down.
      if (playing && onPlayer) return null;

      if (settings.booting) {
        return path == '/boot' ? null : '/boot';
      }
      if (settings.apiToken.isEmpty || settings.pairingInProgress) {
        return path == '/pair' ? null : '/pair';
      }
      if (!settings.connected) {
        return path == '/unreachable' ? null : '/unreachable';
      }
      if (path == '/boot' || path == '/pair' || path == '/unreachable') {
        return '/';
      }
      return null;
    },
    routes: [
      GoRoute(path: '/boot', builder: (_, __) => const _BootConnectingScreen()),
      GoRoute(path: '/pair', builder: (_, __) => const PairingScreen()),
      GoRoute(path: '/unreachable', builder: (_, __) => const UnreachableScreen()),
      GoRoute(path: '/', builder: (_, __) => const HomeScreen()),
      GoRoute(path: '/catalog', builder: (_, __) => const CatalogScreen()),
      GoRoute(path: '/search', builder: (_, __) => const SearchScreen()),
      GoRoute(path: '/favourites', builder: (_, __) => const FavouritesScreen()),
      GoRoute(path: '/watched', builder: (_, __) => const WatchedScreen()),
      GoRoute(
        path: '/title/:id',
        builder: (_, state) => DetailScreen(titleId: state.pathParameters['id']!),
      ),
      GoRoute(
        path: '/edit/:id',
        builder: (_, state) => EditTitleScreen(titleId: state.pathParameters['id']!),
      ),
      GoRoute(
        path: '/player/:fileId',
        builder: (_, state) {
          final extra = state.extra as Map<String, dynamic>? ?? const {};
          final files = (extra['files'] as List<FileReference>?) ?? const <FileReference>[];
          return PlayerScreen(
            fileId: state.pathParameters['fileId']!,
            playbackUrl: extra['url'] as String? ?? '',
            youtubeKey: extra['youtubeKey'] as String?,
            trailerPreferredQuality: extra['preferredQuality'] as String?,
            trailerInitialHeight: extra['trailerHeight'] as int?,
            titleId: extra['titleId'] as String?,
            episodeId: extra['episodeId'] as String?,
            season: extra['season'] as int?,
            episode: extra['episode'] as int?,
            title: extra['title'] as String? ?? 'Playback',
            startMs: extra['startMs'] as int? ?? 0,
            files: files,
            isStream: extra['isStream'] as bool? ?? false,
            sessionId: extra['sessionId'] as String?,
            magnet: extra['magnet'] as String?,
            localTorrent: extra['localTorrent'] as bool? ?? false,
            streamFileIndex: extra['streamFileIndex'] as int?,
            listedSeeders: extra['listedSeeders'] as int? ?? 0,
            listedPeers: extra['listedPeers'] as int? ?? 0,
            catalogTitle: extra['catalogTitle'] as String?,
            kind: extra['kind'] as String?,
            posterUrl: extra['posterUrl'] as String?,
            backdropUrl: extra['backdropUrl'] as String?,
          );
        },
      ),
      GoRoute(path: '/settings', builder: (_, __) => const SettingsScreen()),
    ],
  );
}

class PeanutButterApp extends ConsumerStatefulWidget {
  const PeanutButterApp({super.key});

  @override
  ConsumerState<PeanutButterApp> createState() => _PeanutButterAppState();
}

class _PeanutButterAppState extends ConsumerState<PeanutButterApp> with WidgetsBindingObserver {
  Timer? _sessionWatch;
  late final GoRouter _router;

  @override
  void initState() {
    super.initState();
    _router = _buildRouter(() => ref.read(settingsProvider));
    WidgetsBinding.instance.addObserver(this);
    // Paint boot route first, then discover/health.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_bootstrapSession());
    });
    _sessionWatch = Timer.periodic(const Duration(seconds: 12), (_) => _checkSession());
  }

  Future<void> _bootstrapSession() async {
    final notifier = ref.read(settingsProvider.notifier);
    notifier.beginBoot();
    try {
      // Hard cap: never leave the user on a blank/boot gate forever
      // (LAN scans + hung /health were trapping Win/Mac on a black frame).
      await _bootstrapBody(notifier).timeout(
        const Duration(seconds: 8),
        onTimeout: () {
          debugPrint('bootstrap timed out after 8s — showing session gate');
        },
      );
    } catch (e, st) {
      debugPrint('bootstrap failed: $e\n$st');
    } finally {
      ref.read(settingsProvider.notifier).finishBoot();
    }
  }

  Future<void> _bootstrapBody(SettingsNotifier notifier) async {
    const definedUrl = String.fromEnvironment('GRAPHQL_URI');
    const definedToken = String.fromEnvironment('API_KEY');
    // Installed builds often have no .env — never touch dotenv.env unless loaded
    // (NotInitializedError used to abort boot and flash Unreachable).
    final envUrl = definedUrl.isNotEmpty
        ? definedUrl
        : (dotenv.isInitialized ? (dotenv.env['GRAPHQL_URI'] ?? '') : '');
    final envToken = definedToken.isNotEmpty
        ? definedToken
        : (dotenv.isInitialized ? (dotenv.env['API_KEY'] ?? '') : '');
    if (envUrl.isNotEmpty) {
      final base = envUrl.replaceFirst(RegExp(r'/graphql$'), '');
      if (!isLocalServer(base)) {
        await notifier.setServerUrl(base);
      }
    }
    if (envToken.isNotEmpty) {
      await notifier.setApiToken(envToken);
    }
    var settings = ref.read(settingsProvider);
    // Never keep a loopback URL — always rediscover on the LAN.
    if (isLocalServer(settings.serverUrl)) {
      await notifier.setServerUrl('');
      settings = ref.read(settingsProvider);
    }
    if (settings.apiToken.isEmpty) {
      // Unpaired: show Pairing immediately — do not block boot on a full LAN scan.
      unawaited(notifier.discoverLocalhost());
      return;
    }

    // Paired: /health alone decides Home vs Unreachable (GraphQL warms after).
    if (await _ensureHealthy(notifier)) {
      await notifier.markConnected();
      _warmServerInfo();
    }
  }

  /// Saved host /health, then LAN discovery + /health. True only when reachable.
  Future<bool> _ensureHealthy(SettingsNotifier notifier) async {
    final settings = ref.read(settingsProvider);
    if (settings.serverUrl.trim().isNotEmpty) {
      if (await notifier.probeCurrentWithRetry()) return true;
    }
    final found = await notifier.discoverLocalhost();
    if (found == null) return false;
    if (ref.read(settingsProvider).apiToken.isEmpty) return false;
    return notifier.probeCurrentWithRetry(attempts: 3);
  }

  void _warmServerInfo() {
    unawaited(() async {
      try {
        ref.invalidate(serverInfoProvider);
        await ref.read(serverInfoProvider.future).timeout(const Duration(seconds: 20));
      } catch (e) {
        if (isUnauthorizedError(e)) {
          await ref.read(settingsProvider.notifier).forgetPairing(
                message: 'This pairing code is no longer valid. Create a new code in the server console.',
              );
        }
        // Reachability already passed via /health — don't bounce to Unreachable.
      }
    }());
  }

  Future<void> _checkSession() async {
    final settings = ref.read(settingsProvider);
    if (settings.apiToken.isEmpty || settings.serverUrl.isEmpty) return;
    // While watching, ignore API blips — local/torrent streams keep playing.
    if (ref.read(playbackActiveProvider) || playbackSessionActive) return;
    try {
      final result = await ref.read(graphQLClientProvider).query(
            QueryOptions(
              document: gql(GET_SERVER_INFO),
              fetchPolicy: FetchPolicy.networkOnly,
            ),
          );
      if (result.hasException) {
        final err = result.exception!;
        if (ref.read(playbackActiveProvider) || playbackSessionActive) return;
        if (isUnauthorizedError(err)) {
          await ref.read(settingsProvider.notifier).forgetPairing(
                message: 'This pairing code is no longer valid. Create a new code in the server console.',
              );
        } else if (settings.connected) {
          await ref.read(settingsProvider.notifier).markDisconnected(friendlyRequestError(err));
        }
        return;
      }
      if (!settings.connected) {
        await ref.read(settingsProvider.notifier).markConnected();
      }
    } catch (e) {
      if (ref.read(playbackActiveProvider) || playbackSessionActive) return;
      if (isUnauthorizedError(e)) {
        await ref.read(settingsProvider.notifier).forgetPairing(
              message: 'This pairing code is no longer valid. Create a new code in the server console.',
            );
      } else if (settings.connected) {
        await ref.read(settingsProvider.notifier).markDisconnected(friendlyRequestError(e));
      }
    }
  }

  @override
  void dispose() {
    _sessionWatch?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _router.dispose();
    super.dispose();
  }

  Future<void> _clearCachesOnExit() async {
    final settings = ref.read(settingsProvider);
    if (!settings.clearCacheOnExit && !isAndroidTv) return;
    try {
      await LocalTorrentEngine.instance.purgeDownloads();
    } catch (_) {}
    try {
      await PlayerCache.clear();
    } catch (_) {}
    try {
      await ArtCache.clear();
    } catch (_) {}
  }

  @override
  Future<AppExitResponse> didRequestAppExit() async {
    // Desktop: await wipe before the process dies (lifecycle alone is too late).
    await _clearCachesOnExit();
    return AppExitResponse.exit;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.detached &&
        state != AppLifecycleState.hidden &&
        state != AppLifecycleState.paused) {
      return;
    }
    // Mobile / TV often tear down without didRequestAppExit.
    unawaited(_clearCachesOnExit());
  }

  @override
  Widget build(BuildContext context) {
    // Re-run redirects when pairing / reachability changes.
    ref.listen(settingsProvider, (_, __) => _routerRefresh.bump());
    final settings = ref.watch(settingsProvider);
    final themeMode = settings.themeMode == ThemeMode.light
        ? ThemeMode.light
        : ThemeMode.dark;
    return MaterialApp.router(
      title: 'PeanutButter',
      debugShowCheckedModeBanner: false,
      themeMode: themeMode,
      theme: AppTheme.dark(),
      darkTheme: AppTheme.dark(),
      color: AppTheme.canvas,
      routerConfig: _router,
      shortcuts: {
        ...WidgetsApp.defaultShortcuts,
        const SingleActivator(LogicalKeyboardKey.select): const ActivateIntent(),
        const SingleActivator(LogicalKeyboardKey.enter): const ActivateIntent(),
        const SingleActivator(LogicalKeyboardKey.gameButtonA): const ActivateIntent(),
      },
      builder: (context, child) {
        final mq = MediaQuery.maybeOf(context);
        Widget body = child ?? const SizedBox.shrink();
        if (mq != null) {
          body = MediaQuery(
            data: mq.copyWith(navigationMode: NavigationMode.directional),
            child: body,
          );
        }
        return ColoredBox(color: AppTheme.canvas, child: body);
      },
    );
  }
}

class _BootConnectingScreen extends ConsumerWidget {
  const _BootConnectingScreen();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final url = settings.serverUrl.trim();
    final searching = settings.discovering;
    final title = searching
        ? 'Searching this network'
        : url.isEmpty
            ? 'Looking for your server'
            : 'Connecting to server';
    final detail = searching
        ? 'Checking /health on devices on your LAN'
        : url.isEmpty
            ? 'Finding PeanutButter on this network'
            : 'Checking /health at $url';

    return Scaffold(
      backgroundColor: AppTheme.canvas,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'PEANUTBUTTER',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: AppTheme.seed,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 2.4,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 28),
                const SizedBox(
                  width: 56,
                  height: 56,
                  child: CircularProgressIndicator(
                    strokeWidth: 3.5,
                    color: AppTheme.seed,
                  ),
                ),
                const SizedBox(height: 28),
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                    fontSize: 22,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  detail,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white54, height: 1.45, fontSize: 14),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
