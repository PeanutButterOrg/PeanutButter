import 'dart:async';
import 'dart:io' show Platform;

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

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
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

final _router = GoRouter(
  routes: [
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

class PeanutButterApp extends ConsumerStatefulWidget {
  const PeanutButterApp({super.key});

  @override
  ConsumerState<PeanutButterApp> createState() => _PeanutButterAppState();
}

class _PeanutButterAppState extends ConsumerState<PeanutButterApp> with WidgetsBindingObserver {
  Timer? _sessionWatch;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Start reachability immediately — do not wait for the first frame, and do
    // not mount Home/Unreachable until this finishes.
    unawaited(_bootstrapSession());
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
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.detached && state != AppLifecycleState.hidden) return;
    final settings = ref.read(settingsProvider);
    if (settings.clearCacheOnExit || isAndroidTv) {
      ArtCache.clear();
      unawaited(PlayerCache.clear());
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    // Windows/macOS/TV "system" theme is usually light → Material scaffolds paint
    // white over our dark chrome. Only honor an explicit Light choice from Settings.
    final themeMode = settings.themeMode == ThemeMode.light
        ? ThemeMode.light
        : ThemeMode.dark;
    // ONE MaterialApp for the whole lifetime. Swapping boot MaterialApp ↔
    // MaterialApp.router left Windows/macOS stuck on an empty black surface.
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
        return ColoredBox(
          color: AppTheme.canvas,
          child: MediaQuery(
            data: MediaQuery.of(context).copyWith(
              navigationMode: NavigationMode.directional,
            ),
            child: _SessionGate(child: child),
          ),
        );
      },
    );
  }
}

/// Boot → Pairing / Unreachable / routed child.
/// Always keeps the router [child] mounted (offstage) while gating — dropping
/// the Navigator on Windows/macOS was leaving a permanent blank black surface.
class _SessionGate extends ConsumerWidget {
  const _SessionGate({required this.child});

  final Widget? child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final paired = settings.apiToken.isNotEmpty;
    final online = paired && settings.connected;
    final playing = ref.watch(playbackActiveProvider) || playbackSessionActive;

    final routed = child ?? const SizedBox.shrink();

    Widget? gate;
    if (settings.booting) {
      gate = const _BootConnectingScreen();
    } else if (settings.pairingInProgress || !paired) {
      if (!playing) gate = const PairingScreen();
    } else if (!online && !playing) {
      gate = const UnreachableScreen();
    }

    if (gate == null) {
      // Online (or playing through a gate): show the real route.
      if (child != null) return routed;
      return const _BootConnectingScreen();
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        Offstage(offstage: true, child: routed),
        gate,
      ],
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
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
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
