import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'friendly_error.dart';
import 'graphql/client.dart';
import 'graphql/queries.dart';
import 'local_torrent.dart';
import 'models.dart';
import 'providers/settings.dart';
import 'screens/catalog.dart';
import 'screens/detail.dart';
import 'screens/edit_title.dart';
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
  // media_kit (libmpv) is used on Android TV for torrent HTTP streams — ExoPlayer
  // stays black while the download progresses.
  MediaKit.ensureInitialized();
  if (!android) {
    try {
      await dotenv.load(fileName: '.env');
    } catch (_) {}
  }
  if (LocalTorrentEngine.instance.supported) {
    unawaited(LocalTorrentEngine.instance.ensureInit());
  }
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
          listedSeeders: extra['listedSeeders'] as int? ?? 0,
          listedPeers: extra['listedPeers'] as int? ?? 0,
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
    // Never block the first frame on discovery/probe — that caused an endless
    // spinner on TV after pairing when boot work outlived Connect.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final notifier = ref.read(settingsProvider.notifier);
      const definedUrl = String.fromEnvironment('GRAPHQL_URI');
      const definedToken = String.fromEnvironment('API_KEY');
      final envUrl = definedUrl.isNotEmpty ? definedUrl : (dotenv.env['GRAPHQL_URI'] ?? '');
      final envToken = definedToken.isNotEmpty ? definedToken : (dotenv.env['API_KEY'] ?? '');
      if (envUrl.isNotEmpty) {
        final base = envUrl.replaceFirst(RegExp(r'/graphql$'), '');
        if (!(Platform.isAndroid && isLocalServer(base))) {
          await notifier.setServerUrl(base);
        }
      }
      if (envToken.isNotEmpty) {
        await notifier.setApiToken(envToken);
      }
      final settings = ref.read(settingsProvider);
      final hadSavedPairing = settings.apiToken.isNotEmpty && settings.serverUrl.isNotEmpty;
      if (hadSavedPairing) {
        final ok = await notifier.probeCurrent();
        if (ok) {
          try {
            await ref.read(serverInfoProvider.future).timeout(const Duration(seconds: 20));
            await notifier.markConnected();
          } catch (e) {
            if (isUnauthorizedError(e)) {
              await notifier.forgetPairing(
                message: 'This pairing code is no longer valid. Create a new code in the server console.',
              );
            } else {
              await notifier.markDisconnected(friendlyRequestError(e));
            }
          }
        }
      } else if (settings.serverUrl.isEmpty) {
        unawaited(notifier.discoverLocalhost());
      } else if (settings.apiToken.isEmpty) {
        unawaited(notifier.probeCurrent());
      }
    });
    _sessionWatch = Timer.periodic(const Duration(seconds: 12), (_) => _checkSession());
  }

  Future<void> _checkSession() async {
    final settings = ref.read(settingsProvider);
    if (settings.apiToken.isEmpty || settings.serverUrl.isEmpty) return;
    try {
      final result = await ref.read(graphQLClientProvider).query(
            QueryOptions(
              document: gql(GET_SERVER_INFO),
              fetchPolicy: FetchPolicy.networkOnly,
            ),
          );
      if (result.hasException) {
        final err = result.exception!;
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
    return MaterialApp.router(
      title: 'PeanutButter',
      debugShowCheckedModeBanner: false,
      themeMode: settings.themeMode,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      routerConfig: _router,
      shortcuts: {
        ...WidgetsApp.defaultShortcuts,
        const SingleActivator(LogicalKeyboardKey.select): const ActivateIntent(),
        const SingleActivator(LogicalKeyboardKey.enter): const ActivateIntent(),
        const SingleActivator(LogicalKeyboardKey.gameButtonA): const ActivateIntent(),
      },
      builder: (context, child) {
        final paired = settings.apiToken.isNotEmpty;
        final online = paired && settings.connected;
        Widget gate;
        // Stay on the pairing form while Connect verifies — writing the token
        // used to flip the gate to Unreachable/boot spinner mid-request.
        if (settings.pairingInProgress || !paired) {
          gate = const PairingScreen();
        } else if (!online) {
          gate = const UnreachableScreen();
        } else {
          gate = child ?? const SizedBox.shrink();
        }
        return MediaQuery(
          data: MediaQuery.of(context).copyWith(
            navigationMode: NavigationMode.directional,
          ),
          child: gate,
        );
      },
    );
  }
}
